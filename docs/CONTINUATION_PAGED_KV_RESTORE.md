# Continuation Paged-KV Restore v1

Status: prototype. Canonical page images, complete source-chain verification,
fresh target-generation remapping, durable payload membership, and
ResourceBank/LeaseTree ordering are implemented with model-free tests.
The next layer now composes this cache with runtime state in a two-process
model-free publication proof.

## Purpose

A historical paged-KV root cannot become live authority in a new process.
Its cache instance and page ownership generations belong to the source cache.
Reusing them would weaken stale-handle and ABA protection.

Paged-KV restore therefore performs an explicit remap:

```text
source root + ordered source PageRefs + canonical page images
                            │
                            ▼
       verify geometry, lengths, challenge, image roots
                            │
                            ▼
       verify every image is in the durable payload snapshot
                            │
                            ▼
       rebuild the complete source ownership digest chain
                            │
                            ▼
       allocate a fresh target cache and zero padded rows
                            │
                            ▼
       copy committed f32 values from little-endian images
                            │
                            ▼
       issue new target cache instance and page generations
                            │
                            ▼
       verify logical KV hash and commit charged ownership live
```

Source `PageRef` values remain evidence. The target emits new refs with its own
cache instance and generations beginning at one.

## Page image wire

Each image contains exactly one logical page and has a 208-byte header,
variable committed-row payload, and 32-byte footer.

| Field | Meaning |
| --- | --- |
| Source page-map root | ABI, cache instance, root generation, committed length/page count, ownership digest |
| Geometry | Layer count, head dimension, and maximum sequence |
| Source page ref | ABI, cache instance, logical page, ownership generation |
| Committed rows | 1–16 rows; the final page may be partial |
| Element count | Exact serialized f32 count |
| Challenge | Shared continuation checkpoint challenge |
| Payload | `(layer, K/V, row, dim)` little-endian f32 bit patterns |
| Footer | Domain-separated SHA-256 over header and payload |

Padded rows are never serialized because an active cache may not have
initialized them. A target page allocation is zero-filled first, then only
committed rows are reconstructed.

For a page with `L` layers, dimension `D`, and `R` committed rows:

```text
payload_elements = L × 2 × R × D
encoded_bytes = 208 + payload_elements × 4 + 32
```

## Complete checkpoint validation

One image proves its own bytes but cannot prove a complete page map by itself.
`restoreAndCommitV1` therefore requires all images in logical-page order and
checks:

- every image carries the same source root, geometry, and challenge;
- logical pages are contiguous from zero;
- page count equals `ceil(committed_len / 16)`;
- each source ref belongs to the source cache instance;
- recomputing the ordered source ownership chain equals the source root;
- each image is an exact tenant-bound entry in the verified payload snapshot;
- the ownership manifest has one `kv_page` allocation per image;
- each allocation claim equals one full target page allocation;
- the parent KV claim equals the fixed page-map allocation; and
- all manifest object kind, length, and roots match the supplied image wires.

A foreign or changed source ownership generation breaks the complete chain
before target allocation begins.

## Atomic target restore

`PagedKVCache.restoreCheckpointV1` accepts only a fresh cache:

- empty committed root at generation one;
- no allocated or provisional page;
- no transaction, retirement, or leased coordinator;
- next row, root, and page generations at their initial values; and
- every fixed page-table entry empty.

All source identities and byte lengths validate before allocation. If any page
allocation fails, every page allocated by that call is freed and the cache
returns to its exact fresh state.

On success:

- the target cache instance is newly allocated and differs from the source,
  including when a restarted process-local counter initially repeats it;
- target page generations are `1..page_count`;
- the target committed root generation is two;
- the next root generation is three;
- padded rows are zero;
- logical committed length is preserved; and
- source refs fail target validation.

`discardRestoredCheckpointV1` can free an exact just-restored target root if the
ownership batch cannot commit. It rejects copied, mutated, leased, or
transaction-active caches.

## Ownership ordering

The continuation ownership layer has already charged the page map and every
full page before `restoreAndCommitV1` allocates target storage. While the
LeaseTree batch is `reserved_unmaterialized`,
`beginPublicationWithLeaseTree` rejects.

Only after all page images restore and match the ownership manifest does
`commitMaterializedV1` change allocation nodes to `live`. The resulting
`ActiveReacquireV1` and target refs share canonical allocation order, providing
an exact node-to-page mapping for the next live-restart layer.

The returned cache intentionally has no standalone convenience destructor.
Callers must first retire and authorize the restored LeaseTree allocations,
free the physical pages, and only then commit the accounting release. This
keeps allocator lifetime and ownership lifetime in the same explicit order.

## Evidence

The native integration fixture restores:

- two layers;
- dimension two;
- maximum sequence 32;
- 17 committed positions across two pages; and
- one fresh ResourceBank/LeaseTree scope with two page allocations.

It proves:

- source and target logical KV SHA-256 are equal;
- source and target cache instances differ;
- target refs validate and source refs fail;
- a changed source generation leaves a probe cache exactly fresh;
- publication is blocked while ownership remains pending;
- exact images make the ownership batch live at sequence 18; and
- teardown frees pages before LeaseTree uncharge and returns Bank usage to zero.

The shared one-page codec fixture is 752 bytes. Zig and Python agree on image
root:

`e052306f36ef24b9b92f7f0ef505045ea25fddf7bdf8f4c9e81b96733437d1e4`

Both implementations reject mutation of every serialized byte and a semantic
contradiction whose outer root has been recomputed. The Python model also
rebuilds the complete source chain, derives fresh target refs/root, and rejects
a stale source generation.

Run focused verification:

```sh
zig test --dep core \
  -Mroot=src/continuation_paged_kv_restore.zig \
  -Mcore=src/core/root.zig
python3 -m unittest \
  bench.tests.test_continuation_paged_kv_restore
```

## Evidence boundary

This prototype restores actual `PagedKVCache` page allocations and logical f32
content under reacquired ownership. The
[live-restart layer](CONTINUATION_LIVE_RESTART.md) now composes its root with
RNG/sampler/output state and publishes a next token in a fresh process. It does
not yet reconstruct the full `LeasedPagedKVCache` coordinator, an active row
transaction, tokenizer state, accelerator residency, or worker pins.

It also does not yet prove:

- device power-cut durability;
- native Linux filesystem recovery;
- numerically equivalent continuation for production model kernels; or
- lower latency, memory, disk, token, or energy use.

The downstream
[checkpoint-file layer](CONTINUATION_CHECKPOINT_FILE.md) now promotes one
complete checkpoint candidate atomically and exercises fresh recovery after
termination at every archive/selector durability phase.
