# Typed Tool Workload

The typed tool workload is the first W4b Runtime Workload Lab slice. It joins
one bounded, credential-free tool transaction to the existing typed-workload
plan, LaneWeave scheduler, and ResourceBank receipt lifecycle.

The retained tool is deliberately small: `bounded_add(target, delta)` updates
one process-local counter. Its purpose is to prove the control-plane invariants
needed by agentic AI workloads without granting filesystem, network, process,
credential, clock, random-number, or external side-effect authority.

## What the slice proves

- a model- or agent-originated proposal is data, not execution authority;
- a local policy produces an explicit allow or deny receipt;
- an allowed first request changes the counter once;
- an exact duplicate reuses the original effect receipt without changing the
  counter again;
- the same idempotency key with a different proposal fails as a conflict;
- denied, cancelled, timed-out, and scheduler-rejected work produces no new
  effect;
- scheduler service, the process-local effect, and the delivery receipt become
  visible only after one accepted in-process precommit/publish transaction; and
- every admitted ResourceBank receipt is retired or cancelled exactly once,
  leaving scheduler, bank, tool-session, and provisional authority at zero.

This is deterministic logical conformance. It is not evidence for live tool
execution, sandbox strength, durable dispatch, crash-safe exactly-once effects,
compensation, latency, throughput, physical memory, energy, or native
multi-platform behavior.

## Contract layers

`tool_action_contract.zig` defines pointer-free, separately sealed records:

1. `DescriptorV1` names the tool implementation, schemas, namespace, operation,
   and bounded capability.
2. `BoundedAddArgumentsV1` carries one target and nonzero signed delta.
3. `ActionProposalV1` binds tenant, agent request, descriptor, arguments, and
   idempotency identity.
4. `PolicyV1` binds tenant, descriptor, enabled operation, delta ceiling, result
   range, epoch, and challenge.
5. `AuthorizationReceiptV1` records an allow decision or a specific denial.
6. `EffectReceiptV1` records the first committed before/after value and
   execution sequence.
7. `DeliveryReceiptV1` binds the logical disposition, effect when present, and
   the exact LaneWeave service event.

The four terminal delivery dispositions are:

| Disposition | Counter mutation | Effect receipt |
| --- | ---: | --- |
| `executed` | exactly once | newly committed |
| `reused` | none | exact prior receipt |
| `denied` | none | absent |
| `conflict` | none | prior receipt identifying the occupied key |

The harness uses fixed caller-owned storage. It allocates no memory and reads no
ambient state. A retained canonical integrity root detects changes to the
ledger, counters, sequences, counts, pending candidate, or storage identity.
Caller ownership supplies lifetime and capacity, not concurrent mutation
authority: from `init` through `close`, reads and writes must go through the
harness. A sequential out-of-band change is rejected as drift; an
unsynchronized raw write is outside the contract.
The scheduler invokes the harness precommit under its mutex and before changing
logical state. The precommit locks the harness, revalidates the exact armed
intent and retained state, and keeps that lock through the post-event publish
callback. Rejection therefore leaves the scheduler ticket and both state
machines uncommitted. After acceptance, the bounded publish callback performs
only preflight-proved mutations and cannot fail.

LaneWeave's scheduling tenant and the tool policy tenant are deliberately
separate domains. The former identifies one fairness/accounting lane; the
latter identifies authorization authority. The prepared and armed digests bind
the exact scheduler permit, proposal, policy-derived receipt, and candidate
without requiring those two tenant identifiers to be equal.

## Scheduler ordering

For a completed request, the workload performs this sequence:

1. LaneWeave admits the request and ResourceBank commits its receipt.
2. The workload binds an address-stable local session to that admission.
3. The tool harness prepares proposal, policy, idempotency, and projected
   counter state without publishing an effect.
4. On the final quantum, LaneWeave arms the exact service permit and the harness
   binds its candidate to the resulting service intent.
5. `commitArmedServiceTransaction` validates scheduler state and calls the
   harness precommit under the scheduler mutex, before Event-v1 or request state
   changes.
6. An accepted precommit retains the harness lock while LaneWeave commits the
   service event. The bounded publish callback then commits the counter or
   reuse/denial/conflict decision and creates the delivery receipt bound to
   that exact event.
7. `finish` authenticates the published receipt and releases the local
   transaction authority.
8. Retirement releases the scheduler-owned ResourceBank receipt.

Cancellation and timeout happen before tool execution. Scheduler rejection
invokes no tool callback, so rejected work cannot obtain a harness session or
effect authority.

This ordering is sufficient for the retained in-process tool because its
effect is bounded, deterministic, and infallible after the locked precommit. A
real external effect needs a durable ActionOutbox and reconciliation protocol
before dispatch; it must not call a network, process, or filesystem API from
either scheduler callback.

## Retained campaign

The reference campaign has one typed tool profile and eight requests:

| Item | Scheduler outcome | Tool result |
| ---: | --- | --- |
| 0 | cancelled | no invocation |
| 1 | timed out | no invocation |
| 2 | completed | execute `+3` |
| 3 | rejected | no session |
| 4 | completed | execute `+5` |
| 5 | completed | reuse the exact `+5` effect |
| 6 | completed | deny an out-of-policy delta |
| 7 | completed | conflict with the occupied key |

The final counter is `8`. Exactly two effects execute. Reuse, denial, and
conflict each occur once without a second mutation.

The campaign is separately versioned from W4a. It does not change the existing
typed-perception plan, result schema, evidence ABI, or retained roots.

## Verification

Run the native tests and independent Python replay:

```sh
tools/zig-with-ephemeral-cache.sh build typed-tool-workload-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
python3 -m unittest bench.tests.test_typed_tool_conformance
```

Print the one-line canonical report:

```sh
tools/zig-with-ephemeral-cache.sh build typed-tool-workload-demo \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Cross-compilation is source-portability evidence only:

```sh
tools/zig-with-ephemeral-cache.sh build typed-tool-workload-compile \
  -Dmetal=false -Doptimize=ReleaseSafe \
  -Dtarget=x86_64-linux-musl -j2
```

The native suite includes stale/copied authority, address movement,
idempotency conflict, no-precommit visibility, direct retained-storage drift,
precommit rejection without scheduler mutation, failure after prepare/arm, and
exact cleanup gates. The Python oracle independently rebuilds the plan,
scheduler replay, tool records, counter transitions, and report roots, then
requires byte-for-byte agreement with the retained fixture and native runner.

## Next contributor slices

Useful follow-ups remain independently reviewable:

- define a durable ActionOutbox record before adding any external dispatcher;
- add an acknowledgement and ambiguity-reconciliation state machine;
- add capability-scoped process, network, or filesystem adapters one at a time;
- add bounded output-size and wall-time policies outside the logical scheduler;
- connect an agent-policy result to a tool proposal without merging proposal
  and authorization authority; and
- retain native multi-OS runs before promoting platform support.

See [Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md),
[AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md), and
[Evidence Policy](EVIDENCE_POLICY.md).
