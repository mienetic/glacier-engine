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
authority. These are integrated experimental slices, not the completed R1 text
runtime.

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

`eos_token` must be outside the model vocabulary in this version. Fixed-length
execution keeps the admitted service count identical to the number of
publication transactions.

## Preferred R1d/R1e lifecycle

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
10. After the fixed final token, call `sealTerminalResult`. It computes the
    canonical little-endian `u32` output root, joins it to the V2 boundary and
    source mapping, validates the actual request-charged receipt against both
    the live Bank publication session and the residency projection, and on
    success advances the terminal-result publication state exactly once from
    zero to one. The envelope context binds the exact artifact, execution plan,
    prompt/schema roots, cache identity, ownership root, publication challenge,
    and adapter evidence.
11. Read the sealed `TerminalResultEvidenceV1` through `terminalResult` and
    validate it against the independently retained bound/local plans and exact
    output tokens. If the original Receipt is retained independently, use
    `terminalResultEvidenceValidForReceiptV1` to reject substitution by a
    different structurally valid receipt. Calling `sealTerminalResult` early or
    a second time rejects without changing the retained result evidence.
12. Call `retire` only after sealing. Before sealing, call `cancel` instead.
    Cancellation is not valid after a terminal result becomes visible. Always
    call `deinit` to release the session's local allocations.

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
token or publish output. The current authority is bound to the exact live
Session address and sequence, so creating a runnable Session from these bytes
requires a later successor-plan, Scheduler, ResourceBank, and publication
handoff protocol.
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

This is a correctness-first startup transaction, not a non-blocking startup
mechanism. It deliberately prevents the same scheduler from admitting,
servicing, cancelling, retiring, or closing logical work while materialization
is in progress. A future staged activation design must preserve the same
charge-before-materialize and replay guarantees before allowing concurrent
scheduler progress.

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
fingerprints.
These are live in-process evidence groupings, not splice-resistant historical
attestations or checkpoint payloads. They do not contain the KV or model bytes
required to restore the Session in another process.

## Ownership rules

- The caller keeps the loaded model alive for the entire session.
- The caller owns the scheduler, bank storage, and downstream sink; the session
  borrows them for the active lifecycle.
- `SessionV3` and its inner Sessions must already be at their final address
  before `start`. Do not move, copy, mutate, or concurrently access them during
  initialization, active publication, or adoption recovery.
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
- `SessionV3.retire` requires a sealed terminal result, while cancellation is
  valid only before sealing. The `deinit` safety path still closes an adopted
  lifecycle, but explicit sealing plus retirement or pre-seal cancellation is
  preferred when the caller needs the resulting evidence and scheduler event.
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
- pending-permit rollback after an injected pre-publication failure;
- zero used resources after retirement;
- zero used resources after an injected initialization-allocation failure.

R1e does not claim that its request-profile manifest is a stable package
identity or that shared logical residency proves physical RSS. It does not
execute a raw-text tokenizer, verify the caller-asserted token-domain,
configuration, or license bytes, publish the terminal envelope to a durable
external sink, serialize a durable checkpoint, transfer publication authority,
or resume the prepared session in a fresh process. Its checkpoint image is a
portable integrity and detached-materialization boundary, not a resumable
Session or authenticated/encrypted storage. It also does not bridge every
V1-valid request
shape: profiles whose local activation accounting falls below the common
token-input byte bound remain outside R1e. `SessionV3` requires exactly
`max_new_tokens` outputs and does not support early EOS or a shorter terminal
sequence; `SessionV2` remains available as the R1c boundary API. The fixture
does not establish production-model quality, native performance evidence,
tokenizer interoperability, strict cross-platform numerical equivalence, or
concurrent same-scheduler progress during startup.

`BoundPlanV1`, `ExecutionResidencyBindingV1`, and the Session bridge are still
an experimental Zig/direct API. There is no fixed `BoundPlanV1` wire, projected
C verifier, or retained `.generate_sequence` `SupportRecordV1` yet. The
residency-aware artifact/plan/result projection and terminal roots have shared
Zig/Python goldens; broader cross-language ABI and support-registry parity
remain future work. The API may change while R1 is active.
