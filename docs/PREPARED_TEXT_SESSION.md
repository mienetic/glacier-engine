# Prepared Text Session

The prepared text session is an experimental Zig API for one bounded,
in-process text-generation lifecycle. It connects an exact prepared `.glrt`
image, one prompt, one resource admission, serial greedy execution, and
transactional token publication without downloading a model.

R1a established the persistent numerical and publication lifecycle. R1b added
atomic start for a shared scheduler. R1c adds the preferred `SessionV2` bridge
to the Common Model Contract while preserving the R1b transaction underneath.
R1d layers the preferred fixed-length `SessionV3` terminal-result lifecycle
over that bridge. R1e adds canonical non-terminal state capture and detached
output/RNG/contiguous-KV materialization without transferring publication
authority. R1f adds exact-current-boundary state-buffer rebind inside the
original same-process Session while preserving that authority. R1g derives a
canonical successor execution plan, residency binding, transcript segment, and
target ownership intent without creating target authority. R1h-a consumes
those records into a fresh barrier-held target bootstrap. R1h-b reserves
receipt-funded ownership, materializes exact checkpoint state, and commits a
process-local runnable target at the restored publication sequence. The durable
handoff slice adds a canonical five-object restart archive, exact source exit,
an exclusive selector lease, one-shot restored activation, and a
receipt-independent terminal-semantic comparison across separate processes.
These are integrated experimental slices, not the completed R1 text runtime.

## Supported envelope

| Concern | Current experimental contract |
| --- | --- |
| Artifact | A mapped prepared `.glrt` image with the separate MLP layout |
| Artifact identity | Source fingerprint, ABI fingerprint, container byte length, and full container SHA-256 |
| Prompt | Caller-provided `[]const u32` token IDs |
| Sampling | Greedy (`temperature = 0`) with a sealed seed |
| Execution | One thread, serial attention, materialized decode state, checked decode plan |
| Numerical policy | Common execution declares `implementation_defined`; retained evidence compares output tokens with the configured oracle |
| Length | A nonzero, fixed `max_new_tokens` service count |
| Common contract | `BoundPlanV1` cross-binds the local plan, request-profile artifact manifest, sequence execution plan, and residency projection |
| Admission | `SessionV3.start` validates the complete binding before `SessionV1.start` derives the exact request claim and work quanta |
| Residency | Shared read-only `.glrt`; total logical claim and request-charged claim remain distinct |
| R1c profile gate | The local activation claim must satisfy the Common Execution Plan's exact token-input byte lower bound |
| Publication | One `LaneWeave` service permit commits one token transaction; one terminal seal advances result state from zero to one |
| Mutable state | Session-owned KV rows, RNG state, sampling count, and output token buffer |
| Evidence | `BoundarySnapshotV2` binds the live execution boundary; `TerminalResultEvidenceV1` joins it to the canonical output and actual charged receipt |
| R1e checkpoint | Canonical non-terminal output/RNG/KV image with independent Zig/Python verification and detached zero-slack materialization |
| R1f rebind | Internally verified replacement of concrete output/KV backing at the exact current boundary while all live authority remains in the original Session |
| R1g successor evidence | Read-only canonical 768-byte execution plan, 256-byte residency binding, and 512-byte transcript segment with source lineage, logical-KV identity, and target ownership intent |
| R1h-a restored admission | Fresh target admission and receipt, a queue-free receipt-funded LeaseTree with one zero-current-claim scope, exact sequence and Bank permit-generation remap, and a process-local bootstrap root held behind the adoption barrier |
| R1h-b restored activation | Charge-before-materialize target `SessionV3`, publication ABI v2 with global `sequence_base`, funded ownership without duplicate aggregate charge, one retained next-token comparison, and barrier-held close to zero |
| Durable source handoff | Address-stable source-live grant under the exclusive selector lease; exact publication-handoff barrier and source-exit receipt; generation-two selection only after the source lane, receipt, and publication binding close |
| Fresh-process target authority | Five-object canonical restart archive, selector-selected generation-two source exit, lease-backed one-shot activation grant retained through cancellation or generation-three terminal selection and retirement |
| Terminal comparison | Receipt-independent terminal semantic joining model/request identity, token domains, output, logical KV, RNG, sampling state, and final position across separately completed baseline and target runs |

`eos_token` must be outside the model vocabulary in this version. Fixed-length
execution keeps the admitted service count identical to the number of
publication transactions.

## Preferred prepared-text lifecycle

1. Load a prepared image with `loader.loadPreparedWithOptions`.
2. Build `prepared_text_session.OptionsV1`, then derive the canonical
   `PlanV1` with `makePlanV1`. The plan binds the exact image identity, prompt
   digest and length, fixed output length, seed, and request claim.
3. Supply nonzero token-domain, token-domain-configuration, and artifact-license
   roots in `BoundPlanInputV1`, then call `makeBoundPlanV1`. These three roots
   are caller assertions: this API binds them but does not inspect or attest
   the bytes they name.
4. The resulting `BoundPlanV1` joins the local plan to an autoregressive
   `generate_sequence` artifact and `implementation_defined` execution profile.
   The execution plan's claim describes total logical resources, including the
   mapped `.glrt`.
   `ExecutionResidencyBindingV1` declares that mapping `shared_read_only` and
   projects the total to the exact request-charged local claim. Construction
   returns `InvalidBoundPlan` if the local activation claim is smaller than the
   Common Execution Plan's exact `u32` prompt-input byte count.
5. Retain `BoundPlanInputV1` independently and pass it with the bound plan to
   `SessionV3.start`. It reconstructs and compares the artifact, execution,
   residency, and local-plan binding before admission, so a coherently re-rooted
   token-domain or license substitution cannot authorize itself. It then
   installs those roots at the Session's final address and delegates to the
   atomic R1b start path. The caller does not admit the request separately.
6. Before request-owned materialization, `LaneWeave` either returns
   `SequenceOverflow` when it cannot reserve the required Event-v1 capacity,
   emits the ordinary rejection event when slack permits, or commits the exact
   `ResourceBank` charge and returns a sealed, single-use publication adoption
   authority. The scheduler-wide adoption barrier is active before its mutex
   is released.
7. While that barrier is active, `start` allocates the session resources and
   performs prefill. It then atomically converts the adoption authority into
   the exact every-service publication binding. If allocation, prefill, or
   binding fails, `start` consumes the authority through cancellation: the
   accepted admission is followed by a normal cancellation event and the
   committed resource claim is released. If cancellation returns a transient
   cleanup error, `start` returns `RecoveryRequired` and the Session retains
   the exact, single-use cancellation authority. After the transient condition
   is resolved, `recoverStartAdoption` retries that cancellation only.
8. Repeatedly obtain the next service permit from the same scheduler and pass
   it to `step` with a `lane_publication_txn.SinkV1`. Each successful step
   publishes exactly one token and commits the corresponding KV/RNG/output
   transition.
9. Call `SessionV3.snapshotVerified` at an idle boundary when evidence is
   needed. It revalidates the bound plan before emitting `BoundarySnapshotV2`.
   A consumer that already holds the expected `BoundPlanV1` and local `PlanV1`
   should verify the join with `boundarySnapshotValidForBoundPlanV2`.
10. At an eligible non-terminal boundary, optionally call
    `captureCheckpointV1`; the same exact image can be detached, rebound into
    the original Session, or passed to `captureSuccessorArtifactsV1` with
    independently selected target ownership intent. Successor capture derives
    canonical plan/residency/transcript records and exact-compares the complete
    live source context before and after the read-only operation. The result is
    evidence by itself; it creates no target receipt, permit, Session, or
    publication authority. The two-stage R1h path requires an independently
    verified selected source-exit grant before it can consume the records.
11. For an in-process composition test, initialize one
    `SelectedSourceExitGrantV1` from the exact selector-selected generation two
    while holding its exclusive lease. For the durable path, the source first
    binds generation one to its address-stable source-live grant, captures the
    five-object restart archive, commits the publication handoff, and selects
    generation two before exiting. A fresh target opens that generation and
    creates the one-shot activation grant; checkpoint bytes alone are
    insufficient.
12. Place a zeroed target `SessionV3` at its final address. Pass
    `target.restoredPublicationSessionIdV1()`, the exact records and retained
    context, and the same activation grant to
    `prepareRestoredAdmissionV1` on a fresh LeaseTree-enabled target
    Scheduler/Bank.
    Pattern-match every `PrepareDecisionV1` branch. `rejected` carries only the
    policy event and no live capability. `recovery_required` carries a
    process-local `PrepareRecoveryV1`; retain it and call
    `recoverPrepareRestoredAdmissionV1` until rollback returns its cancellation
    event. `prepared` carries the fresh receipt, empty receipt-funded tree,
    restored `N/G`, and non-runnable adoption barrier. Either abort it before
    activation, or pass the same capability, checkpoint evidence, compatible
    model/prompt/options/local plan, and source bound plan to
    `target.startRestoredV1`. If startup returns `RecoveryRequired`, retain both
    values and call `recoverRestoredStartV1`; then abort the still-prepared
    bootstrap explicitly. After success the prepared capability is
    `.activated`, the grant is `.consumed`, and neither may be aborted. The
    target can acquire its first service permit and call `step`. A durable
    terminal target selects generation three with the exact terminal semantic
    before `retire`; a non-terminal cancellation leaves generation two
    retryable. Finish with restored `cancel` or `retire`, retrying
    `recoverRestoredCloseV1` if teardown reports recovery required. The lower
    publication/contiguous restored initializers are composition points; their
    ordinary close entry points reject funded-tree ownership.
13. On the ordinary, non-restored lifecycle, call `sealTerminalResult` after
    the fixed final token. It computes the canonical little-endian `u32` output
    root, joins it to the V2 boundary and source mapping, validates the actual
    request-charged receipt against both the live Bank publication session and
    the residency projection, and on success advances the terminal-result
    publication state exactly once from zero to one. The envelope context binds
    the exact artifact, execution plan, prompt/schema roots, cache identity,
    ownership root, publication challenge, and adapter evidence.
14. Read the sealed `TerminalResultEvidenceV1` through `terminalResult` and
    validate it against the independently retained bound/local plans and exact
    output tokens. If the original Receipt is retained independently, use
    `terminalResultEvidenceValidForReceiptV1` to reject substitution by a
    different structurally valid receipt. Calling `sealTerminalResult` early or
    a second time rejects without changing the retained result evidence.
15. For that ordinary lifecycle, call `retire` only after sealing. Before
    sealing, call `cancel` instead. Cancellation is not valid after a terminal
    result becomes visible. Always call `deinit` to release the session's local
    allocations.

The adoption barrier seals the admission, scheduler identity, publication
request epoch, address-stable session identity, service policy, and a
single-use generation. While resource allocation and prefill are in progress,
other logical mutators on the same scheduler fail with `AdoptionInFlight`.
After adoption commits or cancels, normal shared-scheduler use resumes.

## R1e detached checkpoint materialization

At an idle boundary after at least one output and before the fixed terminal
token, `SessionV3.captureCheckpointV1` can capture a canonical state image. The
method revalidates the V2 boundary, bound plan, initial result-publication
state, nested receipt, live Bank address fence, request epoch, and current
publication sequence before serializing any state.

The image contains:

- independently matchable local-plan, bound-plan, artifact, execution,
  residency, boundary, transcript, state-commitment, and challenge roots;
- output tokens as canonical little-endian `u32`;
- four raw RNG words and the exact sampling count;
- committed contiguous KV values ordered by layer, K prefix, then V prefix,
  with every `f32` preserved as raw little-endian bits; and
- component roots plus a domain-separated whole-image root.

`prepared_text_checkpoint.decodeCheckpointV1` reconstructs the output chain,
RNG root, full logical KV root, incremental publication KV chain, and complete
state commitment. It also compares every contextual root and exact scalar
context—request epoch, sequence, bounds, vocabulary, geometry, output count,
and sampling count—with `ExpectedBindingsV1`, which the caller must retain
independently.
`materializeDetachedV1` then allocates a new output buffer and KV cache, zeros
all capacity, and copies only the committed prefixes.

That new value is deliberately detached: it contains no Scheduler, Bank,
receipt, permit, sink, mutex, or publication Session. It cannot run the next
token or publish output by itself. R1f lets only the original live Session
rematerialize and install its exact current state while retaining the existing
embedded-coordinator address, sequence, and authority. Constructing a different
or fresh-process Session still requires successor-plan, Scheduler,
ResourceBank, ownership-remapping, durability, and exclusive-handoff protocols.
Both the encoded slice and detached allocations are caller-owned and are not
charged to the live Session's `ResourceBank`.

Sequence zero is rejected because its next token depends on prefill logits,
which are not in the image. Terminal, sealed, cancelled, retired,
recovery-adoption, active-row, and stale-boundary capture also reject. The
fixed profile enforces:

```text
0 < output_count = next_sequence = sampling_calls < max_new_tokens
kv_positions = prompt_tokens + output_count - 1
max_kv_positions = prompt_tokens + max_new_tokens - 1
```

See [Prepared Text Checkpoint](PREPARED_TEXT_CHECKPOINT.md) for the exact wire,
ownership boundary, tests, and path from detached materialization to a safe
fresh-process continuation.

## R1f same-process state-buffer rebind

At the same R1e boundary, the original live Session can install the canonical
image without transferring authority:

```zig
const checkpoint_root = try session.rebindCheckpointV1(
    checkpoint_bytes,
    checkpoint_challenge,
);
```

The method derives `ExpectedBindingsV1` from the live Session rather than from
the image. It validates the current V2 boundary, retained plans, result state,
nested receipt, exact ResourceBank fence, publication sequence, and
address-stable ownership wiring; decodes and materializes internally with the
Session allocator; then validates the same live context again. It also compares
the exact committed output and raw KV bytes, RNG/counters, geometry, publication
KV root, and zero slack.

Only after every fallible check succeeds does the method replace the values of
the existing cache and output fields and release their former allocations. The
embedded publication coordinator at `&publication_session.inner`, Scheduler,
ResourceBank, receipt, request epoch, sequence, transcript/state roots,
cache-field address, and RNG/counter/output-length field addresses remain
unchanged. No service permit is consumed and no Scheduler or Bank event is
emitted. The next ordinary `step` recomputes logits and follows the same
transition as the uninterrupted path.

Rebinding the same exact boundary can safely repeat, but a checkpoint becomes
stale as soon as the Session advances. Active KV row transactions, copied or
moved Sessions, recovery-adoption state, sequence zero, terminal state, and
context substitution reject before takeover. A successful rebind invalidates
all previously borrowed output/cache slices and row-transaction marks.

The retained integration test holds one service permit across rebind and uses
that exact permit for the next ordinary step. It compares the whole token
transition plus output, RNG, sampling count, and logical KV state with a
separate uninterrupted Session. A phase-gated allocator sweeps every candidate
allocation failure and verifies complete Session/Scheduler/Bank/pointer
preservation with no leaked candidate.

This is not a new Session, authority transfer, fresh-process restore, durable
checkpoint publication, rewind, or concurrent mutation protocol. Candidate and
old allocations coexist briefly without changing the logical ResourceBank
claim; that overlap is not physical peak-memory evidence.

R1f requires exclusive access to the Session and its bound receipt authority
for the entire call. It does not hold the scheduler-wide adoption barrier while
materializing, and unrelated work on the same Scheduler is not blocked or
validated by rebind. R1f is not a concurrent Session or authority-mutation
protocol. If a caller already holds a service permit, the Scheduler's ordinary
pending-service fence may independently reject other logical mutators with
`ServiceInFlight`; that fence belongs to the permit, not to rebind.

## R1g canonical successor evidence

At the same exact non-terminal checkpoint boundary, the original live Session
can derive pointer-free successor evidence without replacing state or
transferring authority:

```zig
const artifacts = try session.captureSuccessorArtifactsV1(
    checkpoint_bytes,
    checkpoint_challenge,
    target_ownership_intent,
);
```

The helper derives the checkpoint expectations and source context from the live
Session. It joins the exact checkpoint to the current bound plan, canonical
source execution plan and residency binding, V2 boundary, publication
transcript, and actual retained receipt. It then produces:

- a canonical 768-byte Common Model Contract successor execution plan whose
  generation advances by one and publication base starts at the current `N`;
- a canonical 256-byte residency projection for that successor plan; and
- a fixed 512-byte transcript segment binding source lineage, state/logical KV,
  successor roots, checkpoint challenge, and target ownership intent.

Artifact/model/operation/shape/policy/resource bindings remain unchanged. The
successor plan changes only its generation, publication base, previous-plan
lineage, logical-KV cache payload, ownership-intent root, challenge, and
recomputed plan root. `captureSuccessorArtifactsV1` derives the complete live
context again after construction and exact-compares it with the initial
context. Any concurrent or stale change rejects; successful capture changes no
Session, Scheduler, Bank, receipt, sequence, transcript, result state, output,
KV, RNG, or counter.

The target record names a proposed fresh Bank/owner, scheduler/coordinator,
LeaseTree/cache identities, successor generations, and the exact request
claim. Its root is ownership intent only. It does not prove restored admission,
acquire a receipt or service permit, remap publication ownership, exit the
source, create a runnable Session, or establish target exclusivity. Calls must
be serialized with every operation on the Session and its bound receipt.

See
[Prepared Text Successor Evidence](PREPARED_TEXT_SUCCESSOR.md) for the exact
plan projection, segment offsets, root domains, mutation gates, and the R1h
evidence boundary. See
[Prepared Text Restore Admission](PREPARED_TEXT_RESTORE_ADMISSION.md) for the
live R1h-a bootstrap and R1h-b activation boundary.

## R1h-b receipt-funded restored activation

`SessionV3.startRestoredV1` accepts only the final Session address named by the
R1h-a bootstrap and the same address-stable source-exit activation grant that
prepared it. It revalidates the complete portable and live context, derives the
successor bound plan, and reserves one queue-free allocation covering all
request-local byte classes. The tree uses `receipt_funded`, so the allocation
is exact ownership within the immutable receipt rather than a second aggregate
charge.

After reservation, the target allocates its normal execution resources and
uses `materializeIntoV1` to copy and revalidate checkpoint output, contiguous
KV, RNG, and sampling state. The final fallible operation commits the funded
batch and pending Scheduler adoption. Before that commit, service remains
blocked; after it, the target is a runnable Session and the prepared capability
is `.activated`. The activation grant advances from `.prepared` to `.consumed`
and remains retained by the Session.

Publication ABI v2 distinguishes the global transaction sequence from
target-local completed service. A restored Session starts with:

```text
sequence_base = next_sequence = output_length = sampling_calls = N
target-local completed service = 0
last Bank publication permit generation = G
```

Its first proposal therefore uses `transaction_sequence = N`, the checkpoint
predecessor transcript, and Bank permit `G + 1`. The retained synthetic-model
integration compares that transition with an uninterrupted reference,
including output tokens, logical KV, RNG, and sampling count.

Restored close first acquires a Scheduler no-service barrier. It then retires
and authorizes the funded allocation, frees Session backing, commits the
allocation free, and atomically closes the publication namespace, empty tree,
parent receipt, and Scheduler lane. Explicit recovery phases retain authority
after any reported cleanup failure. The R1h-b transaction remains
process-local; the durable handoff layer supplies and retains the selected
lease/grant authority around it.

`SessionV3.start` remains a correctness-first startup transaction rather than a
non-blocking startup mechanism. Its adoption barrier deliberately prevents the
same scheduler from admitting, servicing, cancelling, retiring, or closing
logical work while startup allocation and prefill are in progress. A future
staged activation design must preserve the same charge-before-materialize and
replay guarantees before allowing concurrent scheduler progress.

## Durable fresh-process handoff

The durable layer composes R1e through R1h-b without serializing any live
Session authority:

```text
generation 1: source live under exclusive lease and source-live grant
        │ exact handoff barrier + source exit
        ▼
generation 2: source-exited receipt + five-object restart archive
        │ exclusive target lease + one-shot activation grant
        ▼
generation 3: receipt-independent terminal semantic + exact lineage
```

The restart archive contains the checkpoint, successor execution plan,
successor residency binding, successor transcript segment, and canonical
restart manifest. The manifest carries prompt tokens, options, local and bound
plans, checkpoint expectations, source context/receipt evidence, and target
ownership as pointer-free canonical records. A fresh target decodes this object
instead of reconstructing native source structures or trusting a JSON sidecar.

The source-live grant owns the lease's only consumer claim and is fenced by its
address. It is bound to the live source Scheduler/coordinator/Bank, request,
sequence `N`, last publication-permit generation `G`, and receipt. Beginning
handoff changes the grant phase; abort returns it to the live bound phase,
while commit closes the exact source publication authority. Completion accepts
only the immediate generation-two selector, then advances and releases the
consumer claim.

The target activation grant likewise owns the lease's only consumer claim.
`prepareRestoredAdmissionV1` and `startRestoredV1` require that exact
address-stable value. A second concurrent grant, copied grant, selector drift,
lease drift, or phase replay rejects. Releasing a non-terminal grant permits a
fresh retry against generation two. The restored Session keeps its active grant
until a non-terminal cancellation or until the exact generation-three terminal
semantic has been selected.

The retained `prepared-text-live-restart-demo` runs a completed baseline
worker, a source worker that selects generation two and exits, and a different
target worker that resumes at `N`, selects generation three, and matches the
baseline terminal semantic. It also checks exclusive locking, no source
resurrection, no duplicate sequence in the retained run, and zero final
Scheduler/Bank/LeaseTree ownership.

This is not yet exactly-once external delivery across every crash window. A
source death before generation two leaves generation one selected and the
request unavailable. A target death after external output but before
generation three can retry generation two and replay from `N`. Production use
therefore needs an idempotent sink keyed by request/global sequence; an
acknowledged durable progress generation remains roadmap work. The current
durable adapter is POSIX-only. Windows durable files, GPU/device-resident
continuation, and native multi-OS recovery campaigns remain roadmap work.

See
[Durable Prepared-Text Handoff](PREPARED_TEXT_DURABLE_HANDOFF.md) for the
generation layouts, lease/grant lifecycle, demo command, and exact nonclaims.

## Compatibility lifecycles

`SessionV1.start` remains the R1b atomic-start path without the Common Model
Contract bridge. `SessionV1.init` remains available for integrations that
already hold a successful admission. The `init` path retains the R1a exclusive
boundary: no thread may call the same scheduler between successful admission
and the return from `init`. `SessionV2` remains the R1c boundary API without
the R1d terminal-result state. New fixed-length integrations should use
`SessionV3.start`.

The V1 boundary snapshot has a canonical root over the local plan, exact image
identity, committed state, sequence position, and publication transcript.
`BoundarySnapshotV2` adds the bound-plan, artifact, execution-plan, and
residency-binding roots. `boundarySnapshotValidV2` checks only that this root
list is internally canonical; `boundarySnapshotValidForBoundPlanV2` also
requires those roots to match the expected bound plan, canonical local plan,
and complete prepared-image identity, including its source and ABI
fingerprints. The boundary root binds publication `sequence_base`, and
contextual validation requires it to equal the execution plan's declared
publication start.
These are live in-process evidence groupings, not splice-resistant historical
attestations or checkpoint payloads. They do not contain the KV or model bytes
required to restore the Session in another process.

## Ownership rules

- The caller keeps the loaded model alive for the entire session.
- The caller owns the scheduler, bank storage, and downstream sink; the session
  borrows them for the active lifecycle.
- `SessionV3` and its inner Sessions must already be at their final address
  before `start` or before their address is supplied to R1h-a. Do not move,
  copy, mutate, or concurrently access them during initialization, active
  publication, or recovery.
- The Common Model Contract artifact manifest is a request-profile identity:
  prompt and output dimensions affect its root. It is not a stable package
  identity. Its `weights_sha256` remains the exact mapped `.glrt` container
  digest.
- `token_domain_sha256`, `token_domain_config_sha256`, and the artifact-license
  root are opaque caller assertions. Binding a digest does not verify the
  asserted tokenizer, configuration, license, or provenance. The caller must
  retain the expected `BoundPlanInputV1` independently through `SessionV3.start`;
  deriving those expectations back from the supplied bound plan would make a
  coherent substitution self-authorizing.
- The execution plan includes the shared read-only `.glrt` bytes in its total
  logical claim. The residency binding removes those resident bytes from the
  exact request-charged claim. This does not prove physical sharing, process
  RSS, page residency, deduplication, or ownership of the mapping.
- R1c does not cover every valid `SessionV1` shape. In particular, a
  long-prompt/minimal-model profile can have a local activation claim below the
  Common Execution Plan's prompt-input byte lower bound and therefore fail
  `makeBoundPlanV1` before admission. Reconciling that ownership and accounting
  boundary is a later milestone.
- The preferred `start` path derives the admitted claim and service count from
  the validated local plan and residency binding. Callers cannot substitute a
  different request claim or `work_quanta` value at that boundary.
- Event capacity is derived from occupied scheduler slots. Accepted work
  reserves its admission event, all `plan.max_new_tokens` service events, and
  one terminal event; unrelated semantic events consume only slack. Near
  sequence exhaustion, an otherwise-rejected start can return
  `SequenceOverflow` instead of emitting a rejection event. No additional ABI,
  snapshot, or scheduler-state field carries this reservation.
- The adoption authority and barrier are process-local operational state. The
  accepted admission and rollback cancellation retain the existing Event-v1
  evidence; the barrier is not a new semantic scheduler event or durable
  capability.
- The durable selector, source-exit receipt, restart archive, and terminal
  semantic are portable evidence. Source-live and target activation grants,
  lease consumer claims, prepared admissions, receipts, permits, and Sessions
  are process-local authority and must remain at their final addresses.
- A live lease consumer claim permits only one source-live or target activation
  grant. Closing the durable lease while that claim is retained rejects; a
  copied/moved grant or selector-generation drift cannot be used to activate a
  Session.
- A receipt-funded tree partitions queue-free allocator ownership within the
  immutable request receipt. It does not reduce, replace, or add to the
  Scheduler/Bank aggregate charge and does not prove physical memory use.
- Same-scheduler logical mutation during `start` fails with
  `AdoptionInFlight`; it must be retried only after `start` returns.
- A successful `SessionV1.init` adopts the supplied admission. The caller must
  not service, cancel, or retire that request independently afterward.
- If initialization fails after receipt adoption begins, the session cancels
  that admission before returning the error. This cleanup relies on the same
  exclusive boundary. Pre-validation failures leave the caller's scheduler
  state unchanged.
- A successful `step` is the only point where the staged KV row, RNG state,
  sampling count, and output token become visible together.
- A numerical error before publication aborts the caller-supplied pending
  service permit; failure to restore that scheduler boundary is reported as a
  recovery-required error.
- If `SessionV3.start` returns `RecoveryRequired`, the common binding and exact,
  single-use cancellation authority remain installed. Do not overwrite or move
  the Session while that authority is live. After the transient cleanup error
  is resolved, call `recoverStartAdoption` to retry cancellation. This API
  neither diagnoses nor repairs Scheduler or Bank state.
- If restored startup returns `RecoveryRequired`, call
  `recoverRestoredStartV1` with the same prepared capability before moving or
  dropping either value. If restored close returns `RecoveryRequired`, retry
  `recoverRestoredCloseV1`; the no-service barrier remains held.
- For an ordinary Session, `SessionV3.retire` requires a sealed terminal result
  and cancellation is valid only before sealing. A restored finished Session
  retires through its funded-tree close path. In the durable composition, that
  terminal close additionally requires the activation grant to observe the
  exact generation-three terminal semantic. The `deinit` safety path closes a
  live restored Session, but explicit cleanup is required for a retained
  startup recovery.
- Self-contained terminal-evidence validation reconstructs and checks the
  envelope's Receipt fields but does not prove current Bank authority. Live
  authority is checked during sealing; later consumers need an independently
  retained Receipt for exact receipt-substitution resistance.

## Retained evidence

The model fixture `compact multi-page INT4 generation matches eager generation`
in [`tests/model_forward.zig`](../tests/model_forward.zig) builds a tiny
synthetic source model and prepares and maps its `.glrt` image. Together with
the LaneWeave publication-adoption unit tests, the retained evidence verifies:

- exact token equivalence with the configured numerical oracle;
- rejection of in-vocabulary early EOS;
- exact admission-claim and service-count binding;
- plan-derived admission claim and work quanta through `SessionV1.start`;
- canonical total-to-request claim projection for request-owned and shared
  read-only artifact residency, including mutation, substitution, and overflow
  rejection in the Model Contract tests;
- charge-before-materialize ordering and rejection before request allocation;
- same-scheduler mutation rejection while adoption is in flight, covered by
  `LaneWeave publication adoption is snapshot invisible and cancel compatible`;
- accepted-admission-to-cancellation rollback after injected initialization
  failure, with the scheduler reusable afterward;
- one downstream commit per output token with no abort;
- canonical plan/image/publication boundary grouping and mutation rejection;
- a canonical little-endian `u32` terminal output root and V2-bound source
  mapping;
- one residency-aware `ResultEnvelopeV1` carrying the exact request-charged
  receipt rather than the total logical claim;
- early, duplicate, and substituted terminal-result rejection before state
  mutation;
- shared Zig/Python artifact/plan/residency/result wire, Receipt-integrity, and
  terminal output/source/evidence root goldens with adversarial mutation
  coverage;
- canonical successor execution-plan/residency/ownership-intent/transcript
  roots shared with an independent Python verifier, including every-byte,
  length, coherent foreign-context, and contextual-substitution rejection;
- read-only successor capture with exact before/after Session, Scheduler, Bank,
  receipt, boundary, sequence, and state preservation;
- coherent foreign live-target rejection before Scheduler/Bank mutation;
- barrier-held restored admission with an exact receipt, allocation-empty
  queue-free receipt-funded LeaseTree, sequence `N`, source permit floor `G`,
  and rejection of the ordinary flat adoption commit;
- exact restored-admission validation against independently retained R1g
  records and live target state;
- reverse-order restored-admission abort to zero, retained setup-recovery
  authority, resumable cleanup phases, and stale copied-capability rejection
  after the first winner;
- receipt-funded allocation activation without aggregate Scheduler/Bank growth,
  mode-splicing rejection, and copied activation/abort single-winner behavior;
- restored publication ABI v2 with global base `N`, first transaction `N`,
  predecessor transcript continuity, and first target Bank permit `G + 1`;
- one restored synthetic-model transition matching uninterrupted output,
  logical KV, RNG, and sampling state under an exact target hard limit;
- barrier-held restored cancellation returning the target receipt, tree, scope,
  allocation, Scheduler lane, and aggregate usage to zero;
- canonical restart-manifest round-trip and contextual substitution rejection;
- source-live grant copy/duplicate/selector-drift rejection and exact
  generation-one-to-two completion;
- generation-two one-shot target-grant retention through restored activation,
  duplicate-grant rejection, and generation-three terminal selection;
- separate baseline, source, and target workers with distinct source/target
  process IDs, exclusive lease evidence, terminal-semantic equality, and zero
  source/target logical ownership;
- pending-permit rollback after an injected pre-publication failure;
- zero used resources after retirement;
- zero used resources after an injected initialization-allocation failure.

The R1g path does not claim that its request-profile manifest is a stable package
identity or that shared logical residency proves physical RSS. It does not
execute a raw-text tokenizer, verify the caller-asserted token-domain,
configuration, or license bytes, publish the terminal envelope to a durable
external sink, serialize a durable checkpoint, transfer publication authority
to another Session, acquire a restored target receipt/permit, or resume the
prepared session in a fresh process. Its checkpoint, same-process rebind, and
successor evidence are not authenticated/encrypted storage or a fresh
authority-construction protocol. It also does not bridge
every V1-valid request shape: profiles whose local activation accounting falls
below the common token-input byte bound remain outside R1g. `SessionV3`
requires exactly
`max_new_tokens` outputs and does not support early EOS or a shorter terminal
sequence; `SessionV2` remains available as the R1c boundary API. The fixture
does not establish production-model quality, native performance evidence,
tokenizer interoperability, strict cross-platform numerical equivalence, or
concurrent same-scheduler progress during startup.

R1h-a by itself remains a non-runnable bootstrap: its caller-reserved session
identity is an address-sized future binding rather than proof that activation
succeeded. R1h-b can consume that exact capability into a process-local target.
The durable composition adds selected source exit, exclusive fresh-process
activation, and receipt-independent terminal-semantic equivalence, but it does
not recover a source crash before generation two, suppress target replay before
generation three, provide exactly-once external delivery without an idempotent
sink, implement Windows durable files, continue GPU-resident state, or establish
production-model/native-platform performance.

`BoundPlanV1`, `ExecutionResidencyBindingV1`, and the Session bridge are still
an experimental Zig/direct API. There is no fixed `BoundPlanV1` wire, projected
C verifier, or retained `.generate_sequence` `SupportRecordV1` yet. The
residency-aware artifact/plan/result projection and terminal roots have shared
Zig/Python goldens; broader cross-language ABI and support-registry parity
remain future work. The API may change while R1 is active.
