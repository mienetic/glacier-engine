# Glacier Model Format v0.1

Status: **draft and expected to change before 1.0**. Do not treat `.glacier`
files as a stable distribution format.

The portable Glacier model format divides tensors into independently checked,
range-readable chunks. It is the source for conversion and preparation; the
derived `.glrt` format is the execution-layout-bound runtime image.

## Design goals

- 256 KiB maximum V1 conversion-window budget, with smaller power-of-two
  profiles;
- explicit tensor role, layer, precision, element range, offset, and length;
- independent CRC-32 per payload;
- range I/O without parsing preceding payloads;
- versioned room for future representation identity and alignment.

## File layout

```text
header (256 bytes)
metadata (JSON)
page index (64 bytes × page count)
page payloads (concatenated)
```

All integer fields are little-endian. Encoders serialize fields explicitly;
in-memory Zig layout is never the file ABI.

## Header

| Offset | Size | Field | Contract |
| ---: | ---: | --- | --- |
| 0 | 4 | `magic` | ASCII `GLAC` |
| 4 | 2 | `version` | `1` |
| 6 | 2 | `header_size` | `256` |
| 8 | 8 | `meta_offset` | Metadata byte offset |
| 16 | 8 | `meta_len` | Metadata byte length |
| 24 | 8 | `num_pages` | Index entry count |
| 32 | 8 | `page_index_off` | Index byte offset |
| 40 | 8 | `page_data_off` | First payload offset |
| 48 | 4 | `page_size_log2` | `18`, the 256 KiB maximum V1 conversion-window budget |
| 52 | 4 | reserved | Zero |
| 56 | 200 | padding | Zero |

## Page entry

Each index entry occupies 64 bytes.

| Offset | Size | Field | Contract |
| ---: | ---: | --- | --- |
| 0 | 8 | `page_id` | Monotonic ID and current table index |
| 8 | 4 | `layer_idx` | Transformer layer |
| 12 | 4 | `tensor_kind` | Defined role value |
| 16 | 8 | `row_start` | First flat logical element; legacy field name |
| 24 | 8 | `row_end` | Exclusive flat logical element |
| 32 | 1 | `precision` | `0=FP16, 1=BF16, 2=INT8, 3=INT4, 4=INT2, 5=TRI1p58, 6=FP32` |
| 33 | 1 | `quant_group` | Quantization group size; zero means an unquantized raw page |
| 34 | 2 | reserved | Zero |
| 36 | 8 | `data_offset` | Absolute payload offset |
| 44 | 8 | `data_len` | Stored payload length |
| 52 | 4 | `crc32` | IEEE CRC-32 of payload |
| 56 | 8 | padding | Two reserved zero `u32` values |

Defined tensor kinds:

```text
0 embedding       1 attn_q          2 attn_k          3 attn_v
4 attn_o          5 mlp_up          6 mlp_down        7 mlp_gate
8 input_norm      9 lm_head        10 final_norm     11 post_attn_norm
12 attn_q_bias   13 attn_k_bias    14 attn_v_bias    15 attn_o_bias
255 other
```

Unknown numeric values reject. `other` is an explicit value, not a fallback for
unknown input.

## Metadata

The metadata blob is JSON and may contain normalized model configuration,
converter version, source identity, and precision inventory. Runtime admission
does not trust descriptive metadata in place of checked header, entry, and model
shape validation.

The sealed converter emits `glacier.model-conversion/v1` metadata with the
architecture label, selected power-of-two conversion-window budget, page count,
source byte length and SHA-256, conversion-profile SHA-256, conversion-plan
SHA-256, and producer identity. The selected budget may be smaller than the
fixed V1 maximum recorded in the header.

## Chunk geometry

The selected window budget applies to source bytes for raw pages and to decoded
F32 workspace bytes for quantized pages. At the default 256 KiB budget, the
current INT4 converter decodes 65,536 logical elements (`256 KiB / 4`) before
quantizing them, so raw and INT4 chunks do not necessarily cover the same source
byte count. Smaller power-of-two budgets are valid and are bound by the
conversion profile.

INT4 payloads contain a quantization header, FP32 scales, and packed nibbles.
INT8 uses the same header and scale layout with one stored byte per element.
Every entry can be read and checked independently. Raw pages require
`quant_group = 0` and exact element-count-to-byte-length agreement. INT4/INT8
pages require a nonzero group, an exact payload length, and a quantization
header whose element count, group, precision, and reserved bytes agree with the
index entry. Strict V1 admission rejects INT2 and ternary payloads until their
payload schemas receive a new checked implementation.

## Reader validation

Readers must reject:

- wrong magic, version, or header size;
- metadata longer than 16 MiB or more than 1,048,576 page entries;
- arithmetic overflow or out-of-file ranges;
- metadata/index/payload overlap that violates the layout;
- metadata that is not one complete JSON object;
- nonzero reserved bytes;
- invalid enum or element range;
- raw or quantized payload geometry that disagrees with the entry;
- a raw-source or decoded-F32 conversion window larger than the fixed V1
  maximum;
- an unsupported stored precision or mismatched quantization sub-header;
- duplicate or non-monotonic page identity where required;
- CRC mismatch;
- tensor shapes inconsistent with an externally supplied model schema at the
  higher-level model-admission boundary.

The metadata-length and page-count caps are checked before allocating their
corresponding reader storage.

The strict reader can stream every page CRC and the full physical container
SHA-256 with caller-provided bounded storage. The sealed POSIX publisher
synchronizes and reopens its unpublished candidate, performs both checks, then
atomically replaces the visible target and commits the parent directory. See
[Sealed Portable-Model Publication](SEALED_MODEL_CONVERSION.md).

## Known limitations

- Element ranges are flat, not matrix rows.
- The 256 KiB value is a maximum conversion-window budget, not stored-payload
  size.
- Payload offsets are not guaranteed to be OS-page or direct-I/O aligned.
- One entry names one representation; equivalent variants have no shared logical
  tile identity.
- V1 conversion metadata does not encode a complete whole-model tensor schema;
  callers need an independently identified schema for cross-tensor shape
  validation.
- Conversion retains the admitted Safetensors header/JSON and one
  descriptor/plan record per output page. The reported transformation workspace
  includes all streaming source-page and payload buffering after header
  admission, but excludes those planning allocations and canonical output
  metadata; excluded allocations are not reported separately.
- CRC-32 detects accidental corruption but is not authentication.

A successor needs logical-tile identity, representation descriptors, physical
alignment, cryptographic content roots, and a migration plan. It must receive a
new version rather than reinterpret v1 bytes.
