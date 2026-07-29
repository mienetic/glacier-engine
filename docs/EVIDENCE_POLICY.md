# Evidence Policy

Public Glacier claims must be reproducible, scoped, and no stronger than their
retained evidence.

## Claim classes

1. **Contract claim** — supported by deterministic tests and rejection cases.
2. **Fixture claim** — supported only for named input bytes and configuration.
3. **Machine result** — supported on one captured machine and workload.
4. **Campaign result** — repeated across the published matrix with uncertainty.
5. **Operational claim** — requires deployment evidence, failure handling, and a
   maintained support boundary.

Every result should use the narrowest applicable class.

## Required bindings

A retained artifact must bind or accompany:

- source and build identity;
- exact input/model/tokenizer identity;
- execution policy and randomness;
- correctness or quality result;
- machine envelope when physical performance is involved;
- raw samples, pairing/order, and validity decisions;
- verifier version and schema;
- the permitted claim and explicit exclusions.

## Evidence planes

Keep these distinct:

- **logical:** runtime-owned resource and token ledgers;
- **transactional:** before/after roots and commit receipts;
- **continuation:** typed object roots, parent checkpoint lineage, and expected
  resume identity;
- **resolution:** tenant scope, grant root, lookup limits, resolved kinds/bytes,
  and final composition outcome;
- **bundle:** semantic roots, tenant-bound blob roots, canonical ordinals, and
  logical/unique payload totals without implied physical storage;
- **store:** owned payload bytes, logical index charge, native capacity,
  references, quarantine state, rollback outcome, and snapshot root;
- **lifecycle:** lease capability, owner, generation, explicit tick/deadline,
  invalidation transition, repair capability/source/reason, and v2 snapshot;
- **collection:** exact audit snapshot, canonical root multiplicity, complete
  active-lease receipts, per-slot classification, collectible ceilings, and
  dry-run plan root without an implied deallocation;
- **sweep staging:** separately scoped grant, regenerated collection plan,
  unchanged snapshot, staged entry/byte ceilings, and functional prepare/abort
  roots without implied commit, deallocation, or durability;
- **sweep commit:** separately scoped destructive grant, canonical retired
  targets, regenerated plan, before/after snapshots and logical accounting,
  freed entry/payload/index totals, and allocator deallocation calls without an
  implied RSS reduction, secure erase, or durability;
- **sweep record:** fixed body/footer bytes, epoch/sequence/previous root,
  reconstructed grant and receipts, semantic accounting verification, and an
  ordered append plan plus anchored committed-prefix/tail classification without
  implied file writes, sync, truncation, repair, recovery, or durability;
- **sweep publication:** exclusive storage epoch/generation, exact observed
  stream and capacity snapshot, ordered body/footer operations, sync watermarks,
  poisoned uncertainty, explicit repair decision, discarded tail, and fresh
  reopen outcome without implied operating-system durability or deletion;
- **sweep file:** trusted directory descriptor, admitted component name,
  device/inode/link/permission identity, exclusive lock outcome, exact
  write/sync/truncate phase, file/directory sync result, namespace-replacement
  decision, and fresh-process reopen without implied power-cut durability or
  payload deletion;
- **sweep transition:** exact no-mutation preview, predicted post-state root,
  fully synced preview-record root, publication/deallocation boundary outcome,
  and old/new snapshot reconciliation without implied durable payload storage,
  power-cut survival, or secure erasure;
- **payload file:** canonical tenant snapshot bytes, fixed exact-target reclaim
  record, tenant/storage-epoch scope, old/new roots and lengths, stable lock
  identity, candidate write/sync, atomic rename, directory sync, and
  fresh-process reconciliation without implied lifecycle durability, power-cut
  survival, secure erasure, or live ownership restoration;
- **committed-output inspection:** stable selected checkpoint and sink roots,
  request/sink identity, aligned or exactly-one-ahead sequence state,
  acknowledgement heads, visible token/byte roots, and strict UTF-8 validity
  without implied writer authority, recovery authority, hostile-writer
  resistance, remote exactly-once delivery, or historical attestation;
- **transport:** chunks, terminal usage, retry, and cancellation events;
- **durability:** bytes written, synced, committed, repaired, and replayed;
- **physical:** RSS, device residency, frequency, thermal, and energy sensors;
- **quality:** exact tokens, numerical error, perplexity, or task evaluation.

A digest proves identity and chain integrity under its verifier. It does not prove
that an upstream observation was truthful or that a physical resource was
isolated.

## Payload disclosure

Read-only and metadata-only are different claims. An inspector that writes
nothing may still expose correlatable request roots, artifact identities,
epochs, generations, counts, timing, or payload-derived digests.

- Default diagnostic output should omit prompt, response, media, credential,
  license, and model payload bytes.
- Payload disclosure must be explicit and must name the exact representation.
- Byte-domain output must remain lossless; text may be emitted only after strict
  validation, never by replacing invalid bytes.
- A metadata-minimizing view is not anonymity, redaction, confidentiality, or a
  complete privacy policy.
- Read-only verification does not authenticate the publisher and does not grant
  execution, publication, repair, or recovery authority.

## Promotion rules

- Architecture work can merge with deterministic contract evidence.
- Performance wording stays diagnostic until paired validity gates pass.
- A single fixture never becomes a general model, platform, or billing claim.
- Missing telemetry is reported as unavailable, not inferred.
- Unsupported modes reject rather than disappearing from the artifact.
- Negative results and stopped tracks remain documented when they inform future
  design.

## Contributor checklist

Before publishing a result, ask:

- Can another person obtain or reconstruct every required input?
- Does an independent parser reject mutation, truncation, and substitution?
- Is the claim limited to what was actually measured?
- Are logical and physical quantities clearly labeled?
- Are credentials, prompt text, personal data, and private paths excluded?
- Would the wording remain true if the result were slower than hoped?

If any answer is no, keep the result diagnostic or fix the evidence bundle.

## Correction and retraction

When a public claim is found to be unsupported, update the document promptly,
link the corrective evidence, and preserve enough history to explain the change.
Correcting a result is normal scientific maintenance and should not be delayed to
protect a headline.
