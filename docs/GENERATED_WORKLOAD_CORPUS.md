# Generated Workload Corpus

The generated workload corpus extends the portable WorkloadPressure campaign
from one hand-authored schedule to a retained set of bounded schedules. It is
the W2 generated deterministic open-loop layer of the
[Runtime Workload Lab](RUNTIME_WORKLOAD_LAB.md).

The layer changes no WorkloadPressure V1 scenario or result ABI and no
Scheduled Media Pressure Evidence V1 ABI. Each generated case is an unchanged
`explicit_open_loop` scenario that passes the existing W0 validator and exact
replay, then passes the existing W1 scheduler-coupled media execution and
evidence verifier. The original W0 and W1 reference bytes and golden roots
remain unchanged.

## What the retained corpus covers

The retained corpus contains four seeds with eight scenario classes per seed:
32 cases in canonical seed-major, class-minor order. The global case index is
`seed_index * 8 + class_index`, so it spans `0..31`; it does not restart at
zero for each seed. Every case is model-free, bounded, and independent of an
ambient clock, thread schedule, system random source, filesystem, network, or
device.

Across the retained cases, the generator varies:

- image, audio, and video reference profiles;
- sorted logical arrival steps;
- scheduler weight and finite work quanta;
- capacity and logical host-resource pressure;
- deadlines, cancellation, and timeout actions; and
- the fairness cohort and exact scenario identity.

Coverage belongs to the complete retained corpus, not necessarily to every
individual case. A normal rejection, cancellation, or timeout is an expected
workload outcome and is not a generator failure.

## Coordinate-addressed generation

Generator V1 uses domain-separated SHA-256 decisions addressed by six fixed
little-endian coordinates after the domain:

```text
"glacier-workload-scenario-corpus-decision-v1\0"
|| LE64(generator_abi)
|| LE64(generator_seed)
|| LE64(global_case_index)
|| LE64(scenario_class)
|| LE64(decision_tag)
|| LE64(item_ordinal)
```

Scenario-level decisions use the absent-item ordinal `0xffffffffffffffff`.
Tags `1..5` address the derived scenario seed, bank epoch, scheduler epoch,
challenge, and modality rotation respectively. The first eight digest bytes
are decoded as a little-endian integer where an integer is needed. Only a zero
derived seed or epoch maps to one; the challenge retains the full digest, with
its first byte changed to one only in the all-zero case. Modality rotation uses
the decoded integer modulo three.

A decision never depends on how many earlier choices another implementation
happened to draw. This avoids a mutable pseudorandom stream whose state can
drift between languages.

The decision domain, integer encoding, coordinate assignment, and mapping from
decision bytes to each bounded choice are part of the generator ABI. The
generator does not claim statistical randomness or cryptographic
unpredictability. Seeds are reproducible case identities, not secret entropy.

## Retained scenario classes

| ID | Class | Exact retained path |
| ---: | --- | --- |
| 1 | `fairness` | Three completions with `1:2:4` weighted fairness |
| 2 | `no_slot` | Four-request burst into two slots; two exact slot rejections |
| 3 | `resource_limit` | One admission followed by two host-limit rejections |
| 4 | `cancel_turnover` | Served request cancels, then its slot serves a completion |
| 5 | `timeout_turnover` | Served request times out, then its slot serves a completion |
| 6 | `deadline_feasible` | Two requests complete at their declared deadlines |
| 7 | `deadline_infeasible` | Infeasible request rejects before a later completion |
| 8 | `projection_limit` | Two exact projection-budget rejections |

The class fixes the intended semantic path. Coordinate-addressed decisions
change scenario identity and modality rotation without weakening those exact
outcome expectations.

Construction is bounded before the scenario runs:

- item count, capacity, arrivals, weights, work, deadlines, and actions stay
  within WorkloadPressure V1 limits;
- item ordinals and arrivals remain canonical;
- request and resource-owner identities remain nonzero and unique;
- the retained media kind determines the existing family, operation, profile
  root, and exact logical claim;
- at least two items form a valid fairness cohort;
- the total service and worst-case trace envelope fit the existing fixed
  caller-owned storage; and
- the generated scenario is rejected unless the unchanged W0 validator accepts
  it.

The generator creates scenarios only. It grants no scheduler permit,
`ResourceBank` receipt, media publication authority, filesystem capability,
provider credential, or device access.

## Unchanged W0 and W1 execution

Every retained case crosses two existing conformance boundaries:

1. **W0 replay.** The generated `ScenarioV1` runs through `LaneWeave`,
   `ResourceBank`, and the exact replay verifier. Ordered outcomes, trace,
   logical summaries, roots, and final zero ownership remain governed by the
   unchanged WorkloadPressure V1 contract.
2. **W1 execution.** The same scenario runs through the generic scheduled-media
   driver. Every admitted request keeps its scheduler-owned receipt; completed
   work executes its bounded image, audio, or video fixture only on the final
   service quantum; rejected, cancelled, and timed-out work publishes nothing.
   The resulting Evidence V1 sidecar is reconstructed independently.

Generated cases produce their own scenario, result, and W1 evidence roots.
They do not replace the hand-authored reference campaign. Compatibility tests
retain the exact original W0 scenario/result bytes and W1 evidence bytes and
goldens.

## Deterministic shrinking

The corpus includes a bounded deterministic shrinker for a caller-supplied
exact failure signature. Candidate reductions are tried in one versioned order.
A candidate is accepted only when:

1. it remains a canonical valid WorkloadPressure V1 scenario;
2. the predicate still returns the exact original signature; and
3. its declared complexity is lower under the shrink contract.

The shrinker stops when no single declared reduction preserves the signature.
The result is therefore locally minimal under those V1 reductions, not proven
to be the globally smallest failing scenario.

The first retained shrink fixture uses an explicitly synthetic conformance
predicate. It proves repeatability, signature preservation, and the local
fixed-point rule; it is not presented as a historical runtime defect. A future
regression may be added only with its stable signature, original and minimized
scenario roots, acceptance command, and nonclaims.

## Retained artifact

The canonical report is retained at
`bench/results/workload-scenario-corpus-v1.json`. Its schema is
`glacier.workload-scenario-corpus/v1`.

The report retains:

- schema and generator ABI identity;
- the ordered four-seed set and eight scenario classes per seed;
- exact corpus and coverage summaries;
- one ordered record per generated case, including its generator seed, class,
  scenario identity, W0 result identity, W1 evidence identity, logical service
  and driver totals, publication and terminal-session totals, outcome summary,
  and zero-orphan result; and
- the synthetic shrink fixture, exact failure signature, original and minimized
  identities, before/after complexity, evaluation and reduction counts,
  local-minimum result, and idempotent second-pass identity.

The artifact contains logical scenario and digest evidence. It contains no
prompt, model weight, provider payload, credential, user media, native timing,
or physical telemetry.

## Run and verify

Use the repository cache-isolating Zig wrapper:

```sh
tools/zig-with-ephemeral-cache.sh build workload-scenario-corpus-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
tools/zig-with-ephemeral-cache.sh build workload-scenario-corpus-demo \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
python3 -m unittest bench.tests.test_workload_scenario_corpus
```

The test target covers the Zig generator, W0 replay, W1 execution, deterministic
shrinking, unchanged reference goldens, and the independent Python generator
and verifier. The demo prints the canonical JSON report. The focused test
compares those native bytes with both the independent Python reconstruction and
the retained fixture; a clean-tree check must show that the committed artifact
is current.

## Claim boundary

The retained artifact supports this claim:

> For the retained 32-case seed matrix, Generator V1 produces bounded canonical
> open-loop scenarios. Zig and the independent Python implementation agree on
> generation and exact W0/W1 verification, and every retained execution closes
> with zero orphan ownership.

It does not establish:

- correctness for every possible seed, exhaustive state-space coverage,
  statistical fuzzing quality, or a formal proof of the scheduler;
- global minimality of a shrunk case;
- wall-clock throughput, request rate, latency, concurrency, process RSS,
  allocator behavior, CPU or GPU utilization, device residency, power, energy,
  temperature, or native operating-system support;
- production model, tokenizer, codec, provider, tool, batching, preemption, or
  asynchronous execution behavior;
- soak, disruption, memory-growth, or service-level behavior; or
- deterministic or native closed-loop behavior.

Cross-compilation checks the portability of the code and fixed contracts. It is
not native workload evidence for the target platform.

## Contributor extensions

Small independent contributions can:

- add one retained seed whose case roots and coverage are reproduced in Zig and
  Python;
- add one bounded generator decision while preserving all prior case roots;
- add one exact failure signature and independently minimized regression
  fixture;
- add a read-only corpus renderer that labels verification state and grants no
  authority; or
- run one generated scenario through an additional typed workload driver
  without changing W0 or W1 evidence.

The next workload mode is W3 deterministic closed-loop conformance. It requires
a separately versioned contract whose replacements are driven by terminal
outcomes and a declared in-flight target. It is not an extension of the
WorkloadPressure V1 open-loop mode and is not implemented by this corpus.
