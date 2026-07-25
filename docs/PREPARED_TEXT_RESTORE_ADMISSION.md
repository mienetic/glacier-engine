# Prepared Text Restore Admission

Prepared-text restore is split into two process-local stages. R1h-a turns
verified successor evidence into a barrier-held target admission. R1h-b
materializes exact checkpoint state under receipt-funded ownership and consumes
that barrier into a runnable restored `SessionV3`.

The path consumes the fixed prepared-text checkpoint, Common Model Contract
execution plan and residency binding, and successor transcript segment. It
adds no durable wire. `PrepareDecisionV1`, `PreparedRestoredAdmissionV1`, and
the restored Session contain live pointers or generation-fenced handles and
must not be serialized or treated as transferable authority.

## R1h-a target bootstrap

`prepareRestoredAdmissionV1` performs these transitions:

1. reconstruct and exact-compare the R1g records against independently
   retained checkpoint, source, and target context;
2. require a fresh LeaseTree-enabled target Bank and fresh target Scheduler;
3. match the Scheduler epoch, coordinator ID, Bank epoch, and challenge to the
   target intent;
4. derive one fixed scheduling policy:
   `request_key = authority_key`, weight one, no deadline, and
   `work_quanta = terminal_sequence - sequence_base`;
5. acquire the exact Scheduler admission and immutable parent receipt;
6. retain the Scheduler publication-adoption barrier;
7. open the intended queue-free receipt-funded LeaseTree and one
   zero-current-claim tenant scope; and
8. bind the target publication namespace to the future Session address,
   request epoch, checkpoint sequence `N`, and source Bank publication-permit
   generation `G`.

The result is `prepared`, policy `rejected`, or `recovery_required`.
`recovery_required` retains the exact process-local setup authority and phase.
Call `recoverPrepareRestoredAdmissionV1` with the same value until rollback
returns the cancellation event. Recovery resumes cleanup; it does not resume
setup or create a prepared target.

The caller must bind the final nested publication-coordinator address returned
by `SessionV3.restoredPublicationSessionIdV1`. Moving the Session after that
binding invalidates the authority.

## Receipt-funded ownership

The immutable target receipt already charges the complete request claim.
Ordinary additive LeaseTrees remain unchanged: their allocation claims extend
the parent charge. R1h instead opts into `receipt_funded`, where allocation
claims are ownership carve-outs within the already charged receipt and do not
change `Bank.used` or aggregate peaks.

`materializedClaimV1` copies every request claim class except `queue_slots`.
The queue slot remains Scheduler-owned. This queue-free claim is the immutable
tree and scope ceiling. R1h-a opens the tree with no allocation nodes; R1h-b
reserves one allocation node for the complete queue-free claim using the
retained cache node and binding keys.

The funded tree is integrity-bound to its funding mode and activation state.
The ceiling must fit the parent receipt class by class. Additive reservation
APIs reject a funded tree, funded reservation APIs reject an additive tree, and
publication through a funded tree rejects until activation commits.

## R1h-b activation

`SessionV3.startRestoredV1` consumes a prepared R1h-a capability:

1. revalidate the checkpoint, successor records, source bound plan, target
   intent, and live prepared authority;
2. derive the canonical successor bound plan;
3. reserve the funded allocation batch before the first allocator call;
4. allocate exact Session backing and use `materializeIntoV1` to restore
   output, contiguous KV, RNG, and sampling state with deterministic zero
   slack;
5. initialize the contiguous publication state from the checkpoint transcript
   at sequence `N`; and
6. commit the materialized funded batch and pending Scheduler adoption through
   `commitRestoredPublicationAdoptionWithFundedLeaseTree`.

The Bank activation is the fallible linearization point. After it succeeds,
installing the Scheduler slot binding and consuming the adoption barrier are
infallible assignments under the Scheduler mutex. Service therefore observes
either the original non-runnable bootstrap or the complete runnable Session,
never partially restored state.

Success moves the prepared capability to `.activated`; it can no longer be
passed to `abortPreparedRestoredAdmissionV1`. The restored Session owns the
remaining lifecycle.

If startup fails before activation, caller backing is freed before the funded
batch is aborted. A blocked batch abort returns `RecoveryRequired` and retains
`allocation_abort_required`; call `recoverRestoredStartV1` with the same
prepared capability until ownership is clean. The R1h-a capability then
remains prepared and may be explicitly aborted.

## Global publication sequence

Token-publication proposals and transcript snapshots use ABI v2 with an
explicit `sequence_base`.

For a fresh Session:

```text
sequence_base = 0
next_sequence = 0
locally completed service = 0
```

For a restored Session:

```text
sequence_base = N
next_sequence = N
output_length = sampling_calls = N
locally completed service = 0
```

The first restored proposal therefore has global
`transaction_sequence = N`, retains the checkpoint predecessor transcript, and
receives target Bank publication permit `G + 1`. Scheduler service permits
remain in the fresh target Scheduler's own epoch and coordinator namespace.

## Barrier-held close

Restored cancellation and retirement first acquire
`RestoredPublicationCloseV1`, a snapshot-invisible no-service barrier. While it
is pending, Scheduler mutators cannot make the lane runnable or race allocator
reclamation.

Cleanup then advances through explicit phases:

```text
close barrier held
→ subtree retirement prepared
→ allocator free authorized
→ Session backing freed
→ funded allocation committed free
→ publication session + empty tree + receipt + Scheduler lane closed
```

The final Bank transition atomically consumes the activated publication
namespace, empty funded tree, zero-charge scopes, and immutable parent receipt.
The Scheduler then emits the ordinary cancel or retire Event-v1. Failures after
the close barrier retain the exact phase in the Session; retry
`recoverRestoredCloseV1`. No recovery phase makes service runnable again or
uncharges the parent before allocator backing is gone.

## Validation and stale authority

`validatePreparedRestoredAdmissionV1` is mutation-free and accepts only the
pre-activation `.prepared` phase. It rechecks:

- all portable records against independently retained source and target
  context;
- the live Scheduler identity, Bank address, adoption, receipt, and exact
  request claim;
- the queue-free funded tree mode, inactive activation bit, empty current
  claim, and one zero-current-claim scope;
- restored request epoch, sequence `N`, and source permit generation `G`; and
- one active Scheduler lane with matching Scheduler/Bank aggregate usage.

Before activation, `abortPreparedRestoredAdmissionV1` closes the restored
publication namespace and empty tree, then cancels the pending adoption.
Copied or replayed handles become stale after the first successful abort or
activation. After activation, only the restored Session close path may release
the funded allocation and parent receipt.

## Scope

R1h-b proves a charge-correct, process-local runnable target:

- one immutable parent charge and one queue-free ownership carve-out;
- checkpoint state materialized before publication activation;
- global transaction sequence `N` and first target Bank permit `G + 1`;
- one retained next-token comparison against uninterrupted output, logical KV,
  RNG, and sampling state; and
- restored cancellation returning Scheduler, Bank, tree, scope, and allocation
  counts to zero.

It does not:

- durably select one successor;
- exit or revoke the source;
- prove exclusive target ownership across a process boundary;
- survive process death as live authority;
- establish exactly-once fresh-process continuation;
- compare uninterrupted and resumed terminal results; or
- establish production-model, native-platform, quality, or performance
  evidence.

## Retained checks

The retained suite covers:

- legacy additive LeaseTree and fresh-session publication behavior;
- receipt-funded mode, queue rejection, ceiling enforcement, mode splicing,
  copied activation/abort single-winner behavior, and unchanged aggregate
  usage;
- R1h-a fresh-target identity, prepared validation, reverse abort, setup
  recovery, and stale-capability rejection;
- publication ABI v2 restored initialization, first transaction at `N`,
  predecessor transcript continuity, and permit `G + 1`;
- restored contiguous KV/output/RNG binding validation; and
- one synthetic-model restored next-token comparison followed by zero-state
  cancellation.

Use the ephemeral cache wrapper for focused Zig checks:

```bash
tools/zig-with-ephemeral-cache.sh test -OReleaseSafe \
  --dep core \
  -Mroot=src/core/resource_bank.zig \
  -Mcore=src/core/root.zig \
  -lc

tools/zig-with-ephemeral-cache.sh test -OReleaseSafe \
  --dep core \
  -Mroot=src/core/lane_weave_qos.zig \
  -Mcore=src/core/root.zig \
  -lc

tools/zig-with-ephemeral-cache.sh test -OReleaseSafe \
  --dep core \
  -Mroot=src/prepared_text_restore_admission.zig \
  -Mcore=src/core/root.zig \
  -lc

tools/zig-with-ephemeral-cache.sh build test \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

The wrapper uses disposable local and global Zig caches and removes them after
each command.
