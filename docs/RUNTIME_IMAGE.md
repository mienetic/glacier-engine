# Glacier Native Runtime Image (`.glrt`)

Status: **GLRT v2 is the only write ABI**. GLRT v1 is frozen, read-only
compatibility. The implementation lives in
[`src/model/runtime_image.zig`](../src/model/runtime_image.zig); the loader adds
executable-model schema checks.

`.glrt` is a derived, architecture-policy and execution-layout-bound image. It is
not a portable exchange format and does not replace the draft `.glacier` source.

## Format summary

| Property | v1 compatibility | v2 current |
| --- | ---: | ---: |
| Header | 512 bytes | 512 bytes |
| Record | 128 bytes | 160 bytes |
| Stream alignment | 64 bytes | 64 bytes |
| Roles | Implicit tensor | Explicit |
| PairNibble | Rejected | Defined |
| Payload CRC-32 | Required by default | Required by default |
| Descriptor + payload SHA-256 | None | Required |
| Writer | No | Yes |
| Reader | Optional | Yes |

All integers and floating-point bit patterns are little-endian. Typed views
reject a big-endian host. Fields are encoded explicitly; Zig struct layout is
never persisted.

## File envelope

```text
header:       512 bytes
index:        record_count × record_size
alignment:    zero-filled to data_offset
streams:      immutable, independently 64-byte aligned
tail:         zero-filled to file_size alignment
```

Canonical v2 equations:

```text
index_offset = 512
index_length = record_count * 160
data_offset  = align_up(index_offset + index_length, 64)
file_size    = align_up(end_of_last_stream, 64)
```

Within each record, non-empty streams are written in this order:

```text
packed_weights, scales_f32, scales_f16, scales_f16_rows4, raw
```

## Header layout

| Bytes | Type | Field | Required meaning |
| --- | --- | --- | --- |
| `0..4` | bytes | `magic` | ASCII `GLRT` |
| `4..6` | `u16` | `version` | `1` or `2` |
| `6..8` | `u16` | `header_size` | `512` |
| `8..10` | `u16` | `record_size` | `128` for v1, `160` for v2 |
| `10..12` | `u16` | `data_alignment` | `64` |
| `12..16` | `u32` | `flags` | Zero |
| `16..24` | `u64` | `record_count` | Nonzero |
| `24..32` | `u64` | `index_offset` | `512` |
| `32..40` | `u64` | `data_offset` | Aligned and after index |
| `40..48` | `u64` | `file_size` | Exact mapped-file length |
| `48..80` | bytes | `source_fingerprint` | Opaque provenance identity |
| `80..112` | bytes | `abi_fingerprint` | Exact format/architecture policy |
| `112..140` | model fields | config | Dimension, hidden, layers, vocab, heads, head dim, KV heads |
| `140..141` | `u8` | `tie_embeddings` | `0` or `1` |
| `141..144` | bytes | reserved | Zero |
| `144..152` | F32 bits | numerics | Positive finite RMS epsilon and RoPE theta |
| `152..156` | `u32` | `index_crc32` | CRC of exact index bytes |
| `156..160` | `u32` | `header_crc32` | CRC of header with this field zero |
| `160..512` | bytes | reserved | Zero |

Executable admission additionally requires `heads * head_dim == dim`,
`kv_heads <= heads`, and `heads % kv_heads == 0`.

## Record layout

The first 120 bytes have common meaning:

| Bytes | Field | Contract |
| --- | --- | --- |
| `0..4` | `layer_idx` | Layer or `0xffffffff` for global role |
| `4..8` | `tensor_kind` | Defined `TensorKind` |
| `8..10` | `encoding` | `0=raw_f32, 1=int4, 2=pair_nibble` |
| `10..12` | `packed_layout` | `0=row_major, 1=rows4_k16, 0xffff=none` |
| `12..16` | `group_size` | Zero only for raw F32 |
| `16..24` | `out_f`, `in_f` | Nonzero logical matrix geometry |
| `24..28` | flags | Zero |
| `28..32` | `payload_crc32` | CRC over canonical stream concatenation |
| `32..40` | `num_elements` | Exactly `out_f * in_f` |
| `40..120` | five offset/length pairs | Packed weights, three scale streams, raw |

The tail is versioned:

| Bytes | v1 | v2 |
| --- | --- | --- |
| `120..122` | Zero | `role`: tensor or MLP gate/up pair |
| `122..124` | Zero | PairNibble layout or none |
| `124..128` | Zero | Zero |
| `128..160` | Absent | SHA-256 descriptor + payload digest |

Ordinary tensor identity is `(layer_idx, role=tensor, tensor_kind)`. An execution
artifact is identified by `(layer_idx, role)`, so adding an artifact does not
require inventing a portable tensor kind.

## Descriptor and range rules

Readers use checked arithmetic for every product, sum, alignment, offset, and
length. Non-empty streams must begin at or after `data_offset`, be 64-byte
aligned, stay inside `file_size`, and not overlap another stream. Empty streams
use canonical zero offset/length values required by their encoding.

Encoding-specific validation checks exact packed and scale extents, group
geometry, layout compatibility, and allowed stream combinations before exposing
typed views.

## Integrity

### Header and index

`header_crc32` covers the complete 512-byte header with bytes `156..160` zeroed.
`index_crc32` covers the exact contiguous record bytes, including v2 record
digests.

### Payload CRC

For each record:

```text
CRC32(packed_weights || scales_f32 || scales_f16 || scales_f16_rows4 || raw)
```

Offsets, descriptors, and alignment padding are not in this CRC.

### V2 record digest

For each v2 record:

```text
SHA256(
  record_bytes[0..128] ||
  packed_weights || scales_f32 || scales_f16 || scales_f16_rows4 || raw
)
```

The descriptor binds interpretation and placement; padding is excluded. A v2
record carries a nonzero digest even when trusted-cache APIs skip recomputation.

Default open verifies header/index CRC, all structure and geometry, payload CRC,
and v2 record digests. Disabling content recomputation does not relax structural
validation.

## Execution ABI fingerprints

The loader compares the header fingerprint with the exact expected version and
architecture policy. Current SHA-256 values are:

| Policy | Fingerprint |
| --- | --- |
| v1 AArch64 | `dc5fe778a28150235c6f11c53bbf876e130dde0804c3b7a492f4de7e059bc7ad` |
| v1 portable | `0c1f185ceff5e9d366a920c8b0046f1543290f85965fbd7cb13f21fe2eec42b6` |
| v2 AArch64 | `d0d7df06350af6b2d48e282f65ff873a3cf95bd6397b1d2d26cc6e679304e06f` |
| v2 portable | `8f291472be36fab2d8e32bfbb87671ebbb18a982036a2d17dc06cbe2907ec890` |

“Portable” names the current preparation policy; request-time kernel admission
still rejects unsupported roles or layouts.

## Source provenance

The low-level codec treats `source_fingerprint` as caller-supplied bytes. The
`glacier prepare` command derives it from the exact `.glacier` file SHA-256 and
normalized model configuration under a versioned domain. It checks the open
source identity before and after materialization and rejects source/output alias.

This is a consistency identity, not a signature or publisher authentication.

## Atomic publication

The v2 writer plans and validates all identities, stream extents, and file offsets
before requesting generated payload bytes. It writes into a same-directory
temporary, validates and hashes records one at a time, flushes final data,
position-writes the index and header, optionally syncs the temporary, then
renames it into place.

Failure leaves the prior destination unchanged. The current writer does not
explicitly sync the parent directory, so it provides atomic namespace
replacement rather than a complete power-loss durability guarantee.

Generated workspace statistics count record materialization buffers only. They
are not process RSS or device-residency evidence.

## Prepared-model schema

The high-level loader validates an exact model collection after individual
records pass:

- required global embedding, final norm, and conditional LM head;
- required per-layer attention and norm roles;
- MLP down plus either complete separate gate/up records or one PairNibble role;
- shapes, layouts, scale extents, and config consistency;
- no unknown, duplicate, partial, mixed, or extra role placements.

MLP representation is homogeneous across the model. Load policies admit either
homogeneous form or require one explicitly. No layer silently falls back to the
other form.

## V1 compatibility

V1 remains frozen:

- header 512, record 128, version 1;
- bytes `120..128` are zero;
- every record is an implicit tensor role;
- PairNibble is invalid;
- a separate v1 ABI fingerprint is required;
- payload CRC is the content-integrity check;
- no writer emits v1.

Do not place v2 meaning in v1 reserved bytes.

## Security boundary

Default checks reject corruption, overflow, overlap, invalid enums, stale
expected fingerprints, incompatible ABI, and unexpected model schema. They do
not authenticate an untrusted distributor: CRC is non-cryptographic and unkeyed
SHA-256 can be recomputed by someone replacing the file.

Authenticated manifests, signing, trusted distribution metadata, and rollback
protection must be added as a separate versioned layer.

## Evolution rules

1. Never reinterpret an existing version, enum, role, layout, reserved byte,
   stream order, digest domain, or fingerprint.
2. Change on-disk meaning only under a new format version and ABI fingerprint.
3. Keep execution-artifact roles separate from portable tensor kinds.
4. Preserve fail-closed behavior for unknown values.
5. Version provenance when its inputs or meaning change.
6. Generated providers may fill only a prevalidated identity and exact extent.
