# Prism Decode Research Track

Status: **paused after feasibility gates rejected the tested dense progressive
layouts**. Scalar correctness oracles remain useful, but Prism is not a runtime
feature or file-format promise.

## Hypothesis

Use a shallow, lower-precision view of the same model to draft tokens, then verify
the candidate block with the exact full-depth representation. Only verified
tokens and exact KV state may commit.

```text
exact checkpoint
      │
      ├─ shallow progressive draft → provisional candidates
      │
      └─ full-depth exact verifier → accepted prefix or corrected token
                                         │
                                         └─ atomic output/KV commit
```

This avoids a second draft model but introduces representation, verification,
rollback, and resident-byte costs that must all be measured.

## Exact decomposition oracle

For the current INT4 coefficient `q = u - 7`, where `u` is a nibble:

```text
coarse = 8*((u >> 3) & 1) - 4
middle = 4*((u >> 2) & 1) - 2
fine   = (u & 3) - 1

coarse + middle + fine = u - 7
```

The experimental tiers use one coarse bit, a second middle bit, and two fine
bits. Exhaustive scalar tests establish exact reconstruction for all nibbles.
They do not establish that a separated physical layout is efficient.

## What was tested

- scalar and allocation-backed progressive views;
- rows4/K16 `1+1+2` physical representation;
- isolated AArch64 feasibility kernels with production-style Q8 inputs;
- direct dense `2+2` successor and activation lookup variation;
- exact P4 reconstruction and independently materialized P2 coefficients.

The retained feasibility screens did not meet the required P2 speed and P4
overhead gates. Dense planes therefore remain out of `.glacier`, `.glrt`, and
production dispatch.

## Exact publication contract

A future draft/verify path must:

1. checkpoint committed KV root, output position, RNG, and sampler state;
2. keep draft KV and output private;
3. verify candidates from the exact checkpoint;
4. accept only the longest exact prefix;
5. publish exact KV/RNG/output through the token transaction;
6. discard all rejected or unused draft state;
7. record the representation, depth, block, acceptance, and fallback evidence.

For greedy decoding, every accepted candidate must equal the exact target argmax
at the prefix formed by previously accepted candidates. Sampling needs a separate
probabilistic contract and cannot inherit the greedy proof.

## Conditions for reopening

A new representation may reopen this track only with a bounded proposal that
accounts for complete artifact bytes, hot resident bytes, conversion workspace,
P2 kernel time, exact P4 time, and end-to-end acceptance.

Initial gates:

- P2 at least 1.45× faster on both required group geometries;
- P4 within 3% of the current exact production path;
- complete artifact overhead at most 1%;
- measured hot-resident overhead at most 3%;
- exact reconstruction and mutation tests pass;
- no hidden canonical packed duplicate outside the declared budget.

`ShadowPack`—retaining a bounded shallow prefix sidecar while materializing the
canonical verifier layout—remains a possible hypothesis. It must stop if the
measured draft-depth/resource envelope cannot produce useful accepted work.

## Contribution opportunities

- improve the isolated oracle or mutation coverage;
- build a representation cost calculator;
- reproduce the stopped result on another architecture;
- propose a bounded layout with explicit stop rules;
- connect a fake draft/verifier to token-transaction abort tests without adding a
  production dispatch path.

Negative results should remain documented. They prevent repeated work and help
future contributors choose better experiments.
