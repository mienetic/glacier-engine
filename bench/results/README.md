# Benchmark Evidence Index

This directory contains small, reviewable fixtures and reports that belong in
version control. Large raw campaigns should be attached to a release or external
artifact store and referenced by digest.

## Status vocabulary

- `fixture`: deterministic contract input; not a performance result.
- `diagnostic`: useful observation that has not passed campaign gates.
- `paired`: same-machine paired experiment with validity decisions retained.
- `replicated`: repeated across the named machine/workload matrix.
- `stopped`: negative or inconclusive result retained to guide architecture.

## Required artifact fields

Every new machine result must identify:

- schema and harness version;
- source commit and dirty-tree status;
- build mode, target, flags, and backend;
- model/tokenizer/input digests;
- sample order, warmup, cooldown, and rejection reasons;
- correctness or quality gate;
- machine envelope and unavailable telemetry;
- metrics with units and raw samples;
- claim class, permitted wording, and exclusions.

Wire or transaction fixtures additionally need their ABI/domain, golden digest,
and independent verifier command.

## Current architecture checkpoints

The repository's strongest checked-in evidence is deterministic conformance:

- contiguous and paged token publication;
- LeaseTree-backed KV ownership and retirement;
- deterministic LaneWeave scheduling and replay;
- prepared runtime-image integrity;
- provider gateway, transport, settlement, cost, and journal replay;
- lossless context mapping and token reconciliation;
- compact provider evidence composition with independent verification.

These checkpoints establish contract behavior. They do not establish a broad
throughput or resource advantage.

## Adding a result

1. Read [Benchmark and evidence guide](../../docs/BENCHMARKS.md) and
   [Evidence policy](../../docs/EVIDENCE_POLICY.md).
2. Run a small smoke artifact and validate its schema.
3. Run the planned paired or replicated campaign without editing rejected
   samples after the fact.
4. Add a concise Markdown summary here only when the underlying raw artifact is
   retained and addressable by digest.
5. State limitations as prominently as the result.

Do not commit model weights, credentials, private prompts, local absolute paths,
or oversized raw traces.
