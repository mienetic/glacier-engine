# Durable runtime-image publication

Glacier prepares native `.glrt` runtime images through a recoverable POSIX
publication adapter. The codec still owns the bytes and validation rules; the
adapter owns the filesystem ordering needed to replace one target without
exposing a partial image.

This is host-filesystem and process-death recovery evidence. It is not a claim
about physical power loss, controller caches, remote filesystems, or storage
hardware.

## Public surface

`runtime_image_durable.PublisherV1` is the descriptor-relative API. It acquires
and preflights an owned sync-capable handle for the caller's already-open
parent directory. The caller may then close its original `std.fs.Dir`; every
mutation and directory commit continues through the acquired authority.

The path wrappers are:

- `writeDurableV1` for eager records;
- `writeDurableWithProviderV1` for one-record-at-a-time materialization.

Both require `WriteOptions.sync = true` and return
`PublicationReceiptV1`. The receipt binds the exact image identity, canonical
publication-plan digest, writer workspace statistics, disposition, stale
candidate cleanup, and directory-authority observation.

The older `runtime_image.writeAtomic*` functions remain available for explicit
file-atomic or test use. Their `sync` option synchronizes the temporary file
before rename, but those functions do not acquire or commit the parent
directory and make no durable-publication claim.

## Publication protocol

One fixed lock and one fixed candidate are reserved per directory. This
directory-wide serialization prevents case- or Unicode-normalized aliases from
bypassing the lock and bounds crash debris to one candidate for the complete
directory. The tradeoff is that two independent runtime-image preparations in
the same directory do not run concurrently.

| Order | Boundary |
| --- | --- |
| 1 | Validate the target name, configuration, record identities, and mandatory sync policy before mutation. |
| 2 | Acquire the persistent directory-scoped lock with no-follow, private-mode, regular-file, single-link, and descriptor/path identity checks. |
| 3 | Remove one safe stale candidate under the lock and commit that cleanup. Unsafe or foreign candidate entries fail closed. |
| 4 | Snapshot and fully validate any existing target before creating the new candidate. Corrupt, writable-by-others, linked, or non-regular targets fail closed. |
| 5 | Exclusively create one private candidate, encode it through the shared GLRT codec, flush, and synchronize the file. |
| 6 | Reopen the candidate without following links, verify the exact inode and namespace entry, parse every GLRT integrity domain, and match the planned record descriptors. |
| 7 | Recheck the lock and target snapshot. If the target already has the exact candidate identity, remove the candidate and commit the directory. |
| 8 | Otherwise atomically replace the target, verify the still-open candidate descriptor at its new name, commit the directory, and revalidate the exact identity. |

`PublisherV1` becomes poisoned after an uncertain namespace mutation or failed
commit. A poisoned publisher cannot be reused; close it and acquire a fresh
publisher for recovery.

## Recovery outcomes

- Death before target replacement leaves the predecessor authoritative. A
  fresh publisher removes any safe candidate, commits the cleanup, and rebuilds
  from source inputs.
- Death after replacement can expose only the fully encoded and synchronized
  successor. A fresh publisher rebuilds a candidate, recognizes the exact
  target identity, removes the redundant candidate, and commits the directory.
- A corrupt existing target is never silently overwritten. The caller must
  resolve or remove it under an explicit recovery policy.
- An unsafe reserved entry or an identity change observed at a checked protocol
  boundary fails closed.

The adapter assumes the containing directory is controlled by the application
and that every legitimate runtime-image writer honors the same
directory-scoped lock. A writer that mutates the namespace without that lock is
outside the contract and can race the final replacement. The adapter is not a
security boundary against an attacker with unrestricted write authority over
the directory.

Provider-based publication also requires deterministic materialization whose
bytes are fully bound by the caller's `source_fingerprint`. The publication
plan commits record descriptors and lengths, not provider payload bytes.
The returned image identity binds the exact bytes that were actually
published; recovery cannot promise the same successor if a provider changes
bytes for the same source fingerprint.

## Verification

Focused Zig tests cover pinned-directory ownership, idempotent publication,
input preflight, provider interruption, every observable publication phase,
stale-candidate recovery, symlink and hard-link substitution, corrupt targets,
and exact predecessor/successor convergence.

The `runtime-image-durable-recovery-test` build step runs a separate worker and
controller. For each retained crash point, the controller waits for a canonical
ready frame, sends real `SIGKILL`, checks the signal status, independently
parses the GLRT container, starts a fresh recovery process, and requires an
exact successor with no remaining candidate. The normal `test` step runs this
campaign on native macOS and Linux hosts; `test-compile` and
`profile-durable-compile` compile the worker for retained POSIX targets.

## Platform boundary

The implementation currently requires the declared POSIX durable-file
capability and is intended for macOS, Linux, and FreeBSD compilation. Native
recovery is retained in CI on hosted Linux and exercised on the macOS
development host. Windows returns `UnsupportedPlatform` before mutation until a
Win32 durable-publication adapter and native recovery campaign exist.
