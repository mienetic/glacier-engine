# Continuation Capsule v1

Status: **prototype manifest ABI**. The fixed wire, full object verifier, and a
separate tenant-scoped in-memory resolver are implemented and tested. Durable
object storage, runtime restore, and crash-safe publication are not implemented.

`ContinuationCapsule` binds one committed AI checkpoint without copying its
large model, plan, or KV objects. The manifest is an identity and verification
boundary; it is not a state serializer and grants no authority.

## Bound state

The wire binds these nine position-typed objects:

| Index | Object | Intended content |
| ---: | --- | --- |
| 0 | model | Prepared model or immutable model-capsule identity |
| 1 | tokenizer | Tokenizer and normalization identity |
| 2 | execution plan | Backend, kernel, layout, worker, and strict policy plan |
| 3 | resource state | ResourceBank receipt/snapshot and LeaseTree commitments |
| 4 | lane state | LaneWeave request, service, cancellation, and trace state |
| 5 | KV state | Contiguous or paged KV root and reconstructable payload object |
| 6 | sampler state | RNG, sampler parameters, counters, and grammar/domain state |
| 7 | output state | Committed token journal and output position |
| 8 | publication receipt | Exact token-transaction commit receipt or transcript root |

Object position is semantic. Equal bytes in two positions produce different
roots.

## Fixed wire

All integers are little-endian. The encoded length is exactly 608 bytes.

| Bytes | Field |
| --- | --- |
| `0..8` | Magic `GCCAPV01` |
| `8..16` | Wire ABI `0x4743434100000001` |
| `16..24` | Encoded length `608` |
| `24..28` | Required-all-objects flag `1` |
| `28..32` | Reserved zero |
| `32..40` | Execution ABI |
| `40..48` | Request epoch |
| `48..56` | Publication sequence |
| `56..64` | Checkpoint generation |
| `64..72` | Committed KV token count |
| `72..80` | Committed output token count |
| `80..112` | Nonzero challenge SHA-256 |
| `112..144` | Parent capsule SHA-256; zero only for generation zero |
| `144..576` | Nine 48-byte typed object references |
| `576..608` | Envelope SHA-256 |

Each object reference is:

```text
u64 object_abi
u64 exact_payload_length
u8  typed_payload_sha256[32]
```

## Object identity

For fixed object index `kind`:

```text
typed_payload_sha256 = SHA256(
  "glacier-continuation-object-v1\0" ||
  LE64(kind) ||
  LE64(object_abi) ||
  LE64(exact_payload_length) ||
  exact_payload_bytes
)
```

The manifest envelope is:

```text
SHA256(
  "glacier-continuation-capsule-wire-v1\0" ||
  encoded_bytes[0..576]
)
```

ABIs and payloads are nonempty. Execution ABI, request epoch, publication
sequence, KV token count, output token count, and challenge are nonzero. Output
tokens cannot exceed KV tokens.

## Parent lineage

Generation zero requires an all-zero parent root. Every later generation requires
a nonzero parent capsule root. A durable restore layer must additionally prove
that the supplied parent is the authorized predecessor; the wire only makes the
lineage explicit.

## Verification levels

`decodeManifestV1` validates fixed structure, scalar rules, reference fields,
and the envelope. It intentionally does not authorize resume.

`decodeAndVerifyV1` additionally receives:

- the exact expected execution/request/checkpoint identity; and
- all nine exact object payloads and ABIs.

It recomputes the complete canonical wire and rejects any scalar, object, type,
length, root, order, or envelope substitution. Input objects may share storage,
but the output buffer may not overlap an object being hashed.

## Evidence

Run the credential-free conformance demo:

```sh
zig build continuation-capsule-demo -Doptimize=ReleaseSafe -Dmetal=false
```

Current fixture facts:

- 608-byte manifest;
- nine typed objects;
- 264 bytes of external fixture payload;
- zero payload bytes embedded in the manifest;
- shared Zig/Python golden root
  `b03dfe6cc29b64da03377a2d0cf1b57635f04d4fe8a2ffa1a8497cb8e55e1aeb`;
- every serialized byte position rejects after mutation, including mutations
  whose outer digest is recomputed;
- a valid foreign KV object rejects.

Run the independent verifier:

```sh
python3 -m unittest bench.tests.test_continuation_capsule
```

These are conformance facts, not proof of process restart, physical memory
savings, storage deduplication, or durability.

## Authority and security boundary

The capsule contains no pointer, path, file descriptor, credential, allocator
handle, scheduler permit, or output callback. Hashes establish identity and
composition, not publisher authenticity. A resolver must enforce tenant and
object-kind access, payload size limits, and trusted provenance before returning
bytes. A runtime must reacquire ResourceBank/LeaseTree ownership rather than
trusting a historical receipt as live authority.

## Next layers

1. ~~Capability-bounded read-only object resolver.~~ Implemented in memory with
   tenant, kind, ABI, length, root, scan, byte, and count admission.
2. ~~Tenant-scoped content-addressed bundle manifest.~~ Implemented with
   canonical ordinals and exact logical/unique fixture totals; no store yet.
3. ~~Bounded in-memory tenant object store.~~ Implemented with exact accounting,
   atomic import rollback, references, and quarantine; no durability yet.
4. ~~Generation-fenced lifecycle and dry-run collection evidence.~~ Implemented
   with explicit leases, repair, retirement, and exact root/lease coverage.
5. ~~Sweep prepare/abort consuming an exact plan.~~ Implemented with plan
   regeneration, a separate capability, and zero payload deallocation.
6. ~~Destructive sweep commit with exact allocator/accounting evidence.~~
   Implemented as a separately authorized atomic in-memory transition.
7. ~~Fixed body/footer sweep commit evidence record.~~ Implemented without
   filesystem, deletion, or recovery authority.
8. ~~Pure anchored sweep-record classification.~~ Implemented without I/O or
   repair authority.
9. ~~Snapshot-bound append/repair capability and deterministic crash model.~~
   Implemented without real filesystem or deletion authority.
10. Real atomic manifest/bundle publication and crash recovery.
11. Resource and page ownership reacquisition.
12. Live restore between two transactional token publications.
13. Paired restart-latency, disk-byte, RSS, and fault-injection campaigns.

Each layer must keep manifest identity separate from storage and execution
authority.

See [Continuation Object Resolver](CONTINUATION_OBJECT_RESOLVER.md) for the
implemented least-authority lookup contract and its evidence boundary.
See [Continuation Bundle](CONTINUATION_BUNDLE.md) for the canonical tenant blob
plan and its non-physical resource accounting.
See [Continuation Object Store](CONTINUATION_OBJECT_STORE.md) for the bounded
in-memory ownership and resource-accounting contract.
See [Continuation Object Collection Plan](CONTINUATION_OBJECT_COLLECTION.md)
for exact dry-run reachability and collection evidence.
See [Continuation Object Sweep Journal](CONTINUATION_OBJECT_SWEEP.md) for
capability-scoped non-destructive staging.
See [Continuation Object Sweep Commit](CONTINUATION_OBJECT_SWEEP_COMMIT.md) for
the exact retired-target removal and accounting boundary.
See [Continuation Object Sweep Record](CONTINUATION_OBJECT_SWEEP_RECORD.md) for
the fixed portable commit evidence and its non-durable boundary.
See [Continuation Object Sweep Writer](CONTINUATION_OBJECT_SWEEP_WRITER.md) for
the scoped publication model and remaining platform boundary.
