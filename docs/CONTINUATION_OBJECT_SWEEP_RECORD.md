# Continuation Object Sweep Record v1

Status: **prototype durable-ready evidence format**. Native Zig and an
independent Python implementation encode, decode, and semantically verify the
same fixed 784-byte record and classify concatenated record streams. The format
and classifier perform no filesystem I/O and are not a durable journal, repair
policy, deletion authority, or crash-atomic state machine by themselves.

The record preserves the evidence for one already completed in-memory object
sweep. It embeds enough canonical data to reconstruct and verify the separate
commit grant, store commit receipt, and outer sweep commit receipt rather than
trusting copied roots alone.

## Boundary

```text
verified CommitGrantV1
  + verified RetiredCommitReceiptV1
  + verified CommitReceiptV1
  + record epoch / sequence / previous root / challenge
                         │
                         ▼
                736-byte record body
                         │
                         ├─ 704-byte canonical prefix
                         └─ 32-byte record root
                         │
                         ▼
                 48-byte commit footer
                  magic + sequence + root
                         │
                         ▼
           pure anchored stream classifier
      committed prefix + named incomplete/corrupt tail

heap/filesystem/network/clock authority: none
deletion/recovery authority: none
durability: not provided by this format alone
```

`appendPlanV1` first verifies the complete record, then returns the body and
footer as two ordered slices. A future storage adapter must write and sync the
body before it appends and syncs the footer. The current function does neither.

`classifyRecoveryV1` accepts caller-owned bytes and a pinned chain anchor. It
returns only classification and safe-prefix metadata. It never opens, writes,
syncs, truncates, repairs, or deletes storage.

## Fixed wire layout

All integers are unsigned little-endian values. Digests are 32 raw SHA-256
bytes. The format is serialized explicitly and never depends on Zig struct
layout or pointers.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | body magic `GCSWRB01` |
| 8 | 8 | ABI version |
| 16 | 8 | total encoded length, fixed at 784 |
| 24 | 4 | flags, fixed at zero |
| 28 | 4 | reserved, fixed at zero |
| 32 | 8 | record epoch |
| 40 | 8 | sequence |
| 48 | 32 | previous record root |
| 80 | 32 | record challenge |
| 112 | 248 | sweep commit grant through removal ceilings |
| 360 | 32 | commit-grant challenge |
| 392 | 32 | canonical target-set root |
| 424 | 32 | post-sweep snapshot root |
| 456 | 72 | nine before-accounting counters |
| 528 | 72 | nine after-accounting counters |
| 600 | 40 | five freed/deallocation counters |
| 640 | 32 | store commit root |
| 672 | 32 | outer sweep commit root |
| 704 | 32 | record root |
| 736 | 8 | footer magic `GCSWRF01` |
| 744 | 8 | repeated sequence |
| 752 | 32 | repeated record root |

The ABI is `0x4743535200000001`. The canonical record root is:

```text
SHA256(
  "glacier-continuation-sweep-record-body-v1\0" ||
  encoded_bytes[0..704]
)
```

Sequence 1 requires an all-zero previous root. Every later sequence requires a
nonzero previous root. This is a local chain-shape rule; a caller that needs an
exact chain must use `decodeAndVerifyV1` with the expected epoch, sequence,
previous root, sweep commit root, and record root.

## Semantic verification

Decoding does more than check framing and hashes:

1. require the exact length, magic, ABI, flags, reserved value, and footer;
2. recompute the body root and compare both stored copies;
3. reconstruct the complete `CommitGrantV1`;
4. derive its canonical authorization root;
5. reconstruct the store and outer commit receipts from the minimal wire fields;
6. verify all receipt roots, shared identities, removal ceilings, snapshot
   transition, and before/after accounting equations; and
7. enforce the record-chain shape.

Consequently, changing an accounting field and recomputing the record root is
not enough to make contradictory evidence valid. A fully valid record from
another epoch, chain position, previous root, or sweep commit also fails an
exact pinned expectation.

## Pure stream classification

`RecoveryAnchorV1` pins the record epoch, next expected sequence, and exact
previous record root at byte zero. An origin stream uses sequence 1 and the zero
previous root. A caller may scan a previously authenticated suffix by supplying
its predecessor root and next sequence.

The classifier walks fixed 784-byte records without allocation. A record enters
the committed prefix only after full framing, body/footer roots, embedded grant
and receipt semantics, epoch, sequence, and previous-root linkage verify.

| Status | Meaning |
| --- | --- |
| `clean` | Every supplied byte belongs to the verified committed chain; an empty origin is also clean |
| `short_body_tail` | 1–735 bytes remain after the committed prefix; incomplete bytes are not interpreted as a record |
| `body_without_footer` | One exact 736-byte body verifies semantically and against the next chain position, but no footer byte exists |
| `partial_footer_tail` | A verified body is followed by 1–47 bytes matching the canonical footer prefix |
| `corrupt_record` | A complete record, complete body, partial footer, or chain position contradicts the contract |

The result includes committed record/byte counts, tail bytes, first and last
sequence, and the final committed record root. `committed_bytes` is an observed
safe prefix, not permission to truncate the remaining bytes. In particular, a
complete invalid record is never downgraded to a recoverable torn tail.

## Deterministic fixture

The model-free fixture records one committed removal:

| Observation | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Store entries | 8 | 7 | -1 |
| Retired entries | 1 | 0 | -1 |
| Payload ledger | 255 bytes | 216 bytes | -39 bytes |
| Logical index ledger | 1,024 bytes | 896 bytes | -128 bytes |
| Allocator deallocation calls | 0 | 1 | +1 call |

The cross-language golden values are:

| Evidence | SHA-256 |
| --- | --- |
| Record root | `a9adfd0946468252bd879acc81456e2afe2e145b38f850869c75fd471d0bba06` |
| Complete encoded record | `3b3fb1adf8ed0b13b8e8719a3ade7dbb2a7133c0ea6d307598ee3b2941d7c6d3` |
| Two-record chained stream | `25009ee1f7e27989e54554fc797f19cec21dd96d3c392f25364d7ab868ee5538` |

The separate sweep-commit demo also feeds the receipts produced by a real
bounded-store mutation directly into this codec and verifies the resulting
record root `6f60f970772e06c422bccd2ac8bf99049126ad3df8d1fb5ee731c77c86c7fa52`.
The cross-language fixture above remains intentionally model-free and minimal.

Run the native demo:

```sh
zig build continuation-sweep-record-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Run the independent verifier tests:

```sh
python3 -m unittest bench.tests.test_continuation_object_sweep_record
```

Both suites reject every one-byte mutation across all 784 positions, every
truncation length, extension, a correctly rehashed accounting contradiction,
and a valid foreign record. The Zig encoder also proves that rejected input and
short destination buffers leave caller output unchanged. Classifier fixtures
cover every body/footer append boundary, every mutation in the second complete
record, valid-but-foreign epoch/sequence/previous-root chains, a rehashed
semantic contradiction, empty streams, and authenticated suffix scans.

## Publication layer

The capability-scoped writer contract and deterministic crash backend are now
implemented. They bind the classified bytes to one exclusive lease snapshot,
separate append from repair, enforce ordered body/footer sync, poison uncertain
operations, and cover every modeled partial-write boundary. They still perform
no real filesystem I/O. A directory adapter, platform lock/sync evidence,
destructive-transition ordering, and end-to-end process restart remain.

See [Continuation Object Sweep Commit](CONTINUATION_OBJECT_SWEEP_COMMIT.md) for
the in-memory transition whose evidence this format carries and
[Continuation Object Sweep Writer](CONTINUATION_OBJECT_SWEEP_WRITER.md) for the
least-authority publication and repair state machines, and
[Roadmap](ROADMAP.md) for the durability sequence.
