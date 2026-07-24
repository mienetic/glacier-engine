# Prepared Text Session

The prepared text session is an experimental Zig API for one bounded,
in-process text-generation lifecycle. It connects an exact prepared `.glrt`
image, one prompt, one resource admission, serial greedy execution, and
transactional token publication without downloading a model.

This is an integrated R1a slice, not the completed R1 text runtime.

## Supported envelope

| Concern | R1a contract |
| --- | --- |
| Artifact | A mapped prepared `.glrt` image with the separate MLP layout |
| Artifact identity | Source fingerprint, ABI fingerprint, container byte length, and full container SHA-256 |
| Prompt | Caller-provided `[]const u32` token IDs |
| Sampling | Greedy (`temperature = 0`) with a sealed seed |
| Execution | One thread, serial attention, materialized decode state, checked decode plan |
| Length | A nonzero, fixed `max_new_tokens` service count |
| Publication | One `LaneWeave` service permit commits one token transaction |
| Mutable state | Session-owned KV rows, RNG state, sampling count, and output token buffer |
| Evidence | Plan digest plus a verified publication boundary snapshot |

`eos_token` must be outside the model vocabulary in this version. Fixed-length
execution keeps the admitted service count identical to the number of
publication transactions.

## Lifecycle

1. Load a prepared image with `loader.loadPreparedWithOptions`.
2. Build `prepared_text_session.OptionsV1`, then derive the canonical
   `PlanV1` with `makePlanV1`. The plan binds the exact image identity, prompt
   digest and length, fixed output length, seed, and request claim.
3. Admit a width-one request through `LaneWeave` using the plan's exact claim
   and `max_new_tokens` as `work_quanta`.
4. Initialize `SessionV1` with that admission. A successful initialization
   adopts the receipt and owns the runtime state for the session. Steps 3 and 4
   are one exclusive boundary: do not call the same scheduler from any thread
   between the successful admission and the return from `init`.
5. Repeatedly obtain the next service permit from the same scheduler and pass
   it to `step` with a `lane_publication_txn.SinkV1`. Each successful step
   publishes exactly one token and commits the corresponding KV/RNG/output
   transition.
6. Call `snapshotVerified` at an idle boundary when evidence is needed.
7. After the fixed final token, call `retire`. Before completion, call `cancel`
   instead. Always call `deinit` to release the session's local allocations.

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
- The successful-admission-to-`init` boundary is exclusive. This version does
  not provide an atomic combined admit-and-adopt operation for shared
  schedulers. Normal shared scheduler use may resume after `init` succeeds.
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
- `retire`, `cancel`, and the `deinit` safety path close the adopted
  publication lifecycle. Explicit retirement or cancellation is preferred when
  the caller needs the resulting scheduler event.

## Retained evidence

The test `compact multi-page INT4 generation matches eager generation` in
[`tests/model_forward.zig`](../tests/model_forward.zig) builds a tiny synthetic
source model, prepares and maps its `.glrt` image, and verifies:

- exact token equivalence with the configured legacy numerical oracle;
- rejection of in-vocabulary early EOS;
- exact admission-claim and service-count binding;
- one downstream commit per output token with no abort;
- canonical plan/image/publication boundary grouping and mutation rejection;
- pending-permit rollback after an injected pre-publication failure;
- zero used resources after retirement;
- zero used resources after an injected initialization-allocation failure.

The fixture does not claim production-model quality, durable or fresh-process
resume, native Linux validation, tokenizer interoperability, or performance.
The session-specific `PlanV1` is not yet the common Model Contract execution
plan, atomic shared-scheduler admission/adoption is not yet provided, and the
API may change while R1 is active.
