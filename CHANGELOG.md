# Changelog

Significant user-visible changes will be recorded here. The project follows the
spirit of Keep a Changelog, but it does not claim semantic-versioning stability
before the first stable release.

## Unreleased

### Added

- Public contributor documentation, governance, support, security, and conduct
  policies.
- Glacier Engine visual identity and repository metadata.
- Proof-carrying provider evidence join over cost, gateway, and transport roots.
- Crash-recoverable provider cost journal store and recovery tests.
- Lossless context packing, token reconciliation, and allocation-free adapter
  fixtures.
- Transactional token publication with contiguous and paged KV state.
- Exact resource admission, LeaseTree ownership, and deterministic LaneWeave
  scheduling.
- Fixed 608-byte continuation capsule binding nine typed external AI-state
  objects, with allocation-free Zig verification and an independent Python
  verifier.
- Allocation-free continuation object resolver with tenant-scoped capability
  grants, bounded catalog scans and byte quotas, caller-owned output, and full
  post-resolution composition verification.
- Fixed continuation bundle manifest with separate semantic and tenant-bound
  blob roots, canonical first-occurrence dedup ordinals, exact logical/unique
  byte totals, and an independent Python verifier.
- Bounded tenant continuation object store with atomic bundle import, immutable
  payload ownership, duplicate reference reuse, exact payload/index accounting,
  quarantine, corruption checks, and allocator-failure rollback.
- Deterministic object lifecycle with generation-fenced leases, explicit logical
  expiry, quarantine invalidation, capability-bound repair, v2 snapshots, and
  matching Zig/Python receipt roots.
- Retained object retirement and bounded dry-run collection planning with exact
  root multiplicity, complete current-lease coverage, per-slot decisions,
  collectible ceilings, and matching Zig/Python evidence roots.
- Capability-scoped functional sweep prepare/abort journals that regenerate an
  approved collection plan, reject stale snapshots and tampered journals, stage
  exact collectible totals, and leave all payload bytes untouched.
- Atomic in-memory object sweep commit with a separate destructive capability,
  complete plan regeneration, canonical retired-target validation, exact
  before/after accounting, allocator-call evidence, and matching Zig/Python
  roots.
- Fixed 784-byte continuation sweep evidence record with body/footer framing,
  record chaining, semantic reconstruction of the commit grant and both
  receipts, pinned expectation checks, and independent Zig/Python fixtures.
- Pure anchored sweep-record classifier with exact committed-prefix metadata,
  five clean/incomplete/corrupt statuses, semantic and chain verification, and
  exhaustive cross-language append-boundary and mutation fixtures.
- Snapshot-bound continuation sweep publication with exclusive lease
  generations, separate append/repair capabilities, ordered body/footer sync,
  poisoned uncertain writers, explicit incomplete-tail repair, and exhaustive
  Zig/Python deterministic crash-boundary models.
- Descriptor-relative continuation sweep files with no-follow lookup,
  exclusive advisory locks, device/inode/link/permission fencing, ordered file
  and directory sync, replacement detection, independent Python verification,
  and six native plus Python subprocess-death boundaries.
- Exact no-mutation sweep commit previews with predicted post-state roots,
  file-synced publication before payload deallocation, injected-boundary
  recovery, and idempotent old/new snapshot reconciliation in Zig and Python.
- Canonical tenant payload snapshots and a descriptor-relative durable payload
  adapter with fixed exact-target reclaim records, copy-on-write promotion,
  stable locking across inode replacement, independent Python verification, and
  seven native plus Python process-death boundaries.
- Fixed continuation ownership manifest with capsule/payload binding,
  fresh-epoch ResourceBank/LeaseTree reacquisition, exact restored publication
  sequence, charge-before-materialization ordering, explicit abort, and
  mutation-complete Zig/Python verification.
- Canonical paged-KV page images with durable payload membership, complete
  source ownership-chain verification, atomic fresh-cache reconstruction, new
  target generations, and stale source-ref rejection.
- Fixed 304-byte continuation runtime state joining the exact publication
  sequence, logical KV digest, RNG, sampler count, output prefix, checkpoint
  challenge, and previous commit, with mutation-complete Zig/Python verification.
- A model-free two-process continuation proof that synchronizes a checkpoint,
  releases source ownership, exits, reacquires a fresh Bank and paged cache,
  resumes the next token exactly once, chains its receipt, and returns target
  ownership to zero.
- Cross-process paged-KV cache-instance collision detection and forced target
  remapping so process-local identity counters cannot revive source PageRefs.
- Canonical whole-checkpoint archives plus a fixed root selector, immutable
  content-addressed generations, exact previous/successor recovery, and seven
  native process-death boundaries followed by seven fresh live resumes.
- An independent checkpoint archive/selector verifier with shared golden roots,
  mutation-complete wire coverage, re-rooted contradiction rejection, and a
  pure foreign-state recovery model.
- A fixed 272-byte shared image/audio/video object descriptor with independent
  Zig/Python golden roots, mutation-complete verification, and re-rooted
  semantic contradiction rejection.
- Checked rational media positions, explicit transform-event roots, and an
  exact-once logical chunk publication chain that binds output and
  resource-claim evidence without granting device, filesystem, or network
  authority.
- A model-free shared media demo plus a gated roadmap from the new contract
  prototype through bounded image, streaming audio, and video execution.
- A fixed 416-byte sealed media decode plan binding object, decoder,
  representation, execution/numerical/rejection policy, exact output/scratch
  bounds, transform, resource policy, challenge, and required capabilities.
- Tiny bounded RGB8, PCM s16le, and intra-frame gray8 video fixtures with a
  canonical 320-byte header, allocation-free caller-owned identity decode,
  complete per-pixel/frame source mappings, keyframe bounds, and shared
  Zig/Python fixture, plan, and receipt roots.
- Mutation-complete verification for all three fixture and decode-plan wires
  plus foreign-plan, output-capacity, overlap, truncation, and re-rooted
  semantic contradiction rejection.
- A fixed 512-byte sealed media transform plan binding source decode evidence,
  implementation, exact geometry/time/rate parameters, resource policy,
  challenge, capabilities, output bounds, and its domain-separated root.
- Allocation-free caller-owned image crop/nearest/tile, audio weighted
  stereo-to-mono mix with exact integer decimation, and video keyframe-selection
  executors with one exact mapping per visible output unit.
- Shared Zig/Python transform plan, mapping-chain, output, and receipt evidence,
  including every-byte plan mutation, re-rooted contradiction, stale binding,
  capacity, substitution, and native overlap rejection.
- A full Glacier AI Runtime roadmap defining shared runtime planes, universal
  family adapters, model-family coverage, promotion gates, delivery sequence,
  use cases, and contributor-sized lanes.

### Status

- The project remains experimental; public API and file formats may change.
