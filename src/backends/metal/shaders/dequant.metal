// Glacier Metal shaders.
//
// dequant_int4_to_f16: unpacks one group of INT4 weights into FP16.
// Matches the layout described in src/model/qio.zig:
//
//   payload = [u32 magic][u32 num_elements][u32 group_size][u8 prec][u8 reserved[3]]
//             [f32 scales[num_groups]]
//             [u8 packed[(num_elements*4 + 7)/8]]
//
// Each thread handles one element: it reads its nibble, looks up the
// scale for its group, and writes scale * (q - 7) into the output FP16
// buffer. qmax for INT4 is 7, so the symmetric midpoint is stored.
//
// This is the kernel the CPU dequant in src/core/quant.zig is the
// reference for. Numerical results MUST match to within FP16 rounding.
//
// Status: compiles, not yet wired to a Metal buffer pipeline from Zig.
// The Objective-C bridge (shim.m) creates the pipeline state and the
// Zig side (metal/backend.zig) dispatches it once buffer plumbing lands.

#include <metal_stdlib>
using namespace metal;

// Sub-header mirrors qio.zig. Kept as plain structs so the offsets line up.
struct QIOHeader {
    uint32_t magic;
    uint32_t num_elements;
    uint32_t group_size;
    uint8_t  precision;
    uint8_t  reserved[3];
};

// QIO magic constant, must match qio.zig PAYLOAD_MAGIC.
constant uint32_t QIO_MAGIC = 0x514F4954;

// Decode one INT4 element from the packed byte stream.
inline int8_t read_int4(device const uint8_t* packed, uint32_t idx) {
    uint32_t byte_idx = idx >> 1;
    uint8_t b = packed[byte_idx];
    // Even index = low nibble, odd = high nibble (matches quant.zig).
    uint8_t nibble = (idx & 1) ? (b >> 4) : (b & 0x0F);
    return int8_t(nibble) - 7;  // shift from [0,15] to [-7,8]; we use [-7,7] (qmax=7)
}

kernel void dequant_int4_to_f16(
    device const uint8_t*  payload [[buffer(0)]],
    device half*           out    [[buffer(1)]],
    constant QIOHeader*    hdr    [[buffer(2)]],
    uint                   gid    [[thread_position_in_grid]])
{
    if (hdr->magic != QIO_MAGIC) return;  // defensive; Zig side guards this
    if (gid >= hdr->num_elements) return;

    const uint32_t group_size = hdr->group_size;
    const uint32_t group_idx  = gid / group_size;

    // Scales live right after the 16-byte sub-header.
    device const float* scales =
        reinterpret_cast<device const float*>(payload + 16);
    const float scale = scales[group_idx];

    // Packed weights live after the scales.
    const uint32_t num_groups = (hdr->num_elements + group_size - 1) / group_size;
    device const uint8_t* packed =
        payload + 16 + num_groups * sizeof(float);

    const int8_t q = read_int4(packed, gid);
    const float v = float(q) * scale;
    out[gid] = half(v);
}
