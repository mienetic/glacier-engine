# Prepared Text Restore Admission

R1h-a turns verified prepared-text successor evidence into live target
authority without making the target runnable. It is an integrated experimental
control-plane slice for the Glacier AI Runtime.

The gate consumes the existing fixed checkpoint, Common Model Contract
execution plan and residency binding, and successor transcript segment. It
creates no additional durable wire. Its public output is `PrepareDecisionV1`.
The `prepared` branch carries `PreparedRestoredAdmissionV1`; a rollback that
cannot finish carries `PrepareRecoveryV1` in `recovery_required`. Both
payloads contain process-local pointers or handles and must never be serialized
or treated as transferable authority.

Its domain-separated bootstrap root binds the R1g evidence roots and ownership
intent to the exact adoption, receipt, tree, scope, canonical request
projection, source/target epochs, restored `N/G`, and live
Scheduler/Bank/session addresses. The address-bearing root is an in-process
corruption and replay fence, not portable authority. Independent
cross-language verification therefore ends at the R1g records; R1h-a is
validated through live operational state checks.

## What the gate acquires

`prepareRestoredAdmissionV1` performs these transitions in order:

1. reconstruct and exact-compare all R1g artifacts against caller-retained
   checkpoint, source, and target context;
2. require a fresh LeaseTree-enabled target Bank and fresh target Scheduler;
3. match the live Scheduler epoch, coordinator ID, and Bank epoch to the target
   intent, and match its challenge to the successor segment;
4. derive one fixed scheduling policy from the intent:
   `request_key = authority_key`, `weight = 1`, no deadline, and
   `work_quanta = terminal_sequence - sequence_base`;
5. acquire an accepted Scheduler admission and its exact fresh Bank receipt;
6. retain the Scheduler publication-adoption barrier;
7. open the intended LeaseTree and one tenant scope under that receipt; and
8. bind the Bank publication namespace to the caller-reserved future-session
   identity/address, exact request epoch, restored sequence `N`, and the source
   Bank's last publication-permit generation `G`.

The result union has three explicit outcomes: `prepared`, policy `rejected`,
or `recovery_required`. The third outcome is used only when setup failed and
automatic reverse cleanup could not finish. It carries the exact process-local
adoption, optional tree/scope, session values, and current cleanup phase rather
than discarding live authority. Call
`recoverPrepareRestoredAdmissionV1` with that payload until rollback completes
and returns the cancellation event, or reports the still-blocked operation. It
does not resume setup or produce a prepared target.

The Scheduler, Bank, and target-session addresses are live process-local
bindings added by the bootstrap root; `TargetOwnershipV1` intentionally commits
the coordinator ID rather than a portable address.

The first future Bank publication permit is therefore `G + 1`, even though the
target receipt begins in a fresh Bank. Scheduler service permits remain in
their own target Scheduler epoch/coordinator namespace and are not seeded from
the Bank publication generation.

## Why the tree is empty

The R1g request claim already accounts for the prepared Session's request-local
KV capacity. LeaseTree v1 allocation claims are additive to their parent
receipt. Reserving the same KV claim again below a receipt charged for the
complete request would double-count memory and make Scheduler and Bank
accounting diverge.

R1h-a therefore opens the exact allocation-empty tree and a tenant scope with
zero current claim and a request-claim ceiling, but does not reserve the
retained `cache_node_key` or `cache_binding_key`. Those keys remain committed
intent for the next materialization gate. That gate must introduce an explicit
parent/cache claim split or funded-suballocation contract before restoring
KV/output/RNG state and committing the adoption.

This is a deliberate safety boundary, not an accounting shortcut.

## Non-runnable barrier

An accepted R1h-a capability retains `PublicationAdoptionV1`. While that
barrier is present, LaneWeave rejects service preparation, new admissions,
cancellation, retirement, and close operations that could race target setup.
The ordinary flat `commitPublicationAdoption` path also cannot consume the
capability because the Bank namespace is already LeaseTree-bound.

The capability is therefore live ownership but not a runnable
`SessionV3`. No target token can be sampled or published through this API.

## Validation and abort

`validatePreparedRestoredAdmissionV1` rechecks:

- the exact portable records against independently retained checkpoint,
  source, and target expectations;
- the exact live Scheduler identity and Bank address;
- the pending adoption and accepted admission;
- the fresh receipt and request claim;
- tree, scope, tenant, authority, and generation-fenced publication binding;
- one active Scheduler lane and matching Scheduler/Bank usage;
- exactly one allocation-empty tree and one zero-current-claim scope with the
  request-claim ceiling; and
- zero reserved, live, quiescing, or free-authorized LeaseTree allocations.

`abortPreparedRestoredAdmissionV1` validates first, then performs the only
legal reverse transition:

```text
close restored publication session
→ close allocation-empty LeaseTree and its scope
→ cancel pending adoption and release receipt
```

The first valid owner wins. A copied or replayed capability becomes stale after
the successful abort and cannot release a reused slot. If an external actor
violates the single-owner contract between the three cleanup transitions, the
capability records the last completed transition before reporting
`RecoveryRequired`. Calling `abortPreparedRestoredAdmissionV1` again resumes
from that exact phase: publication session still bound, LeaseTree still open,
or adoption still held. It never represents all three cases with one ambiguous
state.

## Scope and next gate

R1h-a proves exact live target identity, fresh admission and receipt,
LeaseTree-aware publication remapping, nonzero sequence restoration, and
strict Bank permit monotonicity. It does not:

- allocate or materialize checkpoint KV/output/RNG state;
- commit the Scheduler adoption;
- create a runnable target Session;
- exit or revoke the source;
- durably choose one successor;
- prove global source/target exclusivity;
- survive process death as live authority; or
- compare uninterrupted and resumed production-model output.

The next prepared-text gate adds charge-correct KV/output/RNG restoration, a
LeaseTree-aware adoption commit, restored Session construction, and one exact
next-token comparison. Durable selection and source-exit proof remain separate
gates after that.

## Retained checks

The retained suite covers:

- legacy flat Scheduler initialization and explicit LeaseTree opt-in;
- exact read-only Scheduler identity;
- fenced restored Bank binding with invalid source/target epochs, zero and
  exhausted generations, forged tree tokens, duplicate binds, and unchanged
  failure snapshots;
- first permit `G + 1`, abort/retry `G + 2`, and overflow behavior;
- coherent foreign live Scheduler rejection before mutation;
- pending-barrier service rejection;
- rejection of the ordinary flat adoption commit;
- exact prepared capability validation and allocation-empty-tree accounting;
- coherent receipt/tree/session splicing rejected before either live authority
  mutates;
- retained setup-recovery authority from adoption-only, bound-session, and
  tree-open rollback states, including one blocked cleanup, external repair,
  and retry with the same payload;
- reverse-cleanup entry from the exact session-closed and tree-closed phases;
- successful reverse cleanup; and
- stale copied-capability rejection after the first abort.

Use the ephemeral cache wrapper for focused Zig checks:

```bash
tools/zig-with-ephemeral-cache.sh test \
  --dep core \
  -Mroot=src/core/resource_bank.zig \
  -Mcore=src/core/root.zig \
  -lc

tools/zig-with-ephemeral-cache.sh test \
  --dep core \
  -Mroot=src/core/lane_weave_qos.zig \
  -Mcore=src/core/root.zig \
  -lc

tools/zig-with-ephemeral-cache.sh test -OReleaseSafe \
  --dep core \
  -Mroot=src/prepared_text_restore_admission.zig \
  -Mcore=src/core/root.zig \
  -lc

tools/zig-with-ephemeral-cache.sh build test -Dmetal=false -j2
```
