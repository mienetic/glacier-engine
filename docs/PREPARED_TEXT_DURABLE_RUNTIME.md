# Public Prepared-Text Durable Runtime

Status: **integrated experimental Zig composition surface**.

This document describes the current public filesystem foundation for the
retained prepared-text recovery path. It does not describe a durable
`glacier text-run` command: ordinary CLI and serving integration remain open.

## Public modules

The installed `glacier` module exports additive writer, wire, and reader
surfaces:

- `prepared_text_durable_runtime` composes the existing package, tokenizer,
  session, checkpoint, source-recovery, result-sink, acknowledged-progress,
  and restore contracts into one bounded writer transition per call; and
- `prepared_text_committed_output_file` reads and reconciles one selected
  checkpoint/result-sink view without taking writer authority;
- `prepared_text_terminal_source_recovery` and
  `prepared_text_direct_terminal` define a distinct sink-free generation-one
  contract and its exact generation-two terminal successor; and
- `prepared_text_direct_terminal_output` reads that terminal successor without
  opening or synthesizing a result sink.

These are experimental Zig APIs, not a stable C ABI or release-stability
promise.

## Writer operations

`prepared_text_durable_runtime` exposes the original three acknowledged-path
entry points plus two direct-terminal entry points.

The source and target entry points select sink capacity at runtime. One
concrete durable store accepts acknowledgement capacities `0..63`, so the
production durable runtime does not monomorphize a separate store for each
capacity. `fixedOutputPlanV1` routes fixed output count one to the sink-free
direct-terminal path and counts `2..64` to the acknowledged path with capacity
`N - 1`.

### `bootstrapFileV1`

This operation creates or exactly recovers the canonical generation-one source
selection. It re-tokenizes the caller's raw UTF-8 input and recomputes the local
plan, bound plan, source-recovery contract, and input archive from the loaded
model, package, prepared representation, tokenizer manifest, scheduling
identity, target ownership, and sink configuration.

The caller owns the model, Scheduler, directory, allocator, and storage bound.
A successful return closes the checkpoint lease and retains none of that
process-local authority.

### `advanceSourceFileV1`

This operation verifies one selected generation-one source, its retained
runtime identity, and its exact empty sink. It re-tokenizes the archived input,
recomputes the current plans, executes exactly the first source token, closes
the source runtime, and selects the recoverable generation-two source exit.

The operation is idempotent for an already-selected exact generation two: it
verifies and returns that selection without executing the model again.

Once the retained runtime identity has been read, this call consumes and closes
the caller's Scheduler. That remains true if a later ordinary typed error is
returned, so the caller must not attempt to reuse that Scheduler after this
point.

### `bootstrapDirectTerminalFileV1`

This operation creates or exactly recovers a distinct generation-one source
contract for `max_new_tokens == 1`. It retains the exact package, prepared
representation, tokenizer, raw input, local/bound plan, source runtime, request,
and challenge identities, but contains no target or result-sink facts.

### `advanceDirectTerminalSourceFileV1`

This operation revalidates the terminal source contract and archived input,
executes exactly one token, seals the terminal result, prepares the canonical
generation-two terminal set, and retires the source lane before publishing the
terminal selector. The generation and sequence edge is `1/1 -> 2/1`: generation
advances while the already-terminal publication sequence remains one.

No target is resolved, no restart checkpoint is captured, and no sink or
acknowledgement file is created. If the source process stops after retirement
but before selector publication, generation one remains authoritative and a
fresh runtime may deterministically repeat the unpublished computation.
Selected generation two replays without executing the model or requiring a
step-sink identity.

### `advanceTargetFileV1`

This operation consumes one selected restart. It initializes caller-owned
target runtime storage only after the retained target identity is known,
restores and advances one token, applies or replays the exact durable sink
acknowledgement, and publishes either the next nonterminal checkpoint or the
terminal selection.

An exact terminal selection returns `already_terminal`. The returned token
prefix borrows caller storage. User-visible committed output should be obtained
through the read-only filesystem API after writer authority has been released.

## Authority and failure boundary

The caller supplies runtime storage or factories, target routing, sink
identity, a descriptor-relative directory, bounded checkpoint storage, and a
`FailStopV1` callback. On the source path, ordinary typed errors may return
before the source exit is committed; later failures invoke the caller's
non-returning fail-stop callback. On the target path, fail-stop protection is
armed immediately before durable sink application and remains armed through
checkpoint selection, runtime closure, and the final caller-output copy.
The direct-terminal path completes all allocation, encoding, and publication
preparation first, then retires the lane and verifies zero Bank/Scheduler
authority. From that successful retirement through selector publication and
source-claim completion, every failure is fail-stop.

Successful source and target receipts state that runtime ownership is closed.
The APIs do not retain the model, allocator, directory, Scheduler, Bank, or
result-sink lease after return.

## Read-only committed output

`prepared_text_committed_output_file.inspectDirectoryV1`:

1. reads the active checkpoint selector and its selected immutable set;
2. normalizes the supported source-exited, acknowledged-progress, or terminal
   shape;
3. reads the active result-sink selector and immutable ledger;
4. reconciles only an aligned view or a nonterminal sink exactly one
   acknowledgement ahead; and
5. rereads both selectors before returning.

The function performs no create, lock, recovery, repair, rename, truncate, or
write operation. `visible_bytes` in the returned view borrow the caller's
output storage. A detectable cooperative selector change fails with
`SelectionChanged`; malformed, substituted, oversized, gapped, or inconsistent
state fails closed.

The standalone inspector adds metadata-first JSON and explicit lossless output
disclosure over this same filesystem API. See
[Prepared-Text Result Inspector](PREPARED_TEXT_RESULT_INSPECTOR.md).

`prepared_text_direct_terminal_output.inspectDirectoryV1` is the sink-free
reader for the direct path. It validates the selected generation-two set, its
embedded exact generation-one selector/set, terminal-source contract, input
archive, semantic, and one canonical little-endian token, then rereads the
selector before returning. Its view reports terminal state and zero
acknowledgements without opening a sink namespace.

## Retained process-death evidence

The existing compile-once prepared-text recovery campaign uses these public
writer entry points for all 49 real-process-death boundaries:

- seven generation-one bootstrap boundaries call `bootstrapFileV1`;
- 23 source-transition boundaries call `advanceSourceFileV1`; and
- 19 target-transition boundaries call `advanceTargetFileV1`.

The independent controller still admits only each boundary's declared absent,
exact-predecessor, or exact-successor filesystem roots and then requires fresh
convergence to the retained four-token terminal oracle. Public extraction did
not replace or weaken that evidence with a second implementation.

The sink-free direct-terminal path has a separate bounded smoke over four real
`SIGKILL` boundaries: after its one model step, after runtime retirement, after
the checkpoint selector rename, and after generation-two publication. The
first two cases retain exact generation one and require a fresh process to
advance it; the last two retain exact generation two and require fresh
recovery to return `already_selected`. An independent Python decoder verifies
the complete generation-one/generation-two lineage, terminal semantic, token,
state, selector, set, and read-only view roots. Every case finishes with a
fresh zero-step audit and an exact checkpoint-only namespace check. The
selector-rename case is host-process-death evidence, not power-loss evidence.

Run the deterministic delivery gate with:

```sh
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-acknowledged-delivery-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Run only the bounded direct-terminal process-death smoke with
`prepared-text-direct-terminal-recovery-smoke-test`. Run
`prepared-text-recovery-test` for the combined 49-boundary acknowledged
campaign plus the four-boundary direct smoke. Both recovery targets reuse the
same worker executable; the combined target does not introduce a second worker
compilation.

## Current nonclaims and open integration

This foundation does not yet provide:

- an exhaustive direct-terminal I/O-fault, storage-fault, or power-loss matrix;
- a public user-facing producer for the request-independent package manifest;
- durable `text-run`, unary serving, or streaming serving integration;
- a stable public ABI or cross-language session binding;
- variable-length or early-EOS durable output;
- GPU-resident continuation, remote delivery, or distributed exactly-once
  semantics;
- hostile-writer resistance, authentication, privacy, or physical power-loss
  persistence; or
- non-POSIX native recovery evidence or a Win32 durable-file adapter.

The retained evidence remains a bounded synthetic CPU fixture over the local
descriptor-relative POSIX durability adapter. It is correctness and recovery
evidence, not a model-quality, platform-support, or performance claim.

## Related documents

- [Acknowledged Prepared-Text Delivery](PREPARED_TEXT_ACKNOWLEDGED_DELIVERY.md)
- [Durable Prepared-Text Handoff](PREPARED_TEXT_DURABLE_HANDOFF.md)
- [Prepared-Text Result Inspector](PREPARED_TEXT_RESULT_INSPECTOR.md)
- [Verified Raw-Text Runtime Path](PREPARED_TEXT_RAW_INPUT.md)
- [AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md)
