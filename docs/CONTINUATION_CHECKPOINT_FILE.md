# Continuation Checkpoint File v1

Status: prototype. A complete model-free restart checkpoint is encoded into one
immutable archive and selected by one fixed root-switch record. Native workers
terminate after all seven archive/selector publication phases; fresh recovery
accepts only the exact previous or successor checkpoint before another process
resumes token publication.

## Purpose

Synchronizing several valid files does not make their collection atomic. A
restart must never compose a capsule from one generation with KV pages, runtime
state, or ownership evidence from another.

The checkpoint-file layer reduces the visibility boundary to one atomic rename:

```text
canonical objects
      │
      ▼
immutable checkpoint-<root>.set
      │ write → sync → directory sync
      ▼
fixed checkpoint-switch-<root>.candidate
      │ write → sync
      ▼
rename candidate → active selector
      │
      ▼
directory sync
```

The archive is content addressed. The active selector contains no object
payloads; it binds one exact archive root and length, lineage, request position,
and challenge. Readers acquire the stable lock, verify the selector, derive the
archive name from its root, and verify the complete archive before exposing any
object slice.

## Canonical checkpoint set

The archive uses a 128-byte header, eight fixed 72-byte directory slots,
contiguous object payloads, and a 32-byte footer:

```text
128-byte header
8 × 72-byte object directory
canonical contiguous payload bytes
32-byte domain-separated checkpoint root
```

The header binds:

- set ABI and exact encoded length;
- monotonically increasing set generation;
- request epoch and next publication sequence;
- object count and zero flags;
- parent checkpoint root; and
- checkpoint challenge.

Each used directory slot binds object kind, ordinal, ABI, exact offset, exact
length, and a domain-separated payload root. Entries are strictly ordered by
`(kind, ordinal)`; unused slots are all zero; payloads have no gaps or aliases.
The current kinds cover capsule, ownership manifest, payload snapshot, ordered
KV pages, runtime state, source-process evidence, and a reserved extension
class.

## Fixed selector

The selector is exactly 192 bytes:

| Region | Bytes | Meaning |
| --- | ---: | --- |
| Framing and position | 64 | Magic, ABI, length, generation, request epoch, next sequence, archive length, flags |
| Previous selector root | 32 | Exact selector lineage |
| Checkpoint root | 32 | Selected immutable archive |
| Challenge | 32 | Shared checkpoint challenge |
| Footer | 32 | Domain-separated selector root |

Generation one requires a zero parent and zero previous selector. Later
generations require both lineages. Publication additionally requires the new
archive's parent checkpoint root to equal the active archive and the new
selector's previous root to equal the active selector.

## Recovery contract

Under one descriptor-relative, owner-private stable lock:

1. write the immutable archive;
2. sync the archive;
3. sync its directory entry;
4. write the fixed selector candidate;
5. sync the selector candidate;
6. rename the candidate over the active selector; and
7. sync the directory.

Recovery receives the exact prepared successor. It verifies the active selector
and archive, then allows only:

- **previous:** finish archive/candidate sync and perform the root switch once;
- **successor:** verify and return `already_applied`; or
- **anything else:** reject as foreign state.

The operation is idempotent. Uncertain in-process I/O poisons the lease and
requires close, fresh lock acquisition, reread, and reclassification. While the
active selector still names the exact previous root, recovery may rewrite only
the prepared inactive successor archive/candidate from caller-supplied verified
bytes; it never repairs an active or unrelated generation.

## Evidence

The native demonstration packages seven real restart objects:

- capsule;
- ownership manifest;
- durable payload snapshot;
- two ordered paged-KV images;
- fixed runtime state; and
- source-process identity.

For each durable phase, a worker receives `SIGKILL`. A fresh process observes
the previous root in five cases and the successor root in two. Recovery reaches
the successor idempotently, and a separate process then restores ownership, KV,
RNG, sampler/output position, and publishes token `504` without duplicated
output. The campaign therefore performs seven process deaths and seven
post-recovery live resumes.

The shared two-object codec fixture is 766 bytes. Zig and the independent Python
verifier agree on checkpoint root
`28a31df6cf0972481ce2e17b3fb0b54f217c3c54025d746f05fe93b58ea697dc`
and selector root
`789052b3ce4994889bee859e3f180b576bd26ce89ab8b90b51f9c8aae55a43df`.
Both reject every serialized-byte mutation, re-rooted semantic contradictions,
and foreign recovery roots.

Run the process-death campaign:

```sh
zig build continuation-checkpoint-file-demo \
  -Doptimize=ReleaseSafe -Dmetal=false
python3 -m unittest \
  bench.tests.test_continuation_checkpoint_file
```

## Evidence boundary

The retained campaign proves natural host process death, filesystem calls, and
fresh-process recovery on the development machine. It does not emulate device
power loss or prove guarantees for every filesystem. It also does not yet:

- compare a production model's uninterrupted and resumed numerical output;
- restore tokenizer/model allocations or accelerator residency;
- retain native Linux execution evidence;
- collect unreachable immutable archives;
- support concurrent non-cooperating writers; or
- measure restart latency, throughput, RSS, disk, token, or energy changes.

The lock is advisory. Privileged mutation and same-length in-place writes by a
process that ignores the lock remain outside the capability contract.
