# Typed Workload Conformance

Typed Workload Conformance is the first W4a layer of the
[Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md). It connects declared model
profiles to deterministic scheduler admission, execution, result validation,
publication, cancellation, and retirement without changing the frozen W0-W3
contracts.

The first W4 slice is deliberately bounded and download-free. It composes the
retained exact-integer vision encoder, audio-window encoder, and temporal-video
encoder. It is logical conformance evidence, not native performance or
production-model evidence.

## Contract identifiers

| Record | ABI |
| --- | --- |
| Plan V1 | `0x4757545750000001` |
| Profile V1 | `0x4757545746000001` |
| Item V1 | `0x4757545749000001` |
| Driver result V1 | `0x4754574452000001` |
| Driver outcome V1 | `0x475457444f000001` |
| Driver trace V1 | `0x4754574454000001` |
| Driver summary V1 | `0x4754574453000001` |
| Perception evidence V1 | `0x4754505745000001` |
| Perception item evidence V1 | `0x4754505749000001` |
| Perception summary V1 | `0x4754505753000001` |

The portable plan wire is canonical little-endian binary. Driver and concrete
perception results are semantic evidence in this slice; they do not define a
binary interchange wire.

## Why W4 has a separate contract

The W0 and W3 workload profiles intentionally have fixed logical claims. The
typed model adapters have different execution-plan claims and require the
scheduler receipt claim to equal the plan claim field for field.

W4 therefore uses a separate plan ABI. It does not:

- add a new mode to the W0 scenario wire;
- reinterpret a W0 or W3 profile root;
- weaken exact receipt-to-plan claim equality;
- replace any W0-W3 retained root; or
- treat the runtime support registry as execution authority.

## Dependency boundary

W4 is split into three layers:

1. `typed_workload_contract.zig` defines portable profile, item, plan, hash,
   validation, and canonical wire rules. It imports no concrete adapter,
   operating-system, provider, or device backend.
2. `typed_workload_driver.zig` owns generic LaneWeave and ResourceBank
   choreography. It receives process-local lifecycle callbacks but does not
   know how a model family computes an output.
3. `typed_perception_workload.zig` supplies the download-free vision,
   audio-window, and temporal-video bindings and their typed evidence.

Canonical plans and evidence contain values and digests only. Function
pointers, native pointers, allocator identities, process handles, and device
handles are never serialized.

## Profile contract

Each `ProfileV1` declares and binds:

- family, operation, input kind, output kind, and numerical policy;
- adapter ABI and lifecycle class;
- execution unit;
- cancellation boundary;
- publication policy;
- correctness-gate kind;
- exact ResourceBank claim;
- support-record digest;
- artifact-manifest digest;
- execution-plan digest;
- adapter-implementation digest;
- correctness-policy digest; and
- the canonical profile digest.

The first retained profiles use a stateless lifecycle, final-service
publication, cancellation before the final service commit, and exact-output
correctness. New lifecycle or publication semantics require an explicit enum
value and retained rejection coverage; they must not be inferred from a family
name.

## Item and plan contract

Each `ItemV1` binds one ordered request to:

- an exact profile index and profile digest;
- arrival step, weight, work quanta, and deadline;
- optional cancellation or timeout step;
- fairness membership;
- unique tenant, request, generation, and resource-owner identities;
- the exact profile claim;
- one immutable input-binding digest; and
- the canonical item digest.

Each `PlanV1` fixes:

- seed and challenge;
- capacity and maximum driver/service work;
- fairness interval;
- ResourceBank and scheduler epochs;
- scheduler projection ceilings;
- exact logical resource limits;
- an ordered, unique profile table; and
- ordered items with unique authority identities.

Validation is fail-closed. A profile substitution, item reorder, claim drift,
zero identity, duplicate authority key, unsupported policy, non-canonical
digest, invalid action boundary, insufficient bound, or trailing wire byte
rejects the complete plan.

## Lifecycle order

For each logical driver step, the generic driver performs:

1. admit items due at this step;
2. bind each accepted scheduler receipt to its final address-stable typed
   session;
3. apply declared cancellation and timeout actions;
4. prepare at most one scheduler service transition;
5. execute a typed adapter only when that transition is the final service
   quantum;
6. arm scheduler service and typed result publication against the same intent;
7. commit both through one finalizer;
8. retire a completed typed session; and
9. record the resulting trace before advancing the step.

Rejected items receive no typed session. Non-final service commits perform no
model execution and create no result. Cancelled and timed-out sessions cannot
publish.

## Single-receipt publication

An accepted item has one scheduler-owned ResourceBank receipt:

```text
item claim
    = profile claim
    = execution-plan claim
    = admission event claim
    = committed receipt claim
```

The typed session adopts that receipt. It does not reserve or commit a second
model-execution receipt.

Before the final service transition, candidate bytes are provisional and
visible output remains zero. The driver then:

1. prepares and validates the typed result;
2. arms the scheduler service intent;
3. arms the result publication against the same intent; and
4. commits both with the scheduler finalizer.

If any fallible check fails before the combined commit, the scheduler permit
and publication permit are aborted and provisional bytes are scrubbed. After a
successful combined commit, exactly one result is visible and retirement
releases the scheduler-owned receipt.

## Cache ownership

The retained perception fixtures use verified processor-cache payloads. Each
item restores those payloads into a separate fresh cache Bank before adapter
execution. Cache ownership is supporting input authority; it is not charged
again to the scheduler receipt.

Every terminal path closes both layers:

- the typed model session is cancelled or retired against the scheduler Bank;
  and
- the cache restore session releases every cache allocation and lease tree.

Moving or copying a bound model session, cache Bank, restore session, or armed
finalizer invalidates its address-fenced authority. Callers must supply stable
storage for the entire item lifecycle.

## Evidence requirements

Typed execution evidence binds, at minimum:

- plan, profile, item, and logical trace roots;
- family, operation, execution unit, and terminal outcome;
- artifact, execution-plan, adapter, support, input-binding, and correctness
  roots;
- scheduler receipt identity and exact claim;
- final scheduler event;
- result-envelope root for completed items;
- publication-state roots before and after commit;
- output length and output digest for completed items; and
- zero values for every result-only field on rejected, cancelled, and timed-out
  items.

The summary keeps admitted, rejected, completed, cancelled, timed-out,
publication, family-execution, service, ownership, and high-water counts
separate. Logical work units are never converted into milliseconds, requests
per second, bytes of physical memory, device utilization, power, temperature,
or energy.

Structural evidence validation is available only for callers that have already
authenticated the driver result. A new trust boundary must use authoritative
validation: replay the plan in fresh caller-owned storage, require canonical
result equivalence, and only then validate the concrete adapter sidecar. This
rejects a contradictory driver history even if an attacker consistently
reseals every structural root.

## Retained campaign

The retained download-free plan has three profiles, six items, capacity three,
and 3,200 canonical plan bytes. Its terminal outcomes are:

```text
cancelled, timed_out, completed, rejected, completed, completed
```

Five items are admitted, three complete, and each retained perception family
publishes exactly once. The rejected item receives no session or cache
authority. Five cache restore sessions close; their three payload allocations
produce exactly 15 commits and 15 releases. Both model and cache ownership end
at zero.

Frozen roots:

| Evidence | SHA-256 |
| --- | --- |
| Plan wire | `66b0dfffc5b7c5fa780aac0da111595e2752aacff13d6f9dc5f68141df9afbad` |
| Logical plan | `dea9aa88a3ea6c159989a769dbcf91659b9aa5d860d9c92155a12487dcd02347` |
| Outcome section | `42065963e33f29d088d0ad87933147d65df7439bdc1740685ef16519a2acaa6f` |
| Trace | `f65e74a653520e378a96f5f8a99c01ac3f02ac9fa1188943e3d4cc41a60f6ca4` |
| Driver summary | `9024ea81959bc53db7b789752169e9f6ab15668519311a3cc197557eac3caa72` |
| Driver result | `b2fcb522dac425eee47a54697bc2c05d19f88d06cba4c5b0e06f569d3a97cdee` |
| Item evidence section | `020b3af8abd9ef97e7d5871d17fb2e51f51d0ec1ce0e49d7e9256b2cf137703a` |
| Perception summary | `a6174f75ae22ec3bec57ee184f69fb116a6bd57d8c16d487705bc64c78f23660` |
| Perception evidence | `fcfbacf21be1e549f2402c9bf0a1d7bf94b6252a4a46f6f5ca8f0f6f0d6fe1f2` |

The independent Python implementation derives the plan wire and logical driver
result. It intentionally does not interpret the concrete Zig adapter sidecar;
native semantic and mutation tests validate that sidecar, and the report
freezes its exact roots. The native runner, retained report, and Python logical
oracle must then match byte-for-byte:

```sh
tools/zig-with-ephemeral-cache.sh build typed-workload-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=. \
  python3 -m unittest bench.tests.test_typed_workload_conformance
```

## Failure requirements

Retained tests must cover:

- unknown, duplicate, reordered, or substituted profiles and items;
- profile, plan, claim, support, artifact, adapter, input, and correctness
  mismatches;
- capacity and resource rejection;
- cancellation and timeout before publication;
- callback failure after admission;
- execution, candidate validation, service-arm, and publication-arm failure;
- candidate drift and provisional-buffer scrubbing;
- stale or foreign receipt/event identity;
- duplicate terminal attempts;
- cleanup of partially initialized sessions;
- short destination buffers and atomic decode/output behavior;
- every-byte wire mutation, truncation, and resealed semantic contradiction;
  and
- final zero scheduler, ResourceBank, cache-allocation, lease, and publication
  ownership.

## Claim boundary

W4 typed conformance can establish that the retained adapters obey the declared
logical profile, execute only at the final service boundary, publish atomically
under the scheduler-owned receipt, reject substitutions, and release all
tracked ownership.

It does not establish:

- native concurrency, queueing, throughput, or wall-clock latency;
- physical CPU, GPU, accelerator, memory, power, thermal, or energy behavior;
- production-model compatibility, quality, or numerical equivalence;
- provider or tool execution;
- safe preemption during an adapter kernel;
- device placement, device residency, or fallback detection;
- long-duration soak or disruption recovery; or
- native support on an operating system from cross-compilation alone.

Those claims belong to W5-W8 and require their own versioned observations and
retained native campaigns.

## Contributor extensions

A new typed profile contribution should include:

1. one bounded profile and immutable input binding;
2. a process-local adapter binding with no serialized authority;
3. completed, rejected, cancelled, timed-out, and cleanup cases;
4. an exact correctness gate;
5. canonical evidence plus an independent verifier;
6. mutation and semantic-substitution rejection;
7. final zero ownership;
8. one focused acceptance command; and
9. explicit nonclaims.

Provider, tool, stateful, streaming, batched, preemptible, and device-backed
profiles may reuse the vocabulary, but they must add the lifecycle states and
evidence required by their actual authority boundaries.
