# Prepared Text Session

The prepared text session is an experimental Zig API for one bounded,
in-process text-generation lifecycle. It connects an exact prepared `.glrt`
image, one prompt, one resource admission, serial greedy execution, and
transactional token publication without downloading a model.

R1a established the persistent numerical and publication lifecycle. R1b adds
the preferred atomic start path for a shared scheduler. These are integrated
experimental slices, not the completed R1 text runtime.

## Supported envelope

| Concern | Current experimental contract |
| --- | --- |
| Artifact | A mapped prepared `.glrt` image with the separate MLP layout |
| Artifact identity | Source fingerprint, ABI fingerprint, container byte length, and full container SHA-256 |
| Prompt | Caller-provided `[]const u32` token IDs |
| Sampling | Greedy (`temperature = 0`) with a sealed seed |
| Execution | One thread, serial attention, materialized decode state, checked decode plan |
| Length | A nonzero, fixed `max_new_tokens` service count |
| Admission | `SessionV1.start` derives the exact claim and work quanta from `PlanV1` |
| Publication | One `LaneWeave` service permit commits one token transaction |
| Mutable state | Session-owned KV rows, RNG state, sampling count, and output token buffer |
| Evidence | Plan digest plus a verified publication boundary snapshot |

`eos_token` must be outside the model vocabulary in this version. Fixed-length
execution keeps the admitted service count identical to the number of
publication transactions.

## Preferred R1b lifecycle

1. Load a prepared image with `loader.loadPreparedWithOptions`.
2. Build `prepared_text_session.OptionsV1`, then derive the canonical
   `PlanV1` with `makePlanV1`. The plan binds the exact image identity, prompt
   digest and length, fixed output length, seed, and request claim.
3. Call `SessionV1.start` with the plan and scheduling identity. `start`
   constructs the width-one request using `plan.claim` and
   `plan.max_new_tokens`; the caller does not admit the request separately.
4. Before request-owned materialization, `LaneWeave` either returns
   `SequenceOverflow` when it cannot reserve the required Event-v1 capacity,
   emits the ordinary rejection event when slack permits, or commits the exact
   `ResourceBank` charge and returns a sealed, single-use publication adoption
   authority. The scheduler-wide adoption barrier is active before its mutex
   is released.
5. While that barrier is active, `start` allocates the session resources and
   performs prefill. It then atomically converts the adoption authority into
   the exact every-service publication binding. If allocation, prefill, or
   binding fails, `start` consumes the authority through cancellation: the
   accepted admission is followed by a normal cancellation event and the
   committed resource claim is released. If cancellation returns a transient
   cleanup error, `start` returns `RecoveryRequired` and the Session retains
   the exact, single-use cancellation authority. After the transient condition
   is resolved, `recoverStartAdoption` retries that cancellation only.
6. Repeatedly obtain the next service permit from the same scheduler and pass
   it to `step` with a `lane_publication_txn.SinkV1`. Each successful step
   publishes exactly one token and commits the corresponding KV/RNG/output
   transition.
7. Call `snapshotVerified` at an idle boundary when evidence is needed.
8. After the fixed final token, call `retire`. Before completion, call `cancel`
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

## Compatibility lifecycle

`SessionV1.init` remains available for integrations that already hold a
successful admission. That path retains the R1a exclusive boundary: no thread
may call the same scheduler between successful admission and the return from
`init`. New integrations should use `SessionV1.start`, which owns that boundary
and removes the caller-managed admission-to-adoption race.

The boundary snapshot has a canonical root over the plan, exact image identity,
committed state, sequence position, and publication transcript captured by the
live session. The underlying publication transcript does not yet carry the full
plan or image digest, so this grouping is not a splice-resistant historical
attestation. It also does not contain the KV or model payloads required to
restore the session in another process.

## Ownership rules

- The caller keeps the loaded model alive for the entire session.
- The caller owns the scheduler, bank storage, and downstream sink; the session
  borrows them for the active lifecycle.
- The Session must already be at its final address before `start` or `init`.
  Do not move, copy, or concurrently access it during initialization, active
  publication, or adoption recovery.
- The preferred `start` path derives the admitted claim and service count from
  the validated plan. Callers cannot substitute a different claim or
  `work_quanta` value at that boundary.
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
- If `start` returns `RecoveryRequired`, it has retained the exact, single-use
  cancellation authority. Do not overwrite or move the Session while that
  authority is live. After the transient cleanup error is resolved, call
  `recoverStartAdoption` to retry cancellation. This API neither diagnoses nor
  repairs Scheduler or Bank state.
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

The fixture does not claim production-model quality, durable or fresh-process
resume, native Linux validation, tokenizer interoperability, or performance.
The session-specific `PlanV1` is not yet the common Model Contract execution
plan, startup does not permit concurrent same-scheduler progress, and the API
may change while R1 is active.
