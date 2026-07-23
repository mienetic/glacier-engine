# Contributor Projects

Every item here is intentionally smaller than its parent architecture track. If
an item still feels large, open a **Claim a contributor slice** issue and ask a
maintainer to split it with you.

## Good first issues

### Document one failure path

Pick a public error from `src/core`, create a minimal example that triggers it,
and add the example to the relevant guide.

**Done when:** the example is deterministic, contains no secret or model
download, and a reviewer can reproduce it with one command.

### Add malformed-fixture coverage

Choose an independent Python wire verifier and add one byte-level mutation case
that is not already named by its test suite.

**Done when:** the valid fixture still passes and the mutation fails for the
intended reason.

### Improve platform diagnostics

Add a read-only parser fixture for one Linux machine-envelope field. Do not turn
missing telemetry into a false measurement.

**Done when:** present, missing, denied, and malformed inputs have tests.

### Build a glossary link check

Find unexplained project-specific terms in public documentation and link them to
the glossary, or add concise glossary entries.

**Done when:** Markdown links resolve and no definition overstates implementation
status.

### Create a fixture inspector

Add a read-only command that prints the identities and lengths in one provider
wire fixture without dumping payload text.

**Done when:** output is stable, bounded, and tested against malformed lengths.

## Intermediate projects

### Provider evidence viewer

Create a human-readable renderer for the compact evidence join and its nested
roots. Keep verification separate from presentation.

**First slice:** decode only the envelope, lengths, sequence, and root names.

### Cost-journal portability campaign

Run the crash/recovery harness on another supported filesystem and document which
sync and advisory-lock guarantees are observable.

**First slice:** add environment capture and one non-destructive smoke case.

### LaneWeave trace visualizer

Render admission, service, cancellation, and retirement events as a timeline.
The visualizer must consume verified events and label unverified input.

**First slice:** emit deterministic JSON suitable for a future UI.

### Model fixture expansion

Add a tiny, redistributable fixture covering one loader or tensor-layout branch.

**First slice:** parser and shape validation only; do not bundle large weights.

### Media transform reference models

The first transform slice is complete: one fixed plan now covers image
crop/nearest/tile mapping, weighted stereo-to-mono mixing with exact integer
decimation, and keyframe-only video selection. Zig and Python share plan and
receipt roots, every output unit maps to exact source units/bytes/time, and
unsupported geometry, rate, selection, identity, capacity, and overlap reject.

**Next slice:** add one bounded case—grayscale crop, a second convex channel
mix, a second exact rate factor, or multi-keyframe selection—without expanding
to a production codec. Preserve the existing plan/mapping identity or propose a
versioned ABI with migration fixtures. Reuse
[Deterministic Media Transforms](MEDIA_TRANSFORMS.md).

### Media runtime LeaseTree ownership

The model-free media transaction now admits and releases one exact request-wide
`ResourceBank` claim across image, audio, and video. The next slice should
subdivide that receipt into decoded-source, mapping, scratch, and output child
leases without changing the existing transform or 640-byte runtime receipt
semantics.

**First slice:** implement the image path with deterministic child identities,
charge-before-use ordering, candidate-mutation abort, exact child retirement,
and a final zero-state assertion. Add one independent allocation/retirement
oracle and stale-child tests before extending the same contract to audio and
video. Reuse [Media Runtime Transaction](MEDIA_RUNTIME_TXN.md).

### AI runtime family registry

Define one small part of the common vocabulary from the
[Glacier AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md): a family ID, operation ID,
typed input/output kind, numerical policy, or explicit unsupported result.

**First slice:** a fixed bounded registry value plus malformed/unknown fixtures
and a read-only renderer. It must not claim that registering a family makes it
executable.

### Stateless encoder result envelope

Design a typed result for one embedding, reranking, or classification fixture.
Keep logical batch-item identity, tensor shape, normalization/tie policy,
artifact root, execution-plan root, and publication sequence explicit.

**First slice:** pure encode/decode/verify plus an independent Python model; no
weights, model download, backend, or quality claim.

### Model-family adapter lifecycle

Prototype `inspect → plan → prepare → validate candidate → publish/abort` with
two fake families that have different state/output semantics.

**First slice:** one stateless vector family and one stateful step family under
zero ambient capabilities, fixed buffers, and deterministic rejection tests.

### ResourceBank property tests

Generate bounded sequences of admit, subdivide, publish, retire, cancel, and
release operations, then check exact zero-state recovery.

**First slice:** one deterministic seed and one minimized stale-handle failure.

### Paged-KV ownership restore fixture

This slice is now implemented with canonical committed-row images, durable
payload membership, full source-chain verification, an actual fresh cache, and
foreign-generation rejection.

The following slice is also complete: a fixed runtime state composes the
restored cache with sampler/RNG, output, sequence, and commit lineage, then a
fresh process publishes the next model-free token without duplicated output.
See [Continuation Live Restart](CONTINUATION_LIVE_RESTART.md).

The durability slice is now also complete as a model-free prototype: one
immutable archive plus a fixed selector survives worker termination after all
seven write, sync, rename, and directory-sync phases, then a fresh process
resumes the next token. See
[Continuation Checkpoint File](CONTINUATION_CHECKPOINT_FILE.md).

**Next slice:** compare uninterrupted and resumed output for one small legal
production-model fixture under a declared deterministic numerical mode.

### Live provider adapter boundary

Design a small out-of-core interface that renders requests, counts the exact
wire, performs transport, and returns terminal usage without importing secrets
into core.

**First slice:** fake adapter plus contract tests; no real network call.

## Advanced projects

### Durable sweep recovery state machine

The in-memory path now separates collection planning, prepare/abort staging, and
destructive commit capabilities. Commit regenerates the plan, validates every
canonical retired target before mutation, emits exact before/after accounting,
and rejects replay against the changed snapshot. A fixed 784-byte body/footer
record now carries the canonical commit evidence, reconstructs both receipts,
and passes independent Zig/Python mutation-complete verification. It performs no
filesystem I/O and does not make the transition durable. An allocation-free
anchored classifier now returns the exact committed prefix and distinguishes
short bodies, a body without footer, a matching partial footer, and corrupt
complete evidence. A snapshot-bound writer model now separates append from
repair authority, enforces ordered body/footer sync, poisons uncertain state,
and explores every partial-write boundary in Zig and Python.

**Completed slices:** fixed pointer-free evidence record, separate commit footer,
chain position, exact pinned expectations, semantic receipt reconstruction, a
pure stream classifier, exclusive snapshot binding, separate append/repair
capabilities, and exhaustive cross-language append, mutation, foreign-chain,
partial-I/O, poison/reopen, and repair fixtures.

The POSIX adapter now implements the next boundary with descriptor-relative
one-component admission, no-follow open, exclusive advisory locking,
device/inode/link/permission fencing, explicit-offset write-all, file and
directory sync, namespace-replacement detection, fresh-read reopen, and exact
repair. Native and Python workers terminate after all six append/repair phases.

**Completed slice:** real host-filesystem adapter and process-death conformance
on the promoted macOS development host, plus portable Linux compilation.

The destructive path now computes an exact receipt and predicted post-state
without mutation, syncs that fixed record before deallocation, proves an
injected post-publication failure leaves the store unchanged, and reconciles the
exact old/new snapshots idempotently in Zig and Python.

**Completed slice:** publication-before-deallocation ordering for the in-memory
payload store.

The payload byte plane now uses a canonical tenant snapshot, a fixed 968-byte
reclaim record carrying every exact target, and copy-on-write promotion under a
stable lock inode. Native and independent Python workers terminate after plan
write/sync/directory-sync and candidate write/sync/rename/directory-sync, then a
fresh process recovers the exact old or new root idempotently.

**Completed slice:** native durable payload bytes and seven-boundary
process-death conformance on the macOS development host.

**Completed slice:** a canonical ownership plan now reacquires a fresh
ResourceBank/LeaseTree and charges exact objects before they become live.

**Completed slice:** canonical committed-row images now rebuild a fresh
paged-KV cache under those reacquired nodes and reject foreign page identity
before publication.

**Completed slice:** a fixed runtime wire now composes sampler/RNG/output,
logical KV, exact sequence, and commit lineage; a fresh process publishes the
next token without duplication and returns ownership to zero.

**Completed slice:** an immutable complete checkpoint archive plus fixed root
selector now survives process death at every archive/selector durability phase
and launches a fresh live resume after recovery.

**Next slice:** add an uninterrupted/resumed small production-model comparison.
A separate contributor slice can run the existing evidence, payload, and
restart campaigns on native Linux filesystems.

### Resolver adversarial fixtures

Extend the in-memory resolver without adding storage authority.

**First slice:** table-driven malformed grants and catalogs covering every
public resolver error while proving destination bytes and accounting remain
unchanged on pre-copy failure.

### Tenant-safe immutable page store

Explore content-addressed immutable pages with tenant-scoped access, provenance,
and corruption handling.

**First slice:** threat model and fake-store state machine.

### Capability-isolated extensions

Define an extension boundary whose declared capabilities can be admitted and
recorded before executing third-party planner, tokenizer, or transport code.

**First slice:** capability vocabulary and fail-closed negotiation tests.

### Generative-media state adapter

Model a tiny deterministic latent plus scheduler-step state without an image or
video model. Bind artifact, numerical policy, current step, latent root,
candidate output, cancellation, checkpoint, and publication lineage.

**First slice:** pure state machine that survives one process restart and never
publishes the same synthetic media chunk twice.

### Agent action authorization boundary

Separate a model-proposed action from permission to invoke a tool. A proposal
may name a schema and arguments but cannot acquire network, filesystem, process,
or credential authority by itself.

**First slice:** one fake idempotent tool, exact proposal/result roots,
operation/byte ceilings, cancellation, replay rejection, and no real I/O.

### Production weight pager

Replace the mechanics prototype with logical representation identity, pins,
async reservations, actual resident-byte accounting, and execution integration.

**First slice:** pure state machine with a fake backend; no performance claim.

## Non-code contributions

- Reproduce a documented command on a new platform.
- Review a format table against the encoder and decoder.
- Improve diagrams, examples, error messages, or accessibility.
- Minimize a failing fixture.
- Translate an onboarding guide while keeping English as the normative contract.
- Review evidence claims for scope and reproducibility.

## Proposing a new project

A useful proposal identifies one user problem, one smallest mergeable behavior,
named rejection cases, an acceptance command, and what remains out of scope. New
ideas are welcome even when they do not fit an existing roadmap track.
