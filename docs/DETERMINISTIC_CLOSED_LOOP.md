# Deterministic Closed-Loop Workload

The deterministic closed-loop workload is the W3 logical-conformance layer of
the [Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md). It exercises repeated
admission, terminal turnover, weighted service, finite-source exhaustion, and
final ownership release without reading an ambient clock or creating native
concurrency.

W3 is a separately versioned contract. It does not add a mode to the
WorkloadPressure V1 open-loop wire and does not change the W0 scenario/result,
W1 scheduled-media evidence, or W2 generated-corpus ABIs and retained roots.

## Contract boundary

A W3 plan contains:

- a finite, canonically ordered candidate list that is also the admission
  attempt budget;
- a declared `in_flight_target`;
- a physical scheduler and resource-bank capacity greater than or equal to the
  target;
- bounded logical driver steps and service quanta;
- fixed LaneWeave and ResourceBank configuration;
- relative logical deadline and terminal-action policies for each candidate;
  and
- nonzero, unique request and ownership identities.

The target is a logical controller target and hard upper bound on admitted,
nonterminal work. It is not an operating-system thread count, process count,
worker-pool size, parallel kernel count, request rate, or native concurrency
measurement.

An admission rejection or another terminal outcome can leave the active
population below the target for the rest of the current logical step. W3
attempts the corresponding refill in the next step if an unused candidate
remains. It never claims that every attempt is admitted or that physical work
remains continuously saturated.

## Normative logical-step order

Every driver step executes four phases in this exact order:

| Phase | Name | Required behavior |
| ---: | --- | --- |
| 1 | `admit_due` | Step zero submits the canonical initial prefix up to the target. Later steps consume prior-step terminal credits in FIFO order. Each credit consumes at most one new candidate. |
| 2 | `apply_actions` | Due cancellation and timeout actions execute in candidate-ordinal order against work that is still active. |
| 3 | `service_retire` | LaneWeave commits at most one service quantum. A request whose remaining work reaches zero retires in the same phase. |
| 4 | `seal_step` | Terminal events collected during phases 1–3 are sealed in their exact trace order as FIFO credits due at `step + 1`. |

Admission rejection never recursively submits another candidate in the same
step. This rule makes rejection chains bounded by both the candidate budget and
the driver-step limit.

## Terminal outcomes and refill

Every terminal outcome creates one logical vacancy:

| Terminal outcome | Terminal phase | Earliest refill |
| --- | --- | --- |
| admission rejection | `admit_due` | next logical step |
| cancellation | `apply_actions` | next logical step |
| timeout | `apply_actions` | next logical step |
| completion and retirement | `service_retire` | next logical step |

Credits preserve terminal-trace order across phases. If a step contains two
ordered actions followed by one retirement, their successors inherit those
three credits in that order. Aggregate outcome totals are not sufficient proof
of this rule; W3 evidence binds every successor to its exact predecessor,
terminal kind, terminal step, lineage, and trigger record.

With `in_flight_target <= capacity`, unique live identities, and one-for-one
credits, an honest W3 execution cannot produce `no_slot` or
`duplicate_tenant`. Either result is an invariant violation. Resource,
deadline-feasibility, and bounded-projection rejection remain valid outcomes
and follow the same next-step credit rule.

## Lineage and generations

Initial candidates occupy logical lineage indices
`0..<in_flight_target` and begin at generation one. A successor:

- inherits its predecessor's lineage index;
- increments the lineage generation exactly once;
- names the predecessor candidate ordinal;
- binds the predecessor outcome and terminal step;
- binds the terminal trace record that created the credit; and
- records its own submission, admission, first-service, and terminal steps.

Logical lineage is not a physical LaneWeave slot identity. Physical slots may
be reused only through fresh scheduler and ResourceBank generations; stale
handles or receipts grant no authority.

## Finite-source drain

The candidate list is finite and every candidate is attempted at most once.
When more credits become due than candidates remain, the earliest FIFO credits
consume the remaining candidates and later credits are recorded as exhausted.
No implicit or synthetic work is created.

The campaign can close only when:

1. every candidate in the attempt budget has been consumed;
2. the active population is zero;
3. the due-credit queue is empty;
4. LaneWeave has no active or finished request;
5. ResourceBank has no reservation or committed receipt; and
6. the verifier accepts the terminal chain and close event.

Every successful admission therefore closes exactly once through cancellation,
timeout, or retirement. Final zero ownership is a required result, not an
optional report field.

## Bounds and storage

W3 uses caller-owned fixed storage. Candidate history, outcomes, lineage, and
trace capacity are bounded by the complete candidate budget rather than the
smaller in-flight target, because one physical slot may serve several
generations over the campaign.

Plan validation rejects a campaign before execution when any declared bound is
zero, inconsistent, overflowing, or larger than the public V1 maximum. The
trace bound covers:

- one admission decision per candidate;
- every committed service quantum;
- one cancellation or retirement for each admitted terminal request;
- one sealed credit per terminal candidate;
- every credit exhausted by finite-source drain; and
- the final close event.

Short wire buffers, malformed inputs, driver-step exhaustion, service-quanta
exhaustion, or trace exhaustion fail without publishing a partial result.

## Canonical evidence

The W3 plan and result use separate fixed-record, canonical little-endian V1
wires. Their headers bind exact ABI, record size, count, flags, and section
roots. Reserved bytes are zero. A domain-separated footer binds the complete
preceding wire body.

| Wire | Canonical byte length |
| --- | ---: |
| Plan V1 | `320 + candidate_count × 256 + 32` |
| Result V1 | `256 + outcome_count × 328 + trace_count × 200 + 424 + 32` |

The final `32` bytes are the wire footer. The plan and result ABIs are
`0x4757434c50000001` and `0x4757434c52000001`; the semantic trace and summary
ABIs are `0x4757434c54000001` and `0x4757434c53000001`.

Result evidence contains:

- one ordered outcome and lineage record per attempted candidate;
- a phase-aware logical trace;
- exact admission, rejection, completion, cancellation, and timeout counts;
- target, physical capacity, candidate budget, and replacement totals;
- outcome-specific refill totals;
- active and due-credit high-water marks;
- lineage count and maximum generation;
- logical service, wait, fairness, and resource high-water summaries;
- exact scheduler and ResourceBank close counters;
- final active and due-credit counts;
- semantic section and result roots; and
- the required zero-orphan ownership result.

Parent roots are recomputed from record metadata and child semantic roots.
Cached record roots are never trusted as detached authority.

The retained canonical report lives at
`bench/results/workload-closed-loop-v1.json` with schema
`glacier.workload-closed-loop/v1`. It contains only bounded logical workload
metadata, exact wire byte lengths, complete-wire SHA-256 digests, and semantic
digests. The wire digests make Zig/Python codec parity explicit. The report
contains no prompt, model weight, provider payload, credential, user media,
native timestamp, or physical telemetry.

## Independent verification

The Zig runtime and Python oracle implement the four phases independently.
The Python verifier does not consume the native trace as expected data and
does not translate W3 into a precomputed open-loop schedule. Both sides:

1. validate and round-trip the canonical plan;
2. execute the direct terminal-driven state machine;
3. reconstruct every outcome, lineage, trace, summary, and root;
4. validate and round-trip the canonical result;
5. reject byte mutations and resealed semantic contradictions;
6. preserve the W0, W1, and W2 retained goldens; and
7. render the same canonical report bytes.

Use the repository cache-isolating Zig wrapper:

```sh
tools/zig-with-ephemeral-cache.sh build workload-closed-loop-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build workload-closed-loop-demo \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
python3 -m unittest bench.tests.test_workload_closed_loop
```

Cross-compilation demonstrates that the fixed contract and code compile for a
target. It is not native load evidence for that operating system or processor.

## Claim boundary

The retained W3 artifact supports this claim:

> For the retained deterministic closed-loop fixture, Zig and the independent
> Python oracle agree on every logical admission attempt, terminal-driven FIFO
> replacement, scheduler event, lineage, summary, and semantic root. Logical
> active work never exceeds the declared target, every admitted receipt closes
> exactly once, and final ownership is zero.

It does not establish:

- requests per second, throughput, wall-clock latency, or tail latency;
- native concurrency, threaded or asynchronous queue behavior, races,
  batching, preemption, or kernel overlap;
- process RSS, allocator growth, CPU or GPU utilization, device residency,
  placement, fallback, power, energy, temperature, or thermal behavior;
- production model, tokenizer, codec, provider, tool, or output quality;
- token or cost reduction for an external provider;
- soak, disruption, service-level, capacity, or reliability behavior;
- native operating-system support from a cross-compile; or
- correctness for every possible plan or a formal proof of LaneWeave.

## Contributor extensions

Small independent contributions can add:

- one retained W3 plan without changing any V1 root;
- one mutation for phase, predecessor, credit, lineage, occupancy, or drain
  evidence;
- one independent decoder or verifier in another language;
- a read-only result renderer that grants no runtime authority;
- a separately versioned generated-plan corpus and shrinker;
- W1 scheduled-media or W4 typed-adapter execution under W3 admission; or
- a native closed-loop runner with its own machine, timing, concurrency, and
  physical-observation envelope.
