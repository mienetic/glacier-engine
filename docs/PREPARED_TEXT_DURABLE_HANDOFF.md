# Durable Prepared-Text Handoff

Glacier's prepared-text handoff is an experimental fresh-process continuation
protocol for the fixed-length `SessionV3` path. It joins canonical restart
context, checkpoint and successor evidence, an exact source-exit receipt, an
exclusive selector lease, a canonical generation-one replay contract, one
target activation grant, and a receipt-independent terminal semantic.

The protocol is designed to fail closed. A target cannot become runnable from
checkpoint evidence alone: it must open the selected source-exited generation,
hold its exclusive lease, pin that exact selection into a one-shot activation
grant, and pass the grant through restored admission and activation.

This is a retained correctness fixture and an experimental Zig API. It is not
yet a production recovery service, a general distributed lease, or a durable
external result-delivery system. The
[acknowledged delivery extension](PREPARED_TEXT_ACKNOWLEDGED_DELIVERY.md)
builds a replay-safe local sink/progress chain after this handoff without
changing the source-exit contract described here.

## What is canonical

The source constructs one pointer-free restart manifest containing:

- prompt token IDs in canonical little-endian `u32` form;
- `OptionsV1` and the local prepared-text `PlanV1`;
- the complete bound Common Model Contract artifact, execution-plan, and
  residency records;
- checkpoint `ExpectedBindingsV1`;
- the source publication context and retained receipt evidence; and
- the proposed target ownership identity.

Encoding revalidates the relationships before publishing destination bytes.
Decoding reconstructs the source context from the canonical bound records
instead of accepting contradictory duplicate structures. The manifest carries
evidence only; it does not serialize a pointer, Scheduler, Bank, service permit,
live receipt authority, or runnable Session.

Before that archive exists, generation one retains a separate canonical source
replay contract. It contains the pre-tokenized prompt, options, scheduling and
bound-plan inputs, recomputed plan/bound-plan/model roots, stable source runtime
identity, request epoch, publication sequence, challenge, target ownership, and
the exact empty-sink implementation, instance, ledger, and selector roots. The
contract is pointer-free replay evidence only. It grants no Scheduler, Bank,
checkpoint, sink, or target authority.

The durable fresh-process archive contains exactly five ordered objects:

1. the canonical prepared-text checkpoint;
2. the canonical successor execution plan;
3. the canonical successor residency binding;
4. the canonical successor transcript segment; and
5. the canonical restart manifest.

The checkpoint and three successor records remain independently verifiable.
The fifth object supplies the bounded trusted context that a fresh target needs
to reproduce those checks without a native-struct or JSON sidecar. A
four-object evidence helper may still be useful inside one process, but the
fresh-process path uses the five-object restart archive.

## Selector generations

The base handoff uses three selected meanings:

| Generation | Selected state | What it permits |
| --- | --- | --- |
| 1 | `source-live` marker plus replay contract | A source may run or replay the unpublished prefix only while it holds the exclusive lease and its source-live grant remains valid. No target activation is allowed. |
| 2 | `source-exited` authority | A successful source process has closed the exact publication binding; the selected set carries its real source-exit receipt, the five-object restart archive, and the byte-identical replay contract. A fresh target may hold one live lease-pinned activation at a time; releasing it permits a deterministic retry. |
| 3 | terminal semantic | The target reached the declared terminal position and selected a canonical terminal semantic that recursively retains the generation-two authority lineage. |

The generation-two selector names the generation-one predecessor. Before
granting target authority, the decoder loads that retained predecessor,
reconstructs its selector, and requires the two generations to contain the
byte-identical replay contract. The generation-three selector names the
generation-two selector and archive. Decoders verify this immediate lineage as
well as request epoch, publication sequence, challenge, object order, ABI,
lengths, and roots. No archive is allowed to choose or rewrite its own trust
root.

The acknowledged extension retains generation two as the same source-exit
authority, then uses nonterminal generations three and four plus terminal
generation five. Each edge advances exactly one global sequence and carries
the exact durable sink acknowledgement for that token.

## Source transition

The source acquires the durable selector lease before becoming live. It then:

1. canonically validates the source replay input and publishes or recovers the
   exact generation-one marker plus contract without replacing a foreign or
   successor checkpoint;
2. creates an address-stable `SourceLiveGrantV1` over that exact selection and
   the lease's sole consumer claim;
3. opens or creates only the contract's exact empty sink before the first model
   step;
4. binds the grant to the live Scheduler/coordinator/Bank, request identity,
   sequence `N`, publication-permit generation `G`, and source receipt;
5. runs to an eligible idle non-terminal boundary and captures the checkpoint,
   successor records, and canonical restart manifest;
6. begins a publication-handoff barrier against the exact predecessor selector
   and prepared archive, moving the grant from bound to handoff;
7. atomically closes the source publication session, Scheduler lane, and Bank
   receipt, producing a real pointer-free source-exit receipt; and
8. publishes generation two with the byte-identical contract before releasing
   the durable lease.

Aborting the handoff returns the grant to its bound live phase. Committing moves
it to exit-committed; completion accepts only the exact immediate
generation-two selector, advances the consumer claim from generation one to
two, then releases it.

The source-exit receipt binds the exact Scheduler/coordinator, source receipt,
request epoch, expected next sequence, final publication-permit generation,
checkpoint, prepared archive, successor segment, target ownership intent, and
predecessor selector. An abort before the source-exit commit restores the
ordinary source lifecycle; a committed exit leaves the old Session unable to
publish again.

If the source process dies before generation two is durably selected,
generation one remains selected. A fresh process may replay the exact
unpublished deterministic prefix under the same lease and contract. It cannot
infer source exit, promote portable checkpoint bytes, or fabricate a receipt
for the dead process. Instead, the successful replay performs the ordinary
handoff and produces its own source-exit receipt. This is safe only for the
retained profile because no durable acknowledgement or external effect exists
before generation two.

Recovery refuses rollback when any durable successor evidence exists, refuses
foreign or partial checkpoint/sink state, and never resets a nonempty sink.
Initial checkpoint and sink publication use atomic no-replace or selector
replacement operations with descriptor-relative identity checks. A crash may
therefore expose only an absent state or the exact prepared initial state
declared for that boundary; candidate files grant no authority.

## Target transition

A fresh target opens the durable directory and keeps its exclusive lease for
the whole activation lifecycle. It:

1. requires selected generation two and verifies the source-exit/archive pair;
2. loads the retained generation-one predecessor and requires its contract to
   match generation two byte for byte;
3. opens the sink under lock, accepts only the contract's exact empty state or
   the exact one-transaction-ahead replay state for the selected generation,
   and retains that lock across activation and apply;
4. decodes the canonical restart manifest and reconstructs the checkpoint,
   source, target, prompt, option, plan, and bound-plan context;
5. creates one address-stable `SelectedSourceExitGrantV1` backed by a consumer
   claim on the live lease;
6. passes that grant to `prepareRestoredAdmissionV1`, which creates the
   barrier-held target admission;
7. passes the same grant through `SessionV3.startRestoredV1`, which performs
   charge-before-materialize restore at global sequence `N`;
8. continues execution to the fixed terminal position;
9. selects generation three with the exact terminal semantic; and
10. marks the grant terminal-selected before retiring the restored Session and
   releasing the consumer claim and lease.

The grant is process-local and address-stable. Its root binds the lease,
consumer claim, generation-two selector, source exit, request/sequence,
checkpoint/archive/segment, target intent, and challenge. A second concurrent
grant from the same lease rejects, copied or stale grants reject after the
first phase winner, and the lease cannot close while its consumer claim is
live. Once a non-terminal grant releases its claim, a fresh grant may retry
generation two.

Aborting prepared admission returns the grant to `ready`; the caller can then
release its consumer claim while leaving generation two selected for
deterministic retry. Cancelling an activated non-terminal target completes and
releases the consumed grant while generation two remains retryable. A terminal
target must first select generation three; it cannot retire successfully while
the grant still names only generation two.

## Terminal semantic equivalence

The ordinary source/oracle run and the ownership-remapped target cannot compare
their raw terminal result envelopes byte-for-byte because those envelopes bind
different Scheduler, Bank, receipt, residency, and execution-plan-generation
authority.

`TerminalSemanticV1` projects the equality surface that should survive that
authority remap. It binds the immutable model/request and token domains,
canonical local plan, prompt, output tokens, logical KV, RNG, sampling state,
and final publication position. It deliberately excludes receipt and
placement-specific authority fields.

Generation three carries that semantic plus the exact generation-two selector
and source-exited archive. This preserves two separate statements:

- the resumed computation is semantically equal to the uninterrupted oracle
  under the declared numerical policy; and
- the result descended from the exact selected source-exit authority.

Semantic equality is not a claim of bitwise equivalence across arbitrary
backends or numerical policies.

## Retained separate-process demo

Run the focused demo with disposable Zig caches:

```bash
tools/zig-with-ephemeral-cache.sh build prepared-text-live-restart-demo \
  -Doptimize=ReleaseSafe -Dmetal=false -j2
```

The parent executable runs three bounded worker invocations:

1. **baseline:** completes the synthetic prepared-text request and writes the
   terminal-semantic oracle, then exits;
2. **source:** starts independently, publishes through sequence `N = 1`,
   commits source exit, selects generation two, returns source Scheduler/Bank
   ownership to zero, and exits; and
3. **target:** starts in a different process, proves that a competing durable
   lease would block, decodes the five-object archive, consumes the one-shot
   activation grant, resumes at `N`, reaches the terminal position, selects
   generation three, matches the baseline terminal semantic, and returns its
   Scheduler/Bank/LeaseTree ownership to zero.

The fixture checks distinct source and target process IDs, no source
reconstruction in the target, no duplicate sequence in the retained run, and
final selector generation three. It uses a tiny generated model fixture and
does not download production weights.

## Durability and replay boundary

The durable file implementation used by this handoff is currently the
descriptor-relative POSIX adapter. Its lock, no-follow, identity, mode,
single-link, file-sync, rename, and directory-sync checks are not a Windows
durable-file implementation. Portable wire decoding and cross-compilation do
not change that support boundary. The strict initial-checkpoint primitive is
available on macOS, iOS, and Linux. The full process gate supports native
macOS/Linux, retained 49-victim evidence is currently macOS-only, and other
targets fail closed because their atomic no-replace publication primitive is
not implemented.

The protocol prevents a target from activating while generation one is
selected and prevents two target grants from sharing one live lease. Before
generation two it permits only replay of the unpublished retained source
prefix. After generation two, a target crash may reopen the exact predecessor
and recompute from `N`; the idempotent sink and acknowledged selector progress
ensure that target sequences `1..3` apply once to the durable POSIX ledger.

The compile-once recovery campaign uses 49 distinct victims: seven across
generation-one checkpoint bootstrap, 23 across empty-sink creation and the
source transition, and 19 across target model/sink/checkpoint progress. Each
victim emits a gated ready frame and self-raises real `SIGKILL`; the controller
requires the exact signal exit. An independent decoder permits only the
declared absent, exact-predecessor, or exact-successor durable state, then a
fresh process converges to generation five and the uninterrupted semantic
oracle.

This does not turn canonical ACK bytes into authenticated capabilities or
establish exactly-once behavior for a remote API, database, queue, or tool.

## Current nonclaims

This slice does not establish:

- a Win32 durable selector/locking adapter or native Windows recovery evidence;
- GPU execution, GPU-resident checkpointing, device-loss recovery, or
  cross-device numerical equivalence;
- production-model quality, broad tokenizer support, early EOS, or
  variable-length terminal output;
- authentication, encryption, remote consensus, host migration, or a
  distributed fencing service;
- replay after a source-side external effect or acknowledgement;
- hostile or non-cooperative writers and physical power-loss durability;
- arbitrary remote or non-idempotent effects outside the acknowledged local
  sink profile; or
- production latency, throughput, power, thermal, or soak evidence.

## Contributor entry points

Useful bounded follow-up projects include:

- add deterministic cancellation and repeated-handoff campaigns around the
  generation-one replay boundary;
- implement a Win32 durable-file adapter with native process-death campaigns;
- add retained native Linux and FreeBSD filesystem campaigns;
- add an independent decoder and mutation campaign for the restart manifest
  and three-generation chain;
- add property tests for grant phase transitions, selector substitution, and
  lease-loss faults;
- extend the workload lab with repeated handoff, cancellation, crash-window,
  memory-growth, and bounded-soak scenarios; and
- specify device-resident continuation and GPU-loss recovery without weakening
  charge-before-materialize ownership.

See [Prepared Text Session](PREPARED_TEXT_SESSION.md),
[Prepared Text Restore Admission](PREPARED_TEXT_RESTORE_ADMISSION.md),
[Prepared Text Checkpoint](PREPARED_TEXT_CHECKPOINT.md), and
[Prepared Text Successor Evidence](PREPARED_TEXT_SUCCESSOR.md) for the
component contracts composed by this protocol. See
[Acknowledged Prepared-Text Delivery](PREPARED_TEXT_ACKNOWLEDGED_DELIVERY.md)
for the post-handoff sink, generations three through five, and target-death
campaign.
