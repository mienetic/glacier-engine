# Prepared Text Checkpoint

The prepared-text checkpoint is an experimental R1e codec for one exact,
non-terminal `SessionV3` boundary. It captures the committed output prefix,
RNG state, sampling count, and contiguous KV prefix as a canonical
little-endian byte image. A verified image can be materialized into a fresh,
detached allocation in the same process.

Detached is an important boundary. The materialized payload has no Scheduler,
ResourceBank, receipt, service permit, sink, or publication authority. It is
not a runnable restored Session, a durable checkpoint, or fresh-process resume.

## What the slice proves

- `SessionV3.captureCheckpointV1` accepts only a live, idle, non-terminal
  boundary after at least one published output.
- The image binds independently retained local-plan, bound-plan, artifact,
  execution-plan, residency, boundary, transcript, state-commitment, and
  challenge roots.
- Output tokens use canonical little-endian `u32`.
- KV payload order is layer ascending, committed K prefix, then committed V
  prefix. Every `f32` is preserved as its exact IEEE bit pattern encoded as a
  little-endian `u32`.
- The verifier reconstructs the output chain, RNG root, full logical KV root,
  incremental publication KV chain, and complete publication state commitment.
- `materializeDetachedV1` zeros every output and KV allocation before copying
  the committed prefixes. Uncommitted capacity is therefore deterministic
  zero, not allocator residue.
- The retained synthetic fixture has independent Zig and Python encoders,
  decoders, component roots, whole-wire golden, every-byte mutation rejection,
  coherent contradiction rejection, and raw `+0`, `-0`, infinity, and NaN
  payload coverage.

## State constraints

Let `N` be the number of published output tokens:

```text
0 < N < max_new_tokens
publication_next_sequence = N
sampling_calls = N
kv_positions = prompt_tokens + N - 1
max_kv_positions = prompt_tokens + max_new_tokens - 1
terminal = false
```

Sequence zero is excluded because the next token would depend on prefill
logits, which are not serialized. For `N > 0`, the prepared execution path
recomputes the next logits from the last output token and committed KV state.
That numerical property makes the payload sufficient for a future continuation
protocol, but the current codec does not supply that protocol's authority.

Capture also requires:

- the result receipt is still live;
- terminal evidence is not sealed;
- the nested admission receipt still equals the retained receipt;
- the ResourceBank validates the exact Session address, request epoch, and
  current publication sequence;
- no KV row transaction or publication attempt is active;
- the V2 boundary remains contextually valid for the retained local and bound
  plans; and
- the dedicated result-publication state is still its initial zero-result
  state.

## Canonical wire

All integers are little-endian. The fixed header is 544 bytes.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | `GLTCKP01` magic |
| 8 | 8 | checkpoint ABI |
| 16 | 8 | total encoded bytes |
| 24 | 4 | allowed flags, currently zero |
| 28 | 4 | reserved zero |
| 32 | 256 | eight 32-byte identity/boundary/state roots |
| 288 | 96 | twelve `u64` state and geometry fields |
| 384 | 32 | four raw RNG `u64` words |
| 416 | 128 | output, RNG, logical-KV, and challenge roots |
| 544 | `4 × N` | canonical output-token payload |
| variable | `4 × KV elements` | canonical committed KV payload |
| final 32 | 32 | domain-separated whole-image SHA-256 |

The total size is:

```text
576 + 4 × output_count + 4 ×
    (num_layers × 2 × kv_positions × kv_dim)
```

The whole-image root detects accidental or adversarial mutation when the
expected roots and challenge are retained independently. SHA-256 alone is not
authentication, authorization, encryption, or confidentiality. Output and KV
bytes may reveal information about the prompt and must be protected according
to the embedding application's data policy.

Every `f32` bit pattern is valid and distinct. The codec does not normalize
negative zero, infinities, subnormals, or NaN payloads because the live
contiguous commitment also hashes their raw bits.

## Zig flow

```zig
const checkpoint_bytes = try session.captureCheckpointV1(
    allocator,
    checkpoint_challenge,
);
defer allocator.free(checkpoint_bytes);

const decoded = try glacier.prepared_text_checkpoint.decodeCheckpointV1(
    checkpoint_bytes,
    expected_bindings,
);
var detached =
    try glacier.prepared_text_checkpoint.materializeDetachedV1(
        allocator,
        decoded,
    );
defer detached.deinit();
```

The caller must construct `ExpectedBindingsV1` from roots and scalar context
retained outside the checkpoint: request/sequence, prompt/output bounds,
vocabulary, KV geometry, output count, and sampling count are compared
directly as well as through their nested commitments. Deriving expectations
from the untrusted image would make coherent substitution self-authorizing.

Do not move or copy the live Session while capturing. The returned byte slice
belongs to the supplied allocator. `DecodedV1` borrows the encoded slice;
retain the bytes until decoding and detached materialization are complete.
The checkpoint bytes and detached output/KV allocations are caller-owned and
are not charged to the live Session's `ResourceBank`. Applications must apply
their own memory admission until a future restore path reserves and subdivides
that ownership before materialization.

## What is deliberately not implemented

- replacing or rewinding a live Session;
- running the detached payload;
- moving publication authority to a new Session address;
- exactly-once continuation from a nonzero sequence;
- durable filesystem publication or crash recovery;
- source/target exclusivity or fresh-process handoff;
- cross-backend numerical equivalence; or
- confidentiality and authenticated storage.

The current publication Session and ResourceBank bind authority to the exact
in-process Session address. Their initializers also begin at sequence zero.
Bypassing those fences would make duplicate or stale publication possible.

## Roadmap from codec to resume

1. Add a verified retained-authority rebind at the exact current boundary,
   without changing Scheduler, Bank, receipt, sequence, or coordinator address.
2. Define a successor plan and transcript segment ABI with a nonzero sequence
   base, source-boundary lineage, nonempty cache payload root, and explicit
   ownership handoff.
3. Add Scheduler restored-admission semantics, a ResourceBank/permit
   generation fence, and LeaseTree-aware publication/receipt remapping
   compatible with that successor segment.
4. Wrap the state image and authority records in the existing immutable
   checkpoint archive and atomic selector.
5. Prove source exit, target exclusivity, fresh-process continuation, no
   duplicate token, and final terminal-result equivalence.

Each step is a separate contributor-sized correctness gate. The codec remains
useful before resume as a portable inspector input, deterministic state
snapshot, corruption detector, and cross-language conformance target.

## Acceptance commands

```bash
zig build test -Dmetal=false -j2
python3 -m unittest bench.tests.test_prepared_text_checkpoint
```

The repository wrapper `tools/zig-with-ephemeral-cache.sh` may be used for Zig
commands when a disposable build cache is preferred.
