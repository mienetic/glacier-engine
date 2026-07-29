# Acknowledged Prepared-Text Delivery

Glacier's R1j/R1k-b2/R1k-b3 path is an experimental local recovery, delivery,
and read-only inspection protocol for the bounded prepared-text runtime. Its
filesystem composition is available through public experimental Zig entry
points. The path retains a canonical source
replay contract plus the exact package/tokenizer/raw UTF-8 input in generation
one, requires an exact empty descriptor-relative sink before the source
computes, and joins each committed target token to a canonical result
acknowledgement, immutable progress checkpoint, and exact selector generation
that may authorize the next process.

The immediate goal is narrow and user-visible. Before generation two, a fresh
source process may replay only the unpublished deterministic prefix named by
generation one; after generation two, killing a target must not apply the same
visible token twice. A fresh target may recompute an unacknowledged
transaction, but it may advance durable progress only with the exact
acknowledgement returned by the sink.

This is an experimental Zig surface and retained correctness fixture. It is
not a distributed lease, a remote-provider exactly-once protocol, a physical
power-loss claim, or production-model evidence.

Acknowledgements are hash-canonical evidence, not authenticated capabilities.
The generic progress codec assumes its caller obtained the ACK from the
exclusive durable sink in the declared transaction order. The retained worker
enforces and audits that order; the codec alone is not a hostile-writer or
multi-tenant security boundary.

## Protocol layers

The implementation keeps seven responsibilities separate:

1. `prepared_text_result_sink.zig` projects one valid
   `CommitReceiptV1` into a canonical delivery input and a 424-byte
   `ResultAcknowledgementV1`.
2. `prepared_text_result_sink_file.zig` stores a complete immutable
   acknowledgement ledger and selects it through one atomic POSIX root switch.
3. `prepared_text_acknowledged_progress.zig` composes that acknowledgement
   with the exact predecessor selector and the next restart or terminal
   evidence.
4. `prepared_text_acknowledged_restore.zig` pins a selected nonterminal
   generation to the exclusive lease's process-local consumer claim.
5. `prepared_text_committed_output.zig` reconciles one caller-verified
   checkpoint prefix with one decoded sink selection without I/O or authority.
6. `prepared_text_committed_output_file.zig` opens, validates, and rereads the
   selected checkpoint and sink before returning that reconciled view;
   `prepared_text_result_inspector.zig` supplies the read-only JSON command.
7. `prepared_text_durable_runtime.zig` composes the existing checkpoint, sink,
   archive, restore, and session modules into caller-owned generation-one
   bootstrap, one-step source advancement, and one-step target advancement.

`prepared_text_acknowledged_delivery.zig` remains the compile-once facade for
its established delivery subset: the result sink, input archive, durable sink
file, acknowledged progress, and restored activation. The committed-output
reader and durable-runtime modules are exported independently from the public
`glacier` root and are compiled by the package, inspector, and recovery gates.

The source-side composition uses three additional reusable contracts:

1. `prepared_text_source_recovery.zig` canonically records the validated plan
   bindings, source runtime identity, target ownership, and exact empty-sink
   identity required for replay.
2. `prepared_text_input_archive.zig` joins the stable package and prepared
   representation to tokenizer evidence, the raw-input binding, and exact UTF-8
   bytes; `prepared_text_source_lease.zig` retains it beside the contract and
   generation-one source-live marker without turning the bytes into runnable
   authority.
3. `prepared_text_durable_handoff.zig` embeds the same bytes in generation two
   and requires a target to validate the retained generation-one predecessor
   plus the selected sink's exact replay state before it can receive an
   activation grant.

## Source replay boundary

The source holds the exclusive checkpoint lease while it publishes or
recovers generation one, opens or creates the contract's exact empty sink, and
computes the first unpublished token. If the process dies before generation
two is selected, a fresh process repeats that prefix under the same lease and
contract.

Replay does not fabricate a source-exit receipt for the dead process. The
successful fresh process performs a normal handoff, obtains its own real
source-exit receipt, and publishes generation two with the byte-identical
generation-one contract. This replay is valid only because the retained
profile exposes no durable acknowledgement or external effect before
generation two. A nonempty, foreign, partial, or identity-drifted sink rejects
instead of being reset.

Generation two does not supersede its own trust anchor. Target admission loads
the retained generation-one set by the parent checkpoint root, reconstructs
its selector, compares the embedded contract byte for byte, and checks the
selected sink is either the contract's exact empty ledger or the exact
one-transaction-ahead acknowledgement produced before a prior target death.
The target retains the sink lock across admission, activation, and apply so
that state cannot drift between validation and replay. Candidate and orphan
files carry no authority.

## Transaction boundary

`lane_publication_txn.SinkV1.commit` is deliberately infallible,
allocation-free, nonblocking, and I/O-free. The durable sink therefore never
runs inside that callback.

The target performs the operations in this order:

```text
SessionV3.step
  → receive and validate CommitReceiptV1
  → apply receipt to durable result sink
  → receive canonical acknowledgement
  → encode checkpoint/progress or terminal set
  → publish the immediate selector successor
  → advance the process-local consumer claim
  → close restored Scheduler/Bank/LeaseTree authority
```

A crash before durable apply leaves the predecessor selected. A crash after
durable apply but before selector publication also leaves the predecessor
selected, but exact replay returns the original acknowledgement without a
second application. A crash during selector publication recovers only the
previous selector or its exact prepared successor.

## Delivery identity and replay

The delivery key is derived from:

- the canonical prepared-text plan root for the selected request;
- the request epoch; and
- the global transaction sequence.

The acknowledgement also binds the token ID, proposal root, transition root,
canonical commit-receipt root, sink implementation and instance identities,
application ordinal, predecessor acknowledgement, and predecessor/result sink
prefixes.

For one delivery key:

- identical content returns the byte-identical original acknowledgement with
  disposition `replayed`;
- a different token, proposal, transition, or receipt rejects as a conflict;
- a future or missing sequence rejects as a gap; and
- a successful first application advances exactly one ordinal and one global
  sequence.

Replay performs no durable write.

## Durable sink root switch

The POSIX adapter stores a complete content-addressed ledger, then atomically
replaces one fixed selector. A nonempty ledger contains the complete contiguous
acknowledgement prefix; it is not an append fragment that needs an ambiguous
tail repair.

The retained operation boundaries are:

1. ledger body write;
2. ledger body sync;
3. ledger footer write;
4. complete ledger file sync;
5. immutable ledger rename;
6. ledger directory sync;
7. selector temporary write;
8. selector temporary sync;
9. selector replacement; and
10. selector directory sync.

Reopening verifies the selector, referenced immutable ledger, complete
acknowledgement chain, file type, private mode, link count, and stable
descriptor-relative identity. Orphan candidates carry no selection authority.

## Selector generations

The fixed four-token fixture starts its acknowledged-delivery scope after the
successful source attempt has published one token and selected generation two:

```text
generation 1  source live + replay contract + raw-input archive
  → generation 2  real source exit + bound restart archive + replay contract
  → generation 3  sequence 1 acknowledged, resume at sequence 2
  → generation 4  sequence 2 acknowledged, resume at sequence 3
  → generation 5  sequence 3 acknowledged, terminal at sequence 4
```

The pre-tokenized compatibility shape contains seven ordered objects:

1. the exact immediate predecessor selector;
2. the new canonical prepared-text checkpoint;
3. the successor execution plan;
4. the successor residency binding;
5. the successor transcript segment;
6. the restart manifest; and
7. the result acknowledgement.

The additive raw-input shape contains an eighth object: the byte-identical
input archive at extension ordinal 6. The restart manifest remains ordinal 4
and the acknowledgement remains ordinal 5. Every successor re-tokenizes and
revalidates the archive against its current plan, and rejects archive omission
or substitution after a bound predecessor. The five-object terminal shape is
unchanged because it embeds the complete immediate predecessor set.

The terminal generation contains the predecessor selector and set, terminal
semantic, final acknowledgement, and canonical little-endian `u32` output.
Decoding recomputes the output root and requires its final token to equal the
acknowledgement token.

The generic checkpoint-file lease can load a retained predecessor only by its
content root and revalidates the complete set before returning borrowed bytes.

## Public one-step filesystem runtime

The public experimental `prepared_text_durable_runtime` module exposes three
write-side operations:

- `bootstrapFileV1` recomputes the package, tokenizer, raw-input, local-plan,
  and bound-plan evidence from caller-owned inputs, then creates or exactly
  recovers generation one;
- `advanceSourceFileV1` verifies generation one and its empty sink, executes
  exactly the first source token, and selects the recoverable generation-two
  source exit; and
- `advanceTargetFileV1` consumes one selected restart, applies or replays its
  exact sink acknowledgement, and publishes one nonterminal successor or the
  terminal selection.

Each call performs one bounded transition. The caller supplies the loaded
model, runtime storage or factory, routing policy, directory, storage bound,
sink identity, output storage, and fail-stop callback. Successful calls release
their filesystem lease before returning. Bootstrap leaves its caller-owned
Scheduler open; successful source and target receipts close their live runtime
ownership. The source-step call is idempotent for an already-selected exact
generation two, and the target-step call returns an already-terminal
disposition for an exact terminal selection.

The public `prepared_text_committed_output_file.inspectDirectoryV1` operation
is the read side. It borrows a directory and output buffer, performs no
recovery or repair, and returns a verified view whose visible bytes borrow the
caller's storage. See
[Public Prepared-Text Durable Runtime](PREPARED_TEXT_DURABLE_RUNTIME.md).

## Read-only committed-output view

R1k-b3 observes the selected checkpoint and result sink without taking either
writer lease. Each reader opens the active selector and its hash-named immutable
object read-only, verifies the complete pair, and rereads the selector. The
inspector then rereads both selectors again after reconciliation; a detectable
cooperative publication race at a final selector reread returns
`SelectionChanged`, while an initial-read identity or storage failure keeps its
underlying typed error.

Only two sequence relationships are accepted:

- `aligned`: checkpoint and sink next sequences and acknowledgement heads
  match; and
- `sink-exactly-one-ahead`: a nonterminal sink has one additional
  acknowledgement whose predecessor heads equal the checkpoint heads.

Terminal state must be aligned and have a nonempty acknowledgement prefix.
Every overlapping acknowledgement token must match the checkpoint output, and
every visible token must fit the retained `utf8-byte-v1` byte domain `0..255`.

The default report is metadata-only. `--reveal-output` explicitly adds token
IDs, byte hex, escaped bytes, and strict UTF-8 text only when valid. This
operation performs no lock, create, write, recovery, repair, or publication and
grants no authority. See
[Prepared-Text Result Inspector](PREPARED_TEXT_RESULT_INSPECTOR.md).

## Claim boundary

The current claim is limited to:

- cooperative local processes on the descriptor-relative POSIX adapter;
- strict initial-checkpoint recovery available on macOS, iOS, and Linux; the
  full process gate supports native macOS/Linux, retained 49-victim evidence is
  currently macOS-only, and other durable hosts fail closed until their atomic
  no-replace primitive is implemented;
- one fixed-length synthetic CPU text fixture with a strict UTF-8 byte
  tokenizer and exact retained raw-input archive;
- source- and target-process `SIGKILL` at named host-operation boundaries;
- deterministic replay of the unpublished generation-one prefix only while no
  durable acknowledgement or external effect exists;
- exactly one durable local sink application for each target-side global
  sequence; and
- canonical terminal token output equal to the uninterrupted fixture oracle;
  plus a read-only, metadata-first view for aligned or exactly-one-ahead
  cooperative selected state.

It does not yet cover:

- tokenizer profiles beyond the retained strict UTF-8 byte identity or
  variable-length/early-EOS output;
- remote APIs, databases, queues, or non-idempotent tools;
- replay after any external source-side effect;
- device-resident/GPU continuation;
- physical storage or system power loss;
- hostile or non-cooperative local writers;
- Win32 durable-file behavior;
- native Linux/FreeBSD recovery evidence;
- a production model and tokenizer;
- authentication, historical attestation, confidentiality, or privacy; or
- checked durable `text-run`, unary serving, or streaming result rendering for
  the separate ordinary-model package producer and process-local admission
  path; or
- non-POSIX native recovery evidence.

## Focused verification

Run the compile-once Zig gate:

```bash
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-acknowledged-delivery-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

Run the independent Python sink verifier:

```bash
python3 -m unittest \
  bench.tests.test_prepared_text_package \
  bench.tests.test_prepared_text_result_sink
```

Run the focused R1k-b3 inspector and independent committed-output oracle:

```bash
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-result-inspector-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

The combined process-death gate reuses one compiled worker:

```bash
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-recovery-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

The gate compiles one worker and reuses it for the 49-victim acknowledged
subcampaign plus the separate four-victim direct-terminal smoke. Every
acknowledged-path victim reaches its boundary through the public `bootstrapFileV1`,
`advanceSourceFileV1`, or `advanceTargetFileV1` entry point: seven
generation-one bootstrap boundaries, 23 source-transition boundaries, and 19
target-transition boundaries. The source matrix covers recovery admission, all
ten empty-sink publication phases, the first model step, handoff preparation,
real source-exit commit, every generation-two checkpoint publication phase,
and observation after generation two. The target matrix retains the
model-step, sink, acknowledgement, and progress-checkpoint boundaries.

The direct-terminal smoke injects real `SIGKILL` after its one model step,
after runtime retirement, after selector rename, and after generation-two
publication. An independent decoder requires exact generation-one visibility
and fresh `advanced` recovery for the first two, exact generation-two
visibility and fresh `already_selected` recovery for the last two, then a
fresh zero-step audit with exact predecessor lineage and no result-sink
namespace. This is bounded host-process-death evidence, not an exhaustive
storage-fault or power-loss campaign.

Each victim emits a gated ready frame and self-raises `SIGKILL`; the controller
requires the exact signal exit and a distinct PID. An independent Python
decoder admits only the declared absent, exact-predecessor, or
exact-successor checkpoint/sink state at each boundary, then a fresh process
recovers through generation five. The final audit requires three sink
applications at global sequences `1..3`, a generation-five terminal set at
sequence four, a canonical four-token output equal to the uninterrupted
oracle, matching final acknowledgement/prefix lineage, and zero live runtime
ownership.

The report is evidence only for the declared fixture and crash model.

## Contributor follow-ups

Useful independent slices include:

- add campaign-time monotonic-view assertions around the read-only inspector
  without granting it recovery authority;
- reproduce the POSIX campaign on a native Linux filesystem and retain its
  machine/filesystem envelope;
- add malformed nested-progress fixtures to the independent decoder;
- add deterministic cancellation and bounded repeated-handoff campaigns around
  the source replay boundary; and
- add a production-quality declared model/tokenizer package without weakening
  the retained exact-byte fixture.
