# Paging and Ownership

Glacier has two different paging domains:

1. **Weight paging** — a mechanics prototype that is not yet used by generation.
2. **Paged KV** — integrated opt-in state with explicit page ownership and token
   publication.

Keeping them separate prevents a synthetic weight-pager test from being mistaken
for a production memory result.

## Weight pager today

`src/core/pager.zig` provides:

- `PageId` lookup and one resident slot per ID;
- synchronous backend load and eviction;
- payload-byte budget;
- O(n) least-recently-used victim selection;
- hit, load, eviction, and transferred-byte counters;
- strict precision rejection without evicting a valid coarse page.

Tests use a fake backend. `Scheduler.ensureLayerResident` can drive the prototype,
but production generation does not instantiate it. Loader prefetch hints during
materialization are not forward-pass paging.

### Prototype limitations

| Limitation | Consequence |
| --- | --- |
| One slot per page ID | Cannot retain several layouts, precisions, devices, or tiers |
| Payload length used as cost | May differ from decoded, repacked, or device bytes |
| Synchronous operations | No cancellation, overlap, or completion evidence |
| No pins/references | Unsafe for asynchronous kernel use |
| O(n) eviction | Does not scale to large tile sets |
| No generation integration | Establishes no model latency or RSS result |

## Production weight-pager contract

Identity must include:

```zig
const ResidentKey = struct {
    logical_tensor: u64,
    tile: u32,
    representation: RepresentationId,
    device: DeviceId,
    tier: MemoryTier,
};
```

Required states:

```text
cold → reserved → loading → resident → pinned
           └──────── error/cancel ───────┘
resident → promoting/demoting → resident
resident → evicting → cold
```

Every transition needs checked byte reservations, completion/cancellation,
integrity outcome, and deterministic trace. A failed promotion leaves the prior
valid representation usable. A pinned or transaction-referenced tile cannot be
evicted.

Integration proceeds through one CPU projection consuming page views without an
eager duplicate before adding broader backends or predictive prefetch.

## Paged KV today

Paged KV stores fixed 16-position, all-layer FP32 K/V bundles behind explicit
logical pages. The integrated components provide:

- lazy payload allocation;
- cache instance and page ownership generation;
- generation-fenced `PageRef` values;
- canonical page-map root and KV hashing;
- row preparation, commit, and abort;
- byte-identical page-aware attention tests;
- token transactions binding KV, RNG, sampler, output, and resource state;
- LeaseTree-backed exact allocation leaves and terminal-lane reclamation.

Strict DecodeLane4 policies select paged behavior. Unsupported geometry or
missing required ownership rejects; it does not fall back to contiguous KV.

## Paged-KV invariants

1. A page payload cannot become visible before its ownership leaf exists.
2. A prepared row cannot mutate the committed root.
3. Commit publishes the new root and related token state once.
4. Abort releases provisional allocation and preserves the prior root.
5. A stale or foreign `PageRef` fails before payload access.
6. Resource release cannot precede the last reference or active publication.
7. Logical charged bytes equal the declared geometry, not process RSS.

## Open work

- prefix copy-on-write and shared immutable prefixes;
- cross-worker page identity and transport;
- quantized KV with numerical gates;
- tier movement across accelerator, RAM, and storage;
- continuous refill and variable-width serving;
- durable continuation and recovery;
- physical residency and peak-memory observation;
- reconciliation with the future production weight pager.

## Promotion gate

Weight paging becomes integrated only when a real generation trace contains
loads, prefetches, pins, hits, and evictions while no complete eager duplicate
remains. Paged KV becomes validated only after multi-request correctness,
cancellation, long-context, physical-memory, and platform campaigns retain their
artifacts under [Evidence policy](EVIDENCE_POLICY.md).
