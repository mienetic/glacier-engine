# Prepared Text Session

The prepared text session is an experimental Zig API for one bounded,
in-process text-generation lifecycle. It connects an exact prepared `.glrt`
image, one prompt, one resource admission, serial greedy execution, and
transactional token publication without downloading a model.

R1a established the persistent numerical and publication lifecycle. R1b added
atomic start for a shared scheduler. R1c adds the preferred `SessionV2` bridge
to the Common Model Contract while preserving the R1b transaction underneath.
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
| Admission | `SessionV2.start` validates the complete binding before `SessionV1.start` derives the exact request claim and work quanta |
| Residency | Shared read-only `.glrt`; total logical claim and request-charged claim remain distinct |
| R1c profile gate | The local activation claim must satisfy the Common Execution Plan's exact token-input byte lower bound |
| Publication | One `LaneWeave` service permit commits one token transaction |
| Mutable state | Session-owned KV rows, RNG state, sampling count, and output token buffer |
| Evidence | `BoundarySnapshotV2` binds the V1 boundary plus bound-plan, artifact, execution-plan, and residency roots |

`eos_token` must be outside the model vocabulary in this version. Fixed-length
execution keeps the admitted service count identical to the number of
publication transactions.

## Preferred R1c lifecycle

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
   `SessionV2.start`. It reconstructs and compares the artifact, execution,
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
9. Call `SessionV2.snapshotVerified` at an idle boundary when evidence is
   needed. It revalidates the bound plan before emitting `BoundarySnapshotV2`.
   A consumer that already holds the expected `BoundPlanV1` and local `PlanV1`
   should verify the join with `boundarySnapshotValidForBoundPlanV2`.
10. After the fixed final token, call `retire`. Before completion, call `cancel`
   instead. Always call `deinit` to release the session's local allocations.

The adoption barrier seals the admission, scheduler identity, publication
request epoch, address-stable session identity, service policy, and a
single-use generation. While resource allocation and prefill are in progress,
other logical mutators on the same scheduler fail with `AdoptionInFlight`.
After adoption commits or cancels, normal shared-scheduler use resumes.

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
and the return from `init`. New integrations should use `SessionV2.start`.

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
- `SessionV2` and its inner Session must already be at their final address
  before `start`. Do not move, copy, mutate, or concurrently access them during
  initialization, active publication, or adoption recovery.
- The Common Model Contract artifact manifest is a request-profile identity:
  prompt and output dimensions affect its root. It is not a stable package
  identity. Its `weights_sha256` remains the exact mapped `.glrt` container
  digest.
- `token_domain_sha256`, `token_domain_config_sha256`, and the artifact-license
  root are opaque caller assertions. Binding a digest does not verify the
  asserted tokenizer, configuration, license, or provenance. The caller must
  retain the expected `BoundPlanInputV1` independently through `SessionV2.start`;
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
- If `SessionV2.start` returns `RecoveryRequired`, the common binding and exact,
  single-use cancellation authority remain installed. Do not overwrite or move
  the Session while that authority is live. After the transient cleanup error
  is resolved, call `recoverStartAdoption` to retry cancellation. This API
  neither diagnoses nor repairs Scheduler or Bank state.
- `retire`, `cancel`, and the `deinit` safety path close the adopted
  publication lifecycle. Explicit retirement or cancellation is preferred when
  the caller needs the resulting scheduler event.

## Retained evidence

The model fixture `compact multi-page INT4 generation matches eager generation`
in [`tests/model_forward.zig`](../tests/model_forward.zig) builds a tiny
synthetic source model and prepares and maps its `.glrt` image. Together with
the LaneWeave publication-adoption unit tests, the retained evidence verifies:

- exact token equivalence with the configured legacy numerical oracle;
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
- pending-permit rollback after an injected pre-publication failure;
- zero used resources after retirement;
- zero used resources after an injected initialization-allocation failure.

R1c does not claim that its request-profile manifest is a stable package
identity or that shared logical residency proves physical RSS. It does not
execute a raw-text tokenizer, verify the caller-asserted token-domain,
configuration, or license bytes, publish a Common Model Contract
`ResultEnvelopeV1`, serialize a durable checkpoint, or resume the prepared
session in a fresh process. It also does not bridge every V1-valid request
shape: profiles whose local activation accounting falls below the common
token-input byte bound remain outside R1c. The fixture does not establish
production-model quality, native performance evidence, tokenizer
interoperability, strict cross-platform numerical equivalence, or concurrent
same-scheduler progress during startup.

`BoundPlanV1`, `ExecutionResidencyBindingV1`, and the Session bridge are still
an experimental Zig/direct API. There is no fixed `BoundPlanV1` wire, C
validator, independent golden oracle, or retained `.generate_sequence`
`SupportRecordV1` yet. Cross-language ABI and support-registry parity are
future work; the API may change while R1 is active.
