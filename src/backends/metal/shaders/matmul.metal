// Glacier Metal shaders — matmul (GEMM).
//
// matmul_f16: C[M,N] = A[M,K] × B^T[N,K]  (B stored row-major as [N,K])
//
// This is the standard LLM linear layer: x[batch, in] × W^T[out, in] = out[batch, out].
// A = activations [M, K], B = weights [N, K], C = output [M, N].
//
// Thread organization:
//   Each thread computes one element of C (tile of 1x1 for MVP).
//   grid: [M, N, 1], threadgroup: [16, 16, 1]
//
// This is a correct-but-naive GEMM. A production version would use
// tiling with threadgroup shared memory (32x32 tiles). For the MVP we
// prioritize correctness + proving the Metal forward path works.

#include <metal_stdlib>
using namespace metal;

struct MatmulDims {
    uint M;
    uint K;
    uint N;
};

// Simple GEMM: each thread computes C[row, col] = sum(A[row,k] * B[col,k]).
// A: [M, K] row-major, B: [N, K] row-major, C: [M, N] row-major.
kernel void matmul_f16(
    device const half*  A    [[buffer(0)]],  // [M, K]
    device const half*  B    [[buffer(1)]],  // [N, K] (weights, already transposed)
    device half*        C    [[buffer(2)]],  // [M, N]
    constant MatmulDims& dims [[buffer(3)]],
    uint2               tid  [[thread_position_in_grid]])
{
    const uint row = tid.x;
    const uint col = tid.y;
    if (row >= dims.M || col >= dims.N) return;

    float acc = 0.0f;
    for (uint k = 0; k < dims.K; k++) {
        acc += float(A[row * dims.K + k]) *
            float(B[col * dims.K + k]);
    }
    C[row * dims.N + col] = half(acc);
}

// Tiled GEMM with threadgroup shared memory for better cache utilization.
// tile_size = 16: each threadgroup computes a 16x16 block of C.
kernel void matmul_f16_tiled(
    device const half*  A    [[buffer(0)]],
    device const half*  B    [[buffer(1)]],
    device half*        C    [[buffer(2)]],
    constant MatmulDims& dims [[buffer(3)]],
    uint2               tg_pos    [[threadgroup_position_in_grid]],
    uint2               tid_in_tg [[thread_position_in_threadgroup]])
{
    constexpr uint TILE = 16;

    const uint row = tg_pos.x * TILE + tid_in_tg.x;
    const uint col = tg_pos.y * TILE + tid_in_tg.y;
    const bool active = row < dims.M && col < dims.N;
    threadgroup half sA[TILE][TILE];
    threadgroup half sB[TILE][TILE];
    float acc = 0.0f;

    // Process K in tiles of TILE.
    for (uint kt = 0; kt < dims.K; kt += TILE) {
        const uint a_col = kt + tid_in_tg.y;
        const uint b_col = kt + tid_in_tg.x;

        if (row < dims.M && a_col < dims.K)
            sA[tid_in_tg.x][tid_in_tg.y] =
                A[row * dims.K + a_col];
        else
            sA[tid_in_tg.x][tid_in_tg.y] = 0.0h;

        // B is row-major [N,K]. sB's first index is the local K
        // coordinate and its second index is the local output column.
        if (col < dims.N && b_col < dims.K)
            sB[tid_in_tg.x][tid_in_tg.y] =
                B[col * dims.K + b_col];
        else
            sB[tid_in_tg.x][tid_in_tg.y] = 0.0h;

        threadgroup_barrier(mem_flags::mem_threadgroup);

        // Compute partial dot product for this tile.
        #pragma unroll
        for (uint k = 0; k < TILE; k++) {
            acc += float(sA[tid_in_tg.x][k]) * float(sB[k][tid_in_tg.y]);
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Every thread must pass both barriers above, including threads outside
    // an asymmetric edge tile. Only active threads publish an output.
    if (active) C[row * dims.N + col] = half(acc);
}

// Fused decode projection: y[out] = dequant(INT4 W[out,in]) * x[in].
// Packed weights and FP32 scales stay resident in shared Metal buffers;
// only the small activation and output vectors cross the command boundary.
struct Int4MatvecDims {
    uint in_features;
    uint out_features;
    uint group_size;
    uint group_shift;
};

kernel void matvec_int4_f32(
    device const uchar* packed [[buffer(0)]],
    device const float* scales [[buffer(1)]],
    device const float* x      [[buffer(2)]],
    device float* out          [[buffer(3)]],
    constant Int4MatvecDims& dims [[buffer(4)]],
    uint row [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_simdgroup]],
    uint simd_width [[threads_per_simdgroup]])
{
    if (row >= dims.out_features) return;

    const uint row_start = row * dims.in_features;
    float acc = 0.0f;
    for (uint col = lane; col < dims.in_features; col += simd_width) {
        const uint weight_idx = row_start + col;
        const uchar byte = packed[weight_idx >> 1];
        const uchar nibble = (weight_idx & 1) ? (byte >> 4) : (byte & 0x0F);
        const float scale = scales[weight_idx >> dims.group_shift];
        acc = fma(x[col], (float(int(nibble) - 7) * scale), acc);
    }
    const float sum = simd_sum(acc);
    if (lane == 0) out[row] = sum;
}
