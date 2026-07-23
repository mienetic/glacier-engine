# Atomic Media Stream Checkpoint Sets

Glacier publishes image, audio, and video continuation state as one immutable
archive generation selected by one fixed root. A reader therefore observes the
complete previous generation or the complete successor generation, never a
mixture of checkpoint and retained-output files.

This layer composes the existing fixed stream checkpoint, fresh-Bank resume,
immutable checkpoint archive, and atomic selector protocols. It does not add a
second filesystem transaction mechanism.

## Archive shape

Each media archive contains exactly four canonical objects:

1. the 2,048-byte image stream checkpoint;
2. the 2,048-byte audio stream checkpoint;
3. the 2,048-byte video stream checkpoint; and
4. one retained-output bundle shared by all three checkpoints.

The retained-output bundle avoids consuming one archive directory entry per
chunk. Its fixed directory has room for four outputs per modality while its
payload area remains variable length:

```text
bundle header (192 bytes)
  generation, request epoch, challenge
  image/audio/video checkpoint roots

fixed output directory (12 × 96 bytes)
  media kind, chunk index, payload offset/length
  exact output SHA-256
  exact stream-chunk receipt SHA-256

canonical retained output bytes
SHA-256 footer
```

Entries are ordered image, audio, then video, with contiguous chunk indices
inside each modality. Unused directory entries must be zero. The bundle root,
each checkpoint root, the generic archive object roots, and the archive root
all use domain-separated hashes.

## Generation lineage

All three checkpoints in one archive must agree on:

- checkpoint generation;
- request epoch;
- next publication sequence; and
- challenge root.

Generation one has no parent archive or prior media-checkpoint roots.
Generation two binds the generation-one archive root and each modality binds
its own prior checkpoint root.

The successor validator additionally requires one new visible chunk per
modality, an unchanged media object, stream identity, time base, tenant and
chunk limit, a strictly advanced timeline/commit state, and byte-identical
retained-output prefixes. A generation cannot rewrite a previously retained
chunk or output.

## Crash boundary campaign

The native conformance demo creates two generations for image, audio, and
video, releases all three source Banks, and repeats publication in a fresh
directory for every durability boundary:

1. archive write;
2. archive file sync;
3. archive directory sync;
4. selector-candidate write;
5. selector-candidate sync;
6. selector rename; and
7. selector directory sync.

The publisher receives `SIGKILL` at each boundary. Before repair, a distinct
target process opens the selected root and resumes all three streams:

- five boundaries expose the complete previous generation;
- two boundaries expose the complete successor generation; and
- no boundary exposes a mixed set.

Recovery then installs or confirms the exact successor and a second fresh
target resumes it. Repeating recovery is idempotent. Across the campaign this
exercises 14 fresh target processes, 42 resumed modality-chunks, and zero
duplicate publications. Every target charges retained output ownership before
materialization and finishes with zero Bank usage, live allocations, and
active lease trees.

## Run the proofs

```sh
zig test src/core/media_stream_checkpoint_set.zig -OReleaseSafe
python3 -m pytest -q bench/tests/test_media_stream_checkpoint_set.py
zig build media-stream-checkpoint-set-demo -Doptimize=ReleaseSafe -Dmetal=false
```

The Zig and Python codecs share a golden retained-bundle root and independently
reject every one-byte bundle mutation. Rehashed foreign checkpoint-root and
retained-output substitutions reject at the media-set boundary.

## Deliberate limits

The campaign uses real process death and real file/directory sync calls, but it
does not emulate storage-device power loss. Generation two is produced by the
still-live original source after its second chunk; creating another checkpoint
after restoring an older generation remains a separate ownership-rebinding
milestone.

Multi-writer leader election, archive garbage collection policy, external
codecs, capture/playback, family-specific processor/cache state, media-model
execution, and generated-media publication also remain gated.
