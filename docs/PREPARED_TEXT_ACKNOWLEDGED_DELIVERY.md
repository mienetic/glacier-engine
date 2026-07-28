# Acknowledged Prepared-Text Delivery

Glacier's R1i path is an experimental local delivery protocol for the bounded
prepared-text runtime. It joins each committed target token to a canonical
result acknowledgement, a descriptor-relative durable sink, an immutable
progress checkpoint, and the exact selector generation that may authorize the
next target process.

The immediate goal is narrow and user-visible: after generation two has
selected a clean source exit, killing a target must not apply the same visible
token twice. A fresh target may recompute an unacknowledged transaction, but it
may advance durable progress only with the exact acknowledgement returned by
the sink.

This is an experimental Zig surface and retained correctness fixture. It is
not a distributed lease, a remote-provider exactly-once protocol, a physical
power-loss claim, or production-model evidence.

Acknowledgements are hash-canonical evidence, not authenticated capabilities.
The generic progress codec assumes its caller obtained the ACK from the
exclusive durable sink in the declared transaction order. The retained worker
enforces and audits that order; the codec alone is not a hostile-writer or
multi-tenant security boundary.

## Protocol layers

The implementation keeps four responsibilities separate:

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

`prepared_text_acknowledged_delivery.zig` is the compile-once public facade for
those layers.

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
clean source has published one token and selected generation two:

```text
generation 1  source live
  → generation 2  source exited, resume at sequence 1
  → generation 3  sequence 1 acknowledged, resume at sequence 2
  → generation 4  sequence 2 acknowledged, resume at sequence 3
  → generation 5  sequence 3 acknowledged, terminal at sequence 4
```

Each nonterminal generation contains seven ordered objects:

1. the exact immediate predecessor selector;
2. the new canonical prepared-text checkpoint;
3. the successor execution plan;
4. the successor residency binding;
5. the successor transcript segment;
6. the restart manifest; and
7. the result acknowledgement.

The terminal generation contains the predecessor selector and set, terminal
semantic, final acknowledgement, and canonical little-endian `u32` output.
Decoding recomputes the output root and requires its final token to equal the
acknowledgement token.

The generic checkpoint-file lease can load a retained predecessor only by its
content root and revalidates the complete set before returning borrowed bytes.

## Claim boundary

The current claim is limited to:

- cooperative local processes on the descriptor-relative POSIX adapter;
- one fixed-length, pre-tokenized synthetic text fixture;
- target-process `SIGKILL` at named host-operation boundaries;
- exactly one durable local sink application for each target-side global
  sequence; and
- canonical terminal token output equal to the uninterrupted fixture oracle.

It does not yet cover:

- interruption while the source creates the sink's initial empty selector;
- source death before generation two;
- raw-text tokenization or variable-length/early-EOS output;
- remote APIs, databases, queues, or non-idempotent tools;
- device-resident/GPU continuation;
- physical storage or system power loss;
- Win32 durable-file behavior;
- native Linux/FreeBSD recovery evidence; or
- a production model and tokenizer.

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
  bench.tests.test_prepared_text_result_sink
```

The full process-death campaign is exposed through its own build gate and
reuses one compiled worker:

```bash
tools/zig-with-ephemeral-cache.sh build \
  prepared-text-recovery-test \
  -Dmetal=false -Doptimize=ReleaseSafe -j2
```

The gate launches 19 real `SIGKILL` victims: one after the model step, ten
across sink publication, one after sink acknowledgement, and seven across
checkpoint publication. It independently observes nine previous and ten
successor sink selectors, plus 17 previous and two successor checkpoint
selectors. Every baseline, source, victim, recovery, and audit process has a
distinct PID. The final audit requires three sink applications at global
sequences `1..3`, a generation-five terminal set at sequence four, a canonical
four-token output equal to the uninterrupted oracle, matching final
acknowledgement/prefix lineage, and zero live runtime ownership.

The report is evidence only for the declared fixture and crash model.

## Contributor follow-ups

Useful independent slices include:

- add a read-only inspector that renders identities and counts without token
  payloads;
- reproduce the POSIX campaign on a native Linux filesystem and retain its
  machine/filesystem envelope;
- add malformed nested-progress fixtures to the independent decoder;
- design the separate pre-generation-two source journal without weakening the
  source-exit barrier; and
- connect a declared redistributable model/tokenizer profile after the raw-text
  golden path is frozen.
