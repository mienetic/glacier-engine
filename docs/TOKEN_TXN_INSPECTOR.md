# Token Transaction Inspector

`bench/token_txn_inspector.py` is a Python-first, read-only inspector for one
bounded strict-B4 TokenTxn evidence journal. It reuses the independent replay
in `bench/lane4_token_txn_event_evidence.py` and compares the candidate journal
with a complete expectation supplied by the caller.

This is an evidence-verification tool. It does not discover which expectation
should be trusted.

## Run the inspector

```sh
python3 bench/token_txn_inspector.py \
  --evidence path/to/token-txn.jsonl \
  --expectation path/to/token-txn.expectation.json
```

The default one-line JSON report is metadata-only and does not render token
IDs. Add `--reveal-token-ids` only when the report destination is authorized
to receive all four 64-token lane outputs:

```sh
python3 bench/token_txn_inspector.py \
  --evidence path/to/token-txn.jsonl \
  --expectation path/to/token-txn.expectation.json \
  --reveal-token-ids
```

The disclosure flag changes only the report. Both input files already contain
token IDs, so they require an appropriate storage and access policy regardless
of the selected report mode. Roots, epochs, and other default metadata can also
correlate a workload and are not anonymized or confidential.

## Trusted expectation

The expectation is canonical one-line ASCII JSON followed by one final newline.
Its schema is
`glacier.decode-lane4/token-txn-replay-expectation-v1`, with this exact
top-level field order:

1. `schema`;
2. `root_binding_sha256`;
3. `request_epoch`;
4. `resource_receipt_sha256`;
5. `head_sha256`;
6. `lane_outputs`.

The three SHA-256 fields are fixed 64-character lowercase hexadecimal strings.
`request_epoch` is one fixed-width lowercase hexadecimal `u64`.
`lane_outputs` contains exactly four arrays of exactly 64 fixed-width lowercase
hexadecimal `u32` token IDs. Unknown fields, alternate key order, JSON numbers,
duplicate keys, non-ASCII text, missing final newline, and values of the wrong
width fail closed. The expectation file is bounded to 4,096 bytes.

The caller must obtain this complete expectation through a separately trusted
workflow. Copying the roots and lane outputs from the candidate evidence into a
new expectation proves only that the two files agree with each other.

## What is checked

The inspector admits only the fixed strict-B4 geometry: one journal receipt
followed by 64 transaction-wave records, with four lanes and 64 token IDs per
lane. The evidence input is bounded to 1,064,960 bytes. Replay checks:

- canonical ASCII JSONL framing and fixed input bounds;
- exact retained ABI values, counts, sequence, lane masks, and terminal shape;
- the ResourceBank receipt digest and the root-bound initial digest;
- every previous/head link, wave digest, prepare acknowledgement, and commit
  digest;
- request epoch, root binding, resource receipt, final head, and every token ID
  against the caller-supplied expectation.

Inputs must be nonempty, stable regular files. The CLI opens them read-only
without following a final symbolic link and rejects an identity, size, or
timestamp change around the read. The application issues no write operation to
either input, although the filesystem may update access-time metadata for a
read. It does not scan a state directory, acquire a lease, contact a network
service, or execute a model. A successful report means that this bounded
journal is canonical and replays to the supplied expectation under the
retained contract.

## Report contract

The report schema is `glacier.decode-lane4/token-txn-inspector-v1`. It is one
canonical compact ASCII JSON line, bounded to 16 KiB. Every successful report
fixes:

- `replay_verified` and `read_only` to `true`;
- `authority_granted` to `false`;
- `token_ids_disclosed` to the selected disclosure mode;
- evidence length, fixed record/lane/transaction counts, transaction totals,
  sequence bounds, timestamp availability, and request epoch;
- retained ABI values, root binding, ResourceBank receipt root, initial and
  final chain heads, raw and canonical evidence digests, and expectation-file
  digest;
- bounded ResourceBank claim metadata and one domain-separated output digest
  for each lane.

The default field set contains no `token_ids` key. The opt-in mode appends one
`token_ids` matrix containing the exact four arrays of 64 lowercase hexadecimal
`u32` values.

Invalid arguments, input-file failures, malformed expectations, and replay
failures return status 2, leave stdout empty, and emit one generic diagnostic
that contains neither input path nor evidence content.

## Security and authority boundary

Digest and replay checks establish integrity and composition relative to the
supplied expectation. They do not establish:

- authenticity, publisher identity, attestation, or provenance of either
  input;
- that the expectation is correct, independently issued, or authorized;
- runtime, ResourceBank, model, storage, tenant, disclosure, or publication
  authority;
- hostile-writer resistance after the files have been opened;
- durability, physical storage behavior, production-model execution, quality,
  performance, or native CPU/GPU behavior.

Treat the expectation source and the report destination as separate policy
decisions. The inspector grants neither decision.

## Contributor gate

Run the focused dependency-free test with:

```sh
python3 -m unittest \
  bench.tests.test_lane4_token_txn_event_evidence \
  bench.tests.test_token_txn_inspector
```

The affected-path verifier selects changed-file Python syntax plus this focused
pair for the replay verifier, inspector, and their regression files. It
intentionally performs no Zig compilation for those focused paths.
