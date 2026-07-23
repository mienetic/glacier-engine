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

### Status

- The project remains experimental; public API and file formats may change.
