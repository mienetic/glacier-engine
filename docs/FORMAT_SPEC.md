# Glacier Model Format v0.1

Status: **draft and expected to change before 1.0**. Do not treat `.glacier`
files as a stable distribution format.

The portable Glacier model format divides tensors into independently checked,
range-readable chunks. It is the source for conversion and preparation; the
derived `.glrt` format is the execution-layout-bound runtime image.

## Design goals

- 256 KiB source-element page quantum;
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
| 48 | 4 | `page_size_log2` | `18`, the 256 KiB converter quantum |
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
| 33 | 1 | `quant_group` | Group size; zero means per-channel |
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

## Chunk geometry

Raw tensors target 256 KiB of source bytes per chunk. The current INT4 converter
decodes a window of 65,536 F32 logical elements (`256 KiB / 4`) before quantizing
it, so raw and INT4 chunks do not necessarily cover the same source byte count.

INT4 payloads contain a quantization header, FP32 scales, and packed nibbles.
Every entry can be read and checked independently.

## Reader validation

Readers must reject:

- wrong magic, version, or header size;
- arithmetic overflow or out-of-file ranges;
- metadata/index/payload overlap that violates the layout;
- nonzero reserved bytes;
- invalid enum or element range;
- duplicate or non-monotonic page identity where required;
- CRC mismatch;
- tensor shapes inconsistent with the admitted model schema.

## Known limitations

- Element ranges are flat, not matrix rows.
- The 256 KiB value is a conversion quantum, not stored-payload size.
- Payload offsets are not guaranteed to be OS-page or direct-I/O aligned.
- One entry names one representation; equivalent variants have no shared logical
  tile identity.
- Generation currently materializes compact tensor payloads eagerly.
- CRC-32 detects accidental corruption but is not authentication.

A successor needs logical-tile identity, representation descriptors, physical
alignment, cryptographic content roots, and a migration plan. It must receive a
new version rather than reinterpret v1 bytes.
