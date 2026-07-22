// Glacier Metal bridge — Objective-C shim callable from Zig.
//
// The bridge is intentionally minimal: it owns an id<MTLDevice>, can compile
// a shader library from a .metallib file, and exposes one entry point
// (glacier_metal_dequant_int4) that the Zig backend uses to dispatch the
// dequant kernel. Heavier operations (matmul, attention) will land here as
// the Metal backend matures.
//
// WHY Objective-C: Metal.framework is Objective-C. Swift would require a
// separate build target; calling Objective-C from Zig via extern "C" is the
// lightest-weight path that works on every macOS version we target.

#import <Metal/Metal.h>
#include <stdint.h>

// Opaque handle returned to Zig. The Zig side treats it as *anyopaque.
typedef struct {
    id<MTLDevice>       device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary>      library;
    id<MTLComputePipelineState> dequant_pipeline;
    id<MTLComputePipelineState> int4_matvec_pipeline;
} GlacierMetalContext;

typedef struct {
    id<MTLBuffer> packed;
    id<MTLBuffer> scales;
    id<MTLBuffer> input;
    id<MTLBuffer> output;
    uint32_t in_features;
    uint32_t out_features;
    uint32_t group_size;
    uint32_t group_shift;
} GlacierMetalInt4Weight;

// Create a Metal context. `metallib_path` is a UTF-8 path to a compiled
// .metallib (produced by `xcrun -sdk macosx metallib`). Returns NULL on
// failure (Metal unavailable, file missing, etc.).
GlacierMetalContext* glacier_metal_init(const char* metallib_path) {
    GlacierMetalContext* ctx = (GlacierMetalContext*)malloc(sizeof(GlacierMetalContext));
    if (!ctx) return NULL;
    ctx->device = MTLCreateSystemDefaultDevice();
    if (!ctx->device) { free(ctx); return NULL; }
    ctx->queue = [ctx->device newCommandQueue];

    NSString* path = [NSString stringWithUTF8String:metallib_path];
    NSError* err = nil;
    ctx->library = [ctx->device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
    if (!ctx->library) { free(ctx); return NULL; }

    id<MTLFunction> fn = [ctx->library newFunctionWithName:@"dequant_int4_to_f16"];
    if (!fn) { free(ctx); return NULL; }
    ctx->dequant_pipeline = [ctx->device newComputePipelineStateWithFunction:fn error:&err];
    if (!ctx->dequant_pipeline) { free(ctx); return NULL; }

    id<MTLFunction> matvec_fn = [ctx->library newFunctionWithName:@"matvec_int4_f32"];
    if (!matvec_fn) { free(ctx); return NULL; }
    ctx->int4_matvec_pipeline = [ctx->device newComputePipelineStateWithFunction:matvec_fn error:&err];
    if (!ctx->int4_matvec_pipeline) { free(ctx); return NULL; }
    return ctx;
}

void glacier_metal_deinit(GlacierMetalContext* ctx) {
    if (!ctx) return;
    // ARC under Obj-C GC handles release; for non-ARC build these are
    // bridging-retained. We assume ARC is enabled for this file.
    free(ctx);
}

// Dispatch the INT4 → FP16 dequant kernel.
//   payload: pointer to qio-encoded bytes (host memory)
//   payload_bytes: length of payload
//   out: caller-allocated FP16 buffer (host memory), num_elements * 2 bytes
//   num_elements: number of weights to decode
// Returns 0 on success, non-zero on error.
int glacier_metal_dequant_int4(
    GlacierMetalContext* ctx,
    const uint8_t* payload,
    uint64_t payload_bytes,
    void* out,
    uint32_t num_elements)
{
    if (!ctx || !payload || !out || payload_bytes < 16) return 1;

    uint32_t payload_magic = 0;
    uint32_t payload_elements = 0;
    uint32_t payload_group_size = 0;
    memcpy(&payload_magic, payload, sizeof(payload_magic));
    memcpy(&payload_elements, payload + 4, sizeof(payload_elements));
    memcpy(&payload_group_size, payload + 8, sizeof(payload_group_size));
    const uint8_t payload_precision = payload[12];
    if (payload_magic != 0x514F4954 || payload_elements != num_elements ||
        payload_group_size == 0 || payload_precision != 1) return 1;
    const uint64_t groups = ((uint64_t)num_elements + payload_group_size - 1) /
        payload_group_size;
    const uint64_t required_bytes = 16 + groups * sizeof(float) +
        ((uint64_t)num_elements + 1) / 2;
    if (payload_bytes < required_bytes) return 1;

    id<MTLBuffer> payload_buf = [ctx->device
        newBufferWithBytes:payload
                     length:payload_bytes
                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> out_buf = [ctx->device
        newBufferWithLength:num_elements * sizeof(uint16_t)
                     options:MTLResourceStorageModeShared];
    if (!payload_buf || !out_buf) return 2;

    // Pack the QIO sub-header into a constant buffer.
    struct { uint32_t magic, num_elements, group_size; uint8_t prec; uint8_t r[3]; } hdr;
    hdr.magic = payload_magic;
    hdr.num_elements = num_elements;
    hdr.group_size = payload_group_size;
    hdr.prec = payload_precision;
    id<MTLBuffer> hdr_buf = [ctx->device
        newBufferWithBytes:&hdr length:sizeof(hdr) options:MTLResourceStorageModeShared];

    id<MTLCommandBuffer> cb = [ctx->queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:ctx->dequant_pipeline];
    [enc setBuffer:payload_buf offset:0 atIndex:0];
    [enc setBuffer:out_buf    offset:0 atIndex:1];
    [enc setBuffer:hdr_buf    offset:0 atIndex:2];

    const NSUInteger threads_per_group = ctx->dequant_pipeline.maxTotalThreadsPerThreadgroup;
    MTLSize group_size = MTLSizeMake(threads_per_group, 1, 1);
    MTLSize grid_size   = MTLSizeMake(num_elements, 1, 1);
    [enc dispatchThreads:grid_size threadsPerThreadgroup:group_size];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) return 3;

    memcpy(out, out_buf.contents, num_elements * sizeof(uint16_t));
    return 0;
}

// Dispatch matmul_f16_tiled: C[M,N] = A[M,K] × B^T[N,K].
// A and B are half* (FP16), C is half* output.
// Returns 0 on success, non-zero on error.
int glacier_metal_matmul(
    GlacierMetalContext* ctx,
    const void* A_bytes,     // [M*K] half
    const void* B_bytes,     // [N*K] half (weights, transposed)
    void* C_bytes,            // [M*N] half output
    uint32_t M, uint32_t K, uint32_t N)
{
    if (!ctx || !A_bytes || !B_bytes || !C_bytes) return 1;

    id<MTLBuffer> a_buf = [ctx->device
        newBufferWithBytes:A_bytes length:M*K*sizeof(uint16_t)
                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> b_buf = [ctx->device
        newBufferWithBytes:B_bytes length:N*K*sizeof(uint16_t)
                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> c_buf = [ctx->device
        newBufferWithLength:M*N*sizeof(uint16_t)
                     options:MTLResourceStorageModeShared];
    if (!a_buf || !b_buf || !c_buf) return 2;

    // Use the tiled kernel for better cache utilization.
    id<MTLFunction> fn = [ctx->library newFunctionWithName:@"matmul_f16_tiled"];
    if (!fn) return 3;
    id<MTLComputePipelineState> pipeline =
        [ctx->device newComputePipelineStateWithFunction:fn error:nil];
    if (!pipeline) return 4;

    // Pack M, K, N into a constant buffer.
    struct { uint32_t M, K, N; } dims = {M, K, N};
    id<MTLBuffer> dim_buf = [ctx->device
        newBufferWithBytes:&dims length:sizeof(dims)
                     options:MTLResourceStorageModeShared];

    id<MTLCommandBuffer> cb = [ctx->queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pipeline];
    [enc setBuffer:a_buf offset:0 atIndex:0];
    [enc setBuffer:b_buf offset:0 atIndex:1];
    [enc setBuffer:c_buf offset:0 atIndex:2];
    [enc setBuffer:dim_buf offset:0 atIndex:3];

    // Thread grid: cover M×N with 16×16 tiles.
    const NSUInteger TILE = 16;
    MTLSize group_size = MTLSizeMake(TILE, TILE, 1);
    MTLSize grid_size = MTLSizeMake(
        ((M + TILE - 1) / TILE) * TILE,
        ((N + TILE - 1) / TILE) * TILE,
        1);
    [enc dispatchThreads:grid_size threadsPerThreadgroup:group_size];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    memcpy(C_bytes, c_buf.contents, M * N * sizeof(uint16_t));
    return 0;
}

// Upload one packed INT4 matrix and its scales once. The returned handle owns
// reusable activation/output buffers and is valid until explicitly destroyed.
GlacierMetalInt4Weight* glacier_metal_int4_weight_create(
    GlacierMetalContext* ctx,
    const uint8_t* packed,
    uint64_t packed_bytes,
    const float* scales,
    uint64_t scale_count,
    uint32_t group_size,
    uint32_t in_features,
    uint32_t out_features)
{
    if (!ctx || !packed || !scales || group_size == 0 ||
        (group_size & (group_size - 1)) != 0 || in_features == 0 || out_features == 0) return NULL;

    const uint64_t elements = (uint64_t)in_features * out_features;
    if (elements > UINT32_MAX) return NULL;
    const uint64_t required_packed = (elements + 1) / 2;
    const uint64_t required_scales = (elements + group_size - 1) / group_size;
    if (packed_bytes < required_packed || scale_count < required_scales) return NULL;

    GlacierMetalInt4Weight* weight =
        (GlacierMetalInt4Weight*)calloc(1, sizeof(GlacierMetalInt4Weight));
    if (!weight) return NULL;

    weight->packed = [ctx->device newBufferWithBytes:packed
                                               length:required_packed
                                              options:MTLResourceStorageModeShared];
    weight->scales = [ctx->device newBufferWithBytes:scales
                                               length:required_scales * sizeof(float)
                                              options:MTLResourceStorageModeShared];
    weight->input = [ctx->device newBufferWithLength:(uint64_t)in_features * sizeof(float)
                                              options:MTLResourceStorageModeShared];
    weight->output = [ctx->device newBufferWithLength:(uint64_t)out_features * sizeof(float)
                                               options:MTLResourceStorageModeShared];
    if (!weight->packed || !weight->scales || !weight->input || !weight->output) {
        free(weight);
        return NULL;
    }
    weight->in_features = in_features;
    weight->out_features = out_features;
    weight->group_size = group_size;
    weight->group_shift = __builtin_ctz(group_size);
    return weight;
}

void glacier_metal_int4_weight_destroy(GlacierMetalInt4Weight* weight) {
    if (!weight) return;
    weight->packed = nil;
    weight->scales = nil;
    weight->input = nil;
    weight->output = nil;
    free(weight);
}

int glacier_metal_int4_matvec(
    GlacierMetalContext* ctx,
    GlacierMetalInt4Weight* weight,
    const float* input,
    uint64_t input_count,
    float* output,
    uint64_t output_count)
{
    if (!ctx || !weight || !input || !output ||
        input_count < weight->in_features || output_count < weight->out_features) return 1;

    memcpy(weight->input.contents, input, (uint64_t)weight->in_features * sizeof(float));
    struct { uint32_t in_features, out_features, group_size, group_shift; } dims = {
        weight->in_features, weight->out_features, weight->group_size, weight->group_shift
    };

    id<MTLCommandBuffer> cb = [ctx->queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    if (!cb || !enc) return 2;
    [enc setComputePipelineState:ctx->int4_matvec_pipeline];
    [enc setBuffer:weight->packed offset:0 atIndex:0];
    [enc setBuffer:weight->scales offset:0 atIndex:1];
    [enc setBuffer:weight->input offset:0 atIndex:2];
    [enc setBuffer:weight->output offset:0 atIndex:3];
    [enc setBytes:&dims length:sizeof(dims) atIndex:4];

    const NSUInteger width = ctx->int4_matvec_pipeline.threadExecutionWidth;
    [enc dispatchThreadgroups:MTLSizeMake(weight->out_features, 1, 1)
         threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) return 3;

    memcpy(output, weight->output.contents,
        (uint64_t)weight->out_features * sizeof(float));
    return 0;
}
