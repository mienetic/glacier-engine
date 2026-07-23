# Continuation Object Sweep Record v1

Status: **prototype durable-ready evidence format**. Native Zig and an
independent Python implementation encode, decode, and semantically verify the
same fixed 784-byte record. The format performs no filesystem I/O and is not a
durable journal, recovery policy, deletion authority, or crash-atomic state
machine by itself.

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

heap/filesystem/network/clock authority: none
deletion/recovery authority: none
durability: not provided by this format alone
```

`appendPlanV1` first verifies the complete record, then returns the body and
footer as two ordered slices. A future storage adapter must write and sync the
body before it appends and syncs the footer. The current function does neither.

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
short destination buffers leave caller output unchanged.

## What remains

The next bounded slice is a pure recovery classifier over concatenated record
bytes. It should distinguish a clean committed prefix, a short body tail, a
complete body missing its footer, and a corrupt complete record without opening
or modifying a file. Later work must separately define directory capabilities,
locking, body/footer sync, uncertain-writer poisoning, truncation policy,
destructive-transition ordering, and end-to-end crash tests.

See [Continuation Object Sweep Commit](CONTINUATION_OBJECT_SWEEP_COMMIT.md) for
the in-memory transition whose evidence this format carries and
[Roadmap](ROADMAP.md) for the durability sequence.
