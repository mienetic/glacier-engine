# Sealed Portable-Model Publication

Status: **integrated experimental POSIX slice**.

Through the sealed publisher, Glacier converts a Safetensors source into a
portable `.glacier` container without writing through the visible target. The
converter produces an unpublished candidate with bounded per-page workspace;
the publisher owns locking, synchronization, validation, replacement, and
recovery.

This split is useful for local model preparation, build farms, edge-device
staging, and services that derive reusable runtime inputs from an authoritative
model source. A failed sealed conversion or terminated publisher process cannot
leave a partially written file at the requested target name.

## Publication protocol

One acquired parent-directory authority owns the complete namespace operation:

1. open and pin a regular, single-link source; record its stat identity,
   byte length, and full SHA-256;
2. acquire one directory-scoped non-blocking lock;
3. reject source/target, source/lock, and source/candidate aliases before
   mutating the candidate namespace;
4. remove at most one fixed stale candidate and commit that cleanup;
5. create one private candidate with no-follow, non-blocking, and
   close-on-exec flags;
6. reserve the header, metadata, and page index, then write and backpatch one
   payload page at a time;
7. synchronize the candidate, reopen the exact inode, validate its complete
   layout, every payload CRC, and its full physical SHA-256;
8. rehash and restat the source, recheck the lock and visible target, then
   atomically replace the target;
9. synchronize the acquired parent directory and return an identity receipt.

If an exact target is already present, publication removes the rebuilt
candidate, commits the directory, and returns `already_current`. A corrupt
existing target, unsafe reserved entry, identity change, or source drift fails
closed.

## Bounded conversion

The converter first retains the admitted Safetensors header/JSON, page
descriptors, and canonical output metadata, not all transformed payloads. It
then reuses one aligned workspace for bounded positional source reads, source
hashing, raw copy, decode, quantization, write, CRC, and output verification.
Source hashing, raw copy, and output verification stream in chunks no larger
than 64 KiB; quantized transformation reuses the same workspace.

The receipt reports `conversion_workspace_bytes_peak`, which includes all
streaming source-page and payload buffering after header admission. Header/JSON,
page-descriptor/plan, and canonical-metadata planning allocations are excluded
from that bound and are not currently reported separately.

V1 records a fixed 256 KiB maximum conversion-window budget in the container
header. Smaller power-of-two budgets remain available for constrained fixtures
and specialized preparation profiles. Raw FP32, FP16, and BF16 pages preserve
their source representation. The current quantized path supports INT4 with
explicit group geometry. Unsupported source or stored precisions reject instead
of being relabeled.

Safetensors admission rejects a JSON header larger than exactly 100,000,000
bytes before copying or parsing it. If `__metadata__` is present, it must be a
JSON object and every value must be a string.

## Identities and receipt

`PublicationReceiptV1` binds:

- the source byte length and SHA-256;
- the output-affecting conversion profile;
- the canonical page and layout plan;
- the publication target, source, effective conversion settings, and converter
  algorithm contracts;
- the exact output byte length, page count, and full-container SHA-256;
- whether stale candidate debris was removed; and
- the acquired directory-authority observation.

The conversion and publication plan roots have separate domains and ABI
versions. Progress callbacks are deliberately excluded from both identities.

The public building blocks for the sealed path are:

```zig
engine.converter.convertSafetensorsFilesV1(...)
engine.converter.convertSafetensorsFilesWithObserverV1(...)
engine.converter_durable.PublisherV1
engine.converter_durable.convertSafetensorsDurableV1(...)
```

The borrowed-file converter functions only populate a caller-owned empty
candidate; they do not synchronize or publish it on their own. The publication
guarantee applies when `PublisherV1` or `convertSafetensorsDurableV1(...)` drives
the complete protocol.

`engine.converter.convertSafetensors(...)` remains a public compatibility API.
It writes a same-directory candidate and performs file-atomic replacement only
after successful conversion, but it does not acquire the publisher lock,
synchronize the candidate or directory, or provide stale-candidate recovery.
New path-based callers that need the complete durable guarantee should use
`convertSafetensorsDurableV1(...)`.

The `glacier convert` command uses the durable path. Platforms without the
required adapter return `UnsupportedPlatform`; the CLI does not silently fall
back to direct target writes.

## Recovery evidence

`zig build model-conversion-durable-recovery-test` compiles one worker and
reuses it across all eight publication phases:

```text
stale_candidate_removed
candidate_created
candidate_page_progress
candidate_encoded
candidate_synced
candidate_validated
target_replaced
directory_committed
```

The controller sends real `SIGKILL`, independently parses the resulting
`.glacier` bytes, accepts only the exact predecessor or exact successor allowed
at that boundary, starts a fresh recovery process, and requires a second retry
to return `already_current`. The fixture has three pages so the independent
parser checks a middle payload as well as both ends.

The campaign runs natively on macOS and Linux. The worker is compile-checked
for FreeBSD. These results cover host process death and filesystem protocol
behavior; they do not emulate physical power loss, storage-controller caches,
remote filesystems, hostile concurrent namespace writers, or native Windows
recovery.

## Contributor openings

Useful independent contributions include:

- additional source dtypes with explicit numerical conversion and oracle tests;
- versioned tensor-shape metadata and stricter whole-model schema admission;
- a Win32 publisher with native termination and replacement evidence;
- native FreeBSD recovery execution;
- authenticated artifact roots and signed release provenance;
- controlled storage-error injection and physical power-loss campaigns; and
- performance and memory envelopes on declared machines without weakening the
  correctness gate.

See [Model Format](FORMAT_SPEC.md), [Platform Portability](PLATFORM_PORTABILITY.md),
and the [AI Runtime Roadmap](AI_RUNTIME_ROADMAP.md).
