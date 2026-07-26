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
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define GLACIER_METAL_DEVICE_INFO_ABI 0x474d444900000001ULL
#define GLACIER_METAL_DISPATCH_ABI 0x474d445200000001ULL

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

// Fixed-width, pointer-free facts used to derive the selected device and
// placement identities. Capacity is retained as capability context only; it
// is never relabelled as allocated or resident memory.
typedef struct {
    uint64_t abi_version;
    uint64_t registry_id;
    uint64_t current_allocated_size;
    uint64_t recommended_max_working_set_size;
    uint64_t location;
    uint64_t location_number;
    uint64_t max_threads_x;
    uint64_t max_threads_y;
    uint64_t max_threads_z;
    uint32_t low_power;
    uint32_t headless;
    uint32_t removable;
    uint32_t unified_memory;
} GlacierMetalDeviceInfo;

// One completed command-buffer observation. GPU timestamps are retained as
// their exact IEEE-754 bit patterns by the Zig wrapper before hashing.
typedef struct {
    uint64_t abi_version;
    uint64_t current_allocated_before;
    uint64_t current_allocated_after;
    double gpu_start_time;
    double gpu_end_time;
    uint32_t command_status;
    uint32_t reserved;
} GlacierMetalDispatchObservation;

_Static_assert(sizeof(GlacierMetalDeviceInfo) == 88,
    "GlacierMetalDeviceInfo ABI size changed");
_Static_assert(offsetof(GlacierMetalDeviceInfo, registry_id) == 8,
    "GlacierMetalDeviceInfo registry offset changed");
_Static_assert(offsetof(GlacierMetalDeviceInfo, current_allocated_size) == 16,
    "GlacierMetalDeviceInfo allocation offset changed");
_Static_assert(offsetof(GlacierMetalDeviceInfo, low_power) == 72,
    "GlacierMetalDeviceInfo flag offset changed");
_Static_assert(sizeof(GlacierMetalDispatchObservation) == 48,
    "GlacierMetalDispatchObservation ABI size changed");
_Static_assert(offsetof(GlacierMetalDispatchObservation, gpu_start_time) == 24,
    "GlacierMetalDispatchObservation start offset changed");
_Static_assert(offsetof(GlacierMetalDispatchObservation, command_status) == 40,
    "GlacierMetalDispatchObservation status offset changed");

static void glacier_metal_context_destroy(GlacierMetalContext* ctx) {
    if (!ctx) return;
    ctx->int4_matvec_pipeline = nil;
    ctx->dequant_pipeline = nil;
    ctx->library = nil;
    ctx->queue = nil;
    ctx->device = nil;
    free(ctx);
}

static void glacier_metal_weight_destroy(GlacierMetalInt4Weight* weight) {
    if (!weight) return;
    weight->packed = nil;
    weight->scales = nil;
    weight->input = nil;
    weight->output = nil;
    free(weight);
}

// Create a Metal context. `metallib_path` is a UTF-8 path to a compiled
// .metallib (produced by `xcrun -sdk macosx metallib`). Returns NULL on
// failure (Metal unavailable, file missing, etc.).
GlacierMetalContext* glacier_metal_init(const char* metallib_path) {
    GlacierMetalContext* ctx =
        (GlacierMetalContext*)calloc(1, sizeof(GlacierMetalContext));
    if (!ctx) return NULL;
    ctx->device = MTLCreateSystemDefaultDevice();
    if (!ctx->device) {
        glacier_metal_context_destroy(ctx);
        return NULL;
    }
    ctx->queue = [ctx->device newCommandQueue];
    if (!ctx->queue) {
        glacier_metal_context_destroy(ctx);
        return NULL;
    }

    NSString* path = [NSString stringWithUTF8String:metallib_path];
    if (!path) {
        glacier_metal_context_destroy(ctx);
        return NULL;
    }
    NSError* err = nil;
    ctx->library = [ctx->device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
    if (!ctx->library) {
        glacier_metal_context_destroy(ctx);
        return NULL;
    }

    id<MTLFunction> fn = [ctx->library newFunctionWithName:@"dequant_int4_to_f16"];
    if (!fn) {
        glacier_metal_context_destroy(ctx);
        return NULL;
    }
    ctx->dequant_pipeline = [ctx->device newComputePipelineStateWithFunction:fn error:&err];
    if (!ctx->dequant_pipeline) {
        glacier_metal_context_destroy(ctx);
        return NULL;
    }

    id<MTLFunction> matvec_fn = [ctx->library newFunctionWithName:@"matvec_int4_f32"];
    if (!matvec_fn) {
        glacier_metal_context_destroy(ctx);
        return NULL;
    }
    ctx->int4_matvec_pipeline = [ctx->device newComputePipelineStateWithFunction:matvec_fn error:&err];
    if (!ctx->int4_matvec_pipeline) {
        glacier_metal_context_destroy(ctx);
        return NULL;
    }
    return ctx;
}

void glacier_metal_deinit(GlacierMetalContext* ctx) {
    glacier_metal_context_destroy(ctx);
}

int glacier_metal_device_info(
    GlacierMetalContext* ctx,
    GlacierMetalDeviceInfo* out)
{
    if (!ctx || !ctx->device || !out) return 1;
    memset(out, 0, sizeof(*out));
    out->abi_version = GLACIER_METAL_DEVICE_INFO_ABI;
    out->registry_id = ctx->device.registryID;
    out->current_allocated_size = ctx->device.currentAllocatedSize;
    out->recommended_max_working_set_size =
        ctx->device.recommendedMaxWorkingSetSize;
    out->location = (uint64_t)ctx->device.location;
    out->location_number = (uint64_t)ctx->device.locationNumber;
    const MTLSize max_threads = ctx->device.maxThreadsPerThreadgroup;
    out->max_threads_x = (uint64_t)max_threads.width;
    out->max_threads_y = (uint64_t)max_threads.height;
    out->max_threads_z = (uint64_t)max_threads.depth;
    out->low_power = ctx->device.isLowPower ? 1U : 0U;
    out->headless = ctx->device.isHeadless ? 1U : 0U;
    out->removable = ctx->device.isRemovable ? 1U : 0U;
    out->unified_memory = ctx->device.hasUnifiedMemory ? 1U : 0U;
    return 0;
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
        glacier_metal_weight_destroy(weight);
        return NULL;
    }
    weight->in_features = in_features;
    weight->out_features = out_features;
    weight->group_size = group_size;
    weight->group_shift = __builtin_ctz(group_size);
    return weight;
}

void glacier_metal_int4_weight_destroy(GlacierMetalInt4Weight* weight) {
    glacier_metal_weight_destroy(weight);
}

int glacier_metal_int4_matvec_observed(
    GlacierMetalContext* ctx,
    GlacierMetalInt4Weight* weight,
    const float* input,
    uint64_t input_count,
    float* output,
    uint64_t output_count,
    GlacierMetalDispatchObservation* observation)
{
    if (observation) {
        memset(observation, 0, sizeof(*observation));
        observation->abi_version = GLACIER_METAL_DISPATCH_ABI;
    }
    if (!ctx || !weight || !input || !output ||
        input_count < weight->in_features || output_count < weight->out_features) return 1;

    if (observation) {
        observation->current_allocated_before =
            ctx->device.currentAllocatedSize;
    }
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
    if (observation) {
        observation->current_allocated_after =
            ctx->device.currentAllocatedSize;
        observation->gpu_start_time = cb.GPUStartTime;
        observation->gpu_end_time = cb.GPUEndTime;
        observation->command_status = (uint32_t)cb.status;
    }
    if (cb.status != MTLCommandBufferStatusCompleted) return 3;

    memcpy(output, weight->output.contents,
        (uint64_t)weight->out_features * sizeof(float));
    return 0;
}

int glacier_metal_int4_matvec(
    GlacierMetalContext* ctx,
    GlacierMetalInt4Weight* weight,
    const float* input,
    uint64_t input_count,
    float* output,
    uint64_t output_count)
{
    return glacier_metal_int4_matvec_observed(
        ctx,
        weight,
        input,
        input_count,
        output,
        output_count,
        NULL);
}
