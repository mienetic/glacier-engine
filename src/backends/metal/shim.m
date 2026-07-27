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
#define GLACIER_METAL_ALLOCATION_LIMITS_ABI 0x474d414900000001ULL
#define GLACIER_METAL_BUFFER_INFO_ABI 0x474d424900000001ULL
#define GLACIER_METAL_ADAPTER_IDENTITY_ABI 0x474d414400000001ULL

typedef struct GlacierMetalBufferAllocation
    GlacierMetalBufferAllocation;

// Copyable native token. It contains no pointer: the random context nonce
// rejects foreign contexts and the never-reused generation rejects stale
// copies after release.
typedef struct {
    uint64_t context_nonce[4];
    uint64_t generation;
} GlacierMetalBufferToken;

// Opaque handle returned to Zig. The Zig side treats it as *anyopaque.
typedef struct {
    id<MTLDevice>       device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary>      library;
    id<MTLComputePipelineState> dequant_pipeline;
    id<MTLComputePipelineState> matmul_pipeline;
    id<MTLComputePipelineState> int4_matvec_pipeline;
    GlacierMetalBufferAllocation* buffer_allocations;
    uint64_t allocation_context_nonce[4];
    uint64_t next_allocation_adapter_instance;
    uint64_t next_buffer_generation;
    uint64_t live_buffer_allocations;
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

// Private native ownership object. Its address never crosses into portable
// evidence; the Zig adapter retains it only in a generation-fenced slot.
struct GlacierMetalBufferAllocation {
    GlacierMetalContext* owner;
    GlacierMetalBufferAllocation* next;
    GlacierMetalBufferToken token;
    id<MTLBuffer> buffer;
    uint64_t device_registry_id;
    uint64_t requested_length;
    uint64_t resource_length;
    uint64_t allocated_size;
};

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

// Immutable policy facts for direct Shared MTLBuffer allocation. Resource
// bytes use the exact MTLBuffer.length contract. allocatedSize is intentionally
// absent because Metal exposes it only after a resource has been created.
typedef struct {
    uint64_t abi_version;
    uint64_t device_registry_id;
    uint64_t max_buffer_length;
    uint64_t resource_granularity;
    uint32_t storage_mode;
    uint32_t cpu_cache_mode;
} GlacierMetalAllocationLimits;

// Direct facts from one live MTLBuffer. allocated_size is a per-resource
// observation and is never inferred from MTLDevice.currentAllocatedSize.
typedef struct {
    uint64_t abi_version;
    uint64_t device_registry_id;
    uint64_t requested_length;
    uint64_t resource_length;
    uint64_t allocated_size;
    uint32_t storage_mode;
    uint32_t cpu_cache_mode;
} GlacierMetalBufferInfo;

// A random context nonce plus a monotonic per-context instance prevents two
// adapters initialized with the same caller nonce from sharing an authority.
typedef struct {
    uint64_t abi_version;
    uint64_t context_nonce[4];
    uint64_t adapter_instance;
} GlacierMetalAdapterIdentity;

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
_Static_assert(sizeof(GlacierMetalAllocationLimits) == 40,
    "GlacierMetalAllocationLimits ABI size changed");
_Static_assert(offsetof(GlacierMetalAllocationLimits, storage_mode) == 32,
    "GlacierMetalAllocationLimits mode offset changed");
_Static_assert(sizeof(GlacierMetalBufferInfo) == 48,
    "GlacierMetalBufferInfo ABI size changed");
_Static_assert(offsetof(GlacierMetalBufferInfo, allocated_size) == 32,
    "GlacierMetalBufferInfo allocation offset changed");
_Static_assert(sizeof(GlacierMetalAdapterIdentity) == 48,
    "GlacierMetalAdapterIdentity ABI size changed");
_Static_assert(offsetof(GlacierMetalAdapterIdentity, adapter_instance) == 40,
    "GlacierMetalAdapterIdentity instance offset changed");
_Static_assert(sizeof(GlacierMetalBufferToken) == 40,
    "GlacierMetalBufferToken ABI size changed");
_Static_assert(offsetof(GlacierMetalBufferToken, generation) == 32,
    "GlacierMetalBufferToken generation offset changed");

static int glacier_metal_nonce_is_zero(const uint64_t nonce[4]) {
    return nonce[0] == 0 && nonce[1] == 0 &&
        nonce[2] == 0 && nonce[3] == 0;
}

static void glacier_metal_context_destroy(GlacierMetalContext* ctx) {
    if (!ctx) return;
    while (ctx->buffer_allocations) {
        GlacierMetalBufferAllocation* allocation =
            ctx->buffer_allocations;
        ctx->buffer_allocations = allocation->next;
        allocation->owner = NULL;
        allocation->next = NULL;
        allocation->buffer = nil;
        free(allocation);
    }
    ctx->live_buffer_allocations = 0;
    ctx->int4_matvec_pipeline = nil;
    ctx->matmul_pipeline = nil;
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

static void glacier_metal_buffer_destroy(
    GlacierMetalBufferAllocation* allocation)
{
    if (!allocation) return;
    allocation->owner = NULL;
    allocation->next = NULL;
    allocation->buffer = nil;
    free(allocation);
}

// Find a handle by pointer identity without dereferencing the untrusted input.
// Callers hold @synchronized(ctx->device) while traversing the owned list.
static GlacierMetalBufferAllocation** glacier_metal_buffer_link_locked(
    GlacierMetalContext* ctx,
    const GlacierMetalBufferToken* token)
{
    GlacierMetalBufferAllocation** link = &ctx->buffer_allocations;
    while (*link && memcmp(
            &(*link)->token,
            token,
            sizeof(*token)) != 0)
        link = &(*link)->next;
    return *link ? link : NULL;
}

// Validate one exact registry resource while the device registry lock is held.
// Returning the allocation is safe only until the caller leaves the lock; a
// copied strong MTLBuffer reference remains valid independently afterward.
static GlacierMetalBufferAllocation*
glacier_metal_buffer_exact_locked(
    GlacierMetalContext* ctx,
    const GlacierMetalBufferToken* token,
    uint64_t required_length)
{
    if (!ctx || !token || token->generation == 0 ||
        required_length == 0)
        return NULL;
    GlacierMetalBufferAllocation** link =
        glacier_metal_buffer_link_locked(ctx, token);
    if (!link)
        return NULL;
    GlacierMetalBufferAllocation* allocation = *link;
    if (allocation->owner != ctx || !allocation->buffer ||
        allocation->device_registry_id != ctx->device.registryID ||
        allocation->requested_length != required_length ||
        allocation->resource_length != required_length ||
        allocation->allocated_size < required_length ||
        allocation->buffer.device.registryID !=
            allocation->device_registry_id ||
        (uint64_t)allocation->buffer.length !=
            allocation->resource_length ||
        (uint64_t)allocation->buffer.allocatedSize !=
            allocation->allocated_size ||
        allocation->buffer.storageMode != MTLStorageModeShared ||
        allocation->buffer.cpuCacheMode !=
            MTLCPUCacheModeDefaultCache)
        return NULL;
    return allocation;
}

// Pipelines are independent operation capabilities. Resolve and cache each one
// only when requested so a context remains usable when unrelated functions are
// absent from a valid metallib.
static id<MTLComputePipelineState> glacier_metal_get_dequant_pipeline(
    GlacierMetalContext* ctx)
{
    if (!ctx || !ctx->device || !ctx->library) return nil;
    if (ctx->dequant_pipeline) return ctx->dequant_pipeline;

    @synchronized (ctx->library) {
        if (!ctx->dequant_pipeline) {
            id<MTLFunction> function =
                [ctx->library newFunctionWithName:@"dequant_int4_to_f16"];
            if (function) {
                NSError* error = nil;
                ctx->dequant_pipeline =
                    [ctx->device
                        newComputePipelineStateWithFunction:function
                                                     error:&error];
            }
        }
    }
    return ctx->dequant_pipeline;
}

static id<MTLComputePipelineState> glacier_metal_get_matmul_pipeline(
    GlacierMetalContext* ctx)
{
    if (!ctx || !ctx->device || !ctx->library) return nil;
    if (ctx->matmul_pipeline) return ctx->matmul_pipeline;

    // MetalBackend is currently single-owner, but synchronizing lazy creation
    // also prevents duplicate pipeline publication if callers race matmul.
    @synchronized (ctx->library) {
        if (!ctx->matmul_pipeline) {
            id<MTLFunction> function =
                [ctx->library newFunctionWithName:@"matmul_f16_tiled"];
            if (function) {
                NSError* error = nil;
                ctx->matmul_pipeline =
                    [ctx->device
                        newComputePipelineStateWithFunction:function
                                                     error:&error];
            }
        }
    }
    return ctx->matmul_pipeline;
}

static id<MTLComputePipelineState> glacier_metal_get_int4_matvec_pipeline(
    GlacierMetalContext* ctx)
{
    if (!ctx || !ctx->device || !ctx->library) return nil;
    if (ctx->int4_matvec_pipeline) return ctx->int4_matvec_pipeline;

    @synchronized (ctx->library) {
        if (!ctx->int4_matvec_pipeline) {
            id<MTLFunction> function =
                [ctx->library newFunctionWithName:@"matvec_int4_f32"];
            if (function) {
                NSError* error = nil;
                ctx->int4_matvec_pipeline =
                    [ctx->device
                        newComputePipelineStateWithFunction:function
                                                     error:&error];
            }
        }
    }
    return ctx->int4_matvec_pipeline;
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
    do {
        arc4random_buf(
            ctx->allocation_context_nonce,
            sizeof(ctx->allocation_context_nonce));
    } while (glacier_metal_nonce_is_zero(
        ctx->allocation_context_nonce));
    ctx->next_allocation_adapter_instance = 1;
    ctx->next_buffer_generation = 1;
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
    if (![ctx->device respondsToSelector:@selector(registryID)] ||
        ![ctx->device
            respondsToSelector:@selector(currentAllocatedSize)] ||
        ![ctx->device
            respondsToSelector:
                @selector(recommendedMaxWorkingSetSize)] ||
        ![ctx->device respondsToSelector:@selector(location)] ||
        ![ctx->device respondsToSelector:@selector(locationNumber)] ||
        ![ctx->device respondsToSelector:@selector(hasUnifiedMemory)])
        return 1;
    @try {
        out->abi_version = GLACIER_METAL_DEVICE_INFO_ABI;
        out->registry_id = ctx->device.registryID;
        out->current_allocated_size =
            ctx->device.currentAllocatedSize;
        out->recommended_max_working_set_size =
            ctx->device.recommendedMaxWorkingSetSize;
        out->location = (uint64_t)ctx->device.location;
        out->location_number =
            (uint64_t)ctx->device.locationNumber;
        const MTLSize max_threads =
            ctx->device.maxThreadsPerThreadgroup;
        out->max_threads_x = (uint64_t)max_threads.width;
        out->max_threads_y = (uint64_t)max_threads.height;
        out->max_threads_z = (uint64_t)max_threads.depth;
        out->low_power = ctx->device.isLowPower ? 1U : 0U;
        out->headless = ctx->device.isHeadless ? 1U : 0U;
        out->removable = ctx->device.isRemovable ? 1U : 0U;
        out->unified_memory =
            ctx->device.hasUnifiedMemory ? 1U : 0U;
    } @catch (NSException* exception) {
        (void)exception;
        memset(out, 0, sizeof(*out));
        return 2;
    }
    return 0;
}

int glacier_metal_allocation_limits(
    GlacierMetalContext* ctx,
    GlacierMetalAllocationLimits* out)
{
    if (!ctx || !ctx->device || !out) return 1;
    memset(out, 0, sizeof(*out));
    if (![ctx->device respondsToSelector:@selector(registryID)] ||
        ![ctx->device respondsToSelector:@selector(maxBufferLength)])
        return 1;
    @try {
        out->abi_version =
            GLACIER_METAL_ALLOCATION_LIMITS_ABI;
        out->device_registry_id = ctx->device.registryID;
        out->max_buffer_length = ctx->device.maxBufferLength;
        // Direct MTLBuffer.length preserves the caller's byte length
        // exactly; it is not the heap alignment returned by
        // heapBufferSizeAndAlign.
        out->resource_granularity = 1;
        out->storage_mode = (uint32_t)MTLStorageModeShared;
        out->cpu_cache_mode =
            (uint32_t)MTLCPUCacheModeDefaultCache;
    } @catch (NSException* exception) {
        (void)exception;
        memset(out, 0, sizeof(*out));
        return 2;
    }
    return 0;
}

int glacier_metal_claim_allocation_adapter(
    GlacierMetalContext* ctx,
    GlacierMetalAdapterIdentity* out)
{
    if (!ctx || !ctx->device || !out) return 1;
    memset(out, 0, sizeof(*out));
    @synchronized (ctx->device) {
        if (glacier_metal_nonce_is_zero(
                ctx->allocation_context_nonce) ||
            ctx->next_allocation_adapter_instance == 0 ||
            ctx->next_allocation_adapter_instance == UINT64_MAX)
            return 2;
        out->abi_version =
            GLACIER_METAL_ADAPTER_IDENTITY_ABI;
        memcpy(
            out->context_nonce,
            ctx->allocation_context_nonce,
            sizeof(out->context_nonce));
        out->adapter_instance =
            ctx->next_allocation_adapter_instance;
        ctx->next_allocation_adapter_instance += 1;
    }
    return 0;
}

int glacier_metal_buffer_create(
    GlacierMetalContext* ctx,
    uint64_t requested_length,
    GlacierMetalBufferToken* out)
{
    if (out) memset(out, 0, sizeof(*out));
    if (!ctx || !ctx->device ||
        ![ctx->device respondsToSelector:@selector(maxBufferLength)] ||
        !out ||
        requested_length == 0 ||
        requested_length > (uint64_t)SIZE_MAX)
        return 1;

    GlacierMetalBufferAllocation* allocation = NULL;
    @try {
        if (requested_length >
            (uint64_t)ctx->device.maxBufferLength)
            return 1;
        allocation =
            (GlacierMetalBufferAllocation*)calloc(
                1,
                sizeof(GlacierMetalBufferAllocation));
        if (!allocation) return 2;

        const MTLResourceOptions options =
            MTLResourceStorageModeShared |
            MTLResourceCPUCacheModeDefaultCache;
        allocation->buffer = [ctx->device
            newBufferWithLength:(NSUInteger)requested_length
                         options:options];
        if (!allocation->buffer ||
            ![allocation->buffer
                respondsToSelector:@selector(allocatedSize)]) {
            glacier_metal_buffer_destroy(allocation);
            return 2;
        }

        allocation->device_registry_id =
            allocation->buffer.device.registryID;
        allocation->requested_length = requested_length;
        allocation->resource_length =
            (uint64_t)allocation->buffer.length;
        allocation->allocated_size =
            (uint64_t)allocation->buffer.allocatedSize;
        if (allocation->device_registry_id !=
                ctx->device.registryID ||
            allocation->resource_length != requested_length ||
            allocation->allocated_size == 0 ||
            allocation->allocated_size <
                allocation->resource_length ||
            allocation->buffer.storageMode != MTLStorageModeShared ||
            allocation->buffer.cpuCacheMode !=
                MTLCPUCacheModeDefaultCache)
        {
            glacier_metal_buffer_destroy(allocation);
            return 2;
        }
    } @catch (NSException* exception) {
        (void)exception;
        glacier_metal_buffer_destroy(allocation);
        return 2;
    }
    @synchronized (ctx->device) {
        if (ctx->next_buffer_generation == 0 ||
            ctx->next_buffer_generation == UINT64_MAX ||
            ctx->live_buffer_allocations == UINT64_MAX) {
            glacier_metal_buffer_destroy(allocation);
            return 3;
        }
        allocation->owner = ctx;
        memcpy(
            allocation->token.context_nonce,
            ctx->allocation_context_nonce,
            sizeof(allocation->token.context_nonce));
        allocation->token.generation =
            ctx->next_buffer_generation;
        ctx->next_buffer_generation += 1;
        allocation->next = ctx->buffer_allocations;
        ctx->buffer_allocations = allocation;
        ctx->live_buffer_allocations += 1;
        *out = allocation->token;
    }
    return 0;
}

int glacier_metal_buffer_info(
    GlacierMetalContext* ctx,
    const GlacierMetalBufferToken* token,
    GlacierMetalBufferInfo* out)
{
    if (!ctx || !ctx->device || !token || !out ||
        token->generation == 0)
        return 1;
    memset(out, 0, sizeof(*out));
    @synchronized (ctx->device) {
        GlacierMetalBufferAllocation** link =
            glacier_metal_buffer_link_locked(ctx, token);
        if (!link)
            return 2;
        GlacierMetalBufferAllocation* allocation = *link;
        if (allocation->owner != ctx || !allocation->buffer)
            return 2;
        @try {
            out->abi_version = GLACIER_METAL_BUFFER_INFO_ABI;
            out->device_registry_id =
                allocation->buffer.device.registryID;
            out->requested_length =
                allocation->requested_length;
            out->resource_length =
                (uint64_t)allocation->buffer.length;
            out->allocated_size =
                (uint64_t)allocation->buffer.allocatedSize;
            out->storage_mode =
                (uint32_t)allocation->buffer.storageMode;
            out->cpu_cache_mode =
                (uint32_t)allocation->buffer.cpuCacheMode;
            if (out->device_registry_id !=
                    allocation->device_registry_id ||
                out->resource_length !=
                    allocation->resource_length ||
                out->allocated_size != allocation->allocated_size)
                return 3;
        } @catch (NSException* exception) {
            (void)exception;
            memset(out, 0, sizeof(*out));
            return 4;
        }
    }
    return 0;
}

int glacier_metal_buffer_release(
    GlacierMetalContext* ctx,
    const GlacierMetalBufferToken* token)
{
    if (!ctx || !ctx->device || !token ||
        token->generation == 0)
        return 1;
    GlacierMetalBufferAllocation* allocation = NULL;
    @synchronized (ctx->device) {
        GlacierMetalBufferAllocation** link =
            glacier_metal_buffer_link_locked(ctx, token);
        if (!link || (*link)->owner != ctx)
            return 2;
        if (ctx->live_buffer_allocations == 0)
            return 3;
        allocation = *link;
        *link = allocation->next;
        allocation->owner = NULL;
        allocation->next = NULL;
        ctx->live_buffer_allocations -= 1;
    }
    glacier_metal_buffer_destroy(allocation);
    return 0;
}

int glacier_metal_live_buffer_count(
    GlacierMetalContext* ctx,
    uint64_t* out)
{
    if (!ctx || !ctx->device || !out) return 1;
    @synchronized (ctx->device) {
        *out = ctx->live_buffer_allocations;
    }
    return 0;
}

int glacier_metal_require_int4_matvec_support(
    GlacierMetalContext* ctx)
{
    return glacier_metal_get_int4_matvec_pipeline(ctx) ? 0 : 1;
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
    if (!ctx || !ctx->device || !ctx->queue || !ctx->library ||
        !payload || !out || payload_bytes < 16)
        return 1;
    id<MTLComputePipelineState> pipeline =
        glacier_metal_get_dequant_pipeline(ctx);
    if (!pipeline) return 1;

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
    if (!hdr_buf) return 2;

    id<MTLCommandBuffer> cb = [ctx->queue commandBuffer];
    if (!cb) return 2;
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    if (!enc) return 2;
    [enc setComputePipelineState:pipeline];
    [enc setBuffer:payload_buf offset:0 atIndex:0];
    [enc setBuffer:out_buf    offset:0 atIndex:1];
    [enc setBuffer:hdr_buf    offset:0 atIndex:2];

    const NSUInteger threads_per_group =
        pipeline.maxTotalThreadsPerThreadgroup;
    MTLSize group_size = MTLSizeMake(threads_per_group, 1, 1);
    MTLSize grid_size   = MTLSizeMake(num_elements, 1, 1);
    [enc dispatchThreads:grid_size threadsPerThreadgroup:group_size];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) return 3;

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
    if (!ctx || !ctx->device || !ctx->queue || !ctx->library ||
        !A_bytes || !B_bytes || !C_bytes || M == 0 || K == 0 || N == 0)
        return 1;

    const uint64_t a_elements = (uint64_t)M * (uint64_t)K;
    const uint64_t b_elements = (uint64_t)N * (uint64_t)K;
    const uint64_t c_elements = (uint64_t)M * (uint64_t)N;
    if (a_elements > SIZE_MAX / sizeof(uint16_t) ||
        b_elements > SIZE_MAX / sizeof(uint16_t) ||
        c_elements > SIZE_MAX / sizeof(uint16_t))
        return 1;
    const NSUInteger a_length =
        (NSUInteger)(a_elements * sizeof(uint16_t));
    const NSUInteger b_length =
        (NSUInteger)(b_elements * sizeof(uint16_t));
    const NSUInteger c_length =
        (NSUInteger)(c_elements * sizeof(uint16_t));

    id<MTLComputePipelineState> pipeline =
        glacier_metal_get_matmul_pipeline(ctx);
    if (!pipeline) return 2;

    const NSUInteger TILE = 16;
    if (pipeline.maxTotalThreadsPerThreadgroup < TILE * TILE)
        return 2;

    id<MTLBuffer> a_buf = [ctx->device
        newBufferWithBytes:A_bytes length:a_length
                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> b_buf = [ctx->device
        newBufferWithBytes:B_bytes length:b_length
                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> c_buf = [ctx->device
        newBufferWithLength:c_length
                     options:MTLResourceStorageModeShared];
    if (!a_buf || !b_buf || !c_buf) return 2;

    // The shader consumes this exact struct at buffer index 3.
    struct { uint32_t M, K, N; } dims = {M, K, N};

    id<MTLCommandBuffer> cb = [ctx->queue commandBuffer];
    if (!cb) return 3;
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    if (!enc) return 3;
    [enc setComputePipelineState:pipeline];
    [enc setBuffer:a_buf offset:0 atIndex:0];
    [enc setBuffer:b_buf offset:0 atIndex:1];
    [enc setBuffer:c_buf offset:0 atIndex:2];
    [enc setBytes:&dims length:sizeof(dims) atIndex:3];

    // Thread grid: cover M×N with 16×16 tiles.
    MTLSize group_size = MTLSizeMake(TILE, TILE, 1);
    MTLSize grid_size = MTLSizeMake(
        (((NSUInteger)M + TILE - 1) / TILE) * TILE,
        (((NSUInteger)N + TILE - 1) / TILE) * TILE,
        1);
    [enc dispatchThreads:grid_size threadsPerThreadgroup:group_size];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) return 4;

    memcpy(C_bytes, c_buf.contents, c_length);
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

// Copy the last completed persistent-weight output into caller memory. The
// observed Zig path invokes this only after validating command-buffer
// telemetry, keeping invalid evidence from publishing candidate output.
int glacier_metal_int4_weight_read_output(
    GlacierMetalInt4Weight* weight,
    float* output,
    uint64_t output_count)
{
    if (!weight || !weight->output || !output ||
        output_count < weight->out_features)
        return 1;
    memcpy(output, weight->output.contents,
        (uint64_t)weight->out_features * sizeof(float));
    return 0;
}

// Dispatch using four exact resources owned by the native allocation registry.
// Host output is intentionally absent: Zig validates the completed observation
// before invoking glacier_metal_int4_registered_output_read.
int glacier_metal_int4_registered_buffers_observed(
    GlacierMetalContext* ctx,
    const GlacierMetalBufferToken* packed_token,
    const GlacierMetalBufferToken* scales_token,
    const GlacierMetalBufferToken* input_token,
    const GlacierMetalBufferToken* output_token,
    const uint8_t* packed,
    uint64_t packed_bytes,
    const float* scales,
    uint64_t scale_count,
    const float* input,
    uint64_t input_count,
    uint32_t group_size,
    uint32_t in_features,
    uint32_t out_features,
    GlacierMetalDispatchObservation* observation)
{
    if (observation) {
        memset(observation, 0, sizeof(*observation));
        observation->abi_version = GLACIER_METAL_DISPATCH_ABI;
    }
    if (!ctx || !ctx->device || !ctx->queue || !ctx->library ||
        !packed_token || !scales_token || !input_token ||
        !output_token || !packed || !scales || !input ||
        !observation || group_size == 0 ||
        (group_size & (group_size - 1)) != 0 ||
        in_features == 0 || out_features == 0 ||
        packed_token->generation == 0 ||
        scales_token->generation == 0 ||
        input_token->generation == 0 ||
        output_token->generation == 0)
        return 1;
    if (glacier_metal_nonce_is_zero(packed_token->context_nonce) ||
        memcmp(
            packed_token->context_nonce,
            scales_token->context_nonce,
            sizeof(packed_token->context_nonce)) != 0 ||
        memcmp(
            packed_token->context_nonce,
            input_token->context_nonce,
            sizeof(packed_token->context_nonce)) != 0 ||
        memcmp(
            packed_token->context_nonce,
            output_token->context_nonce,
            sizeof(packed_token->context_nonce)) != 0)
        return 1;
    if (memcmp(packed_token, scales_token, sizeof(*packed_token)) == 0 ||
        memcmp(packed_token, input_token, sizeof(*packed_token)) == 0 ||
        memcmp(packed_token, output_token, sizeof(*packed_token)) == 0 ||
        memcmp(scales_token, input_token, sizeof(*packed_token)) == 0 ||
        memcmp(scales_token, output_token, sizeof(*packed_token)) == 0 ||
        memcmp(input_token, output_token, sizeof(*packed_token)) == 0)
        return 1;

    const uint64_t elements =
        (uint64_t)in_features * (uint64_t)out_features;
    if (elements > UINT32_MAX)
        return 1;
    const uint64_t required_packed = (elements + 1) / 2;
    const uint64_t required_scales =
        (elements + group_size - 1) / group_size;
    const uint64_t scales_bytes =
        required_scales * sizeof(float);
    const uint64_t input_bytes =
        (uint64_t)in_features * sizeof(float);
    const uint64_t output_bytes =
        (uint64_t)out_features * sizeof(float);
    if (packed_bytes != required_packed ||
        scale_count != required_scales ||
        input_count != in_features)
        return 1;

    id<MTLBuffer> packed_buffer = nil;
    id<MTLBuffer> scales_buffer = nil;
    id<MTLBuffer> input_buffer = nil;
    id<MTLBuffer> output_buffer = nil;
    void* packed_contents = NULL;
    void* scales_contents = NULL;
    void* input_contents = NULL;
    @try {
        @synchronized (ctx->device) {
            GlacierMetalBufferAllocation* packed_allocation =
                glacier_metal_buffer_exact_locked(
                    ctx, packed_token, required_packed);
            GlacierMetalBufferAllocation* scales_allocation =
                glacier_metal_buffer_exact_locked(
                    ctx, scales_token, scales_bytes);
            GlacierMetalBufferAllocation* input_allocation =
                glacier_metal_buffer_exact_locked(
                    ctx, input_token, input_bytes);
            GlacierMetalBufferAllocation* output_allocation =
                glacier_metal_buffer_exact_locked(
                    ctx, output_token, output_bytes);
            if (!packed_allocation || !scales_allocation ||
                !input_allocation || !output_allocation)
                return 2;
            packed_buffer = packed_allocation->buffer;
            scales_buffer = scales_allocation->buffer;
            input_buffer = input_allocation->buffer;
            output_buffer = output_allocation->buffer;
            packed_contents = packed_buffer.contents;
            scales_contents = scales_buffer.contents;
            input_contents = input_buffer.contents;
            if (!packed_contents || !scales_contents ||
                !input_contents || !output_buffer.contents)
                return 2;
        }
    } @catch (NSException* exception) {
        (void)exception;
        return 2;
    }

    id<MTLComputePipelineState> pipeline =
        glacier_metal_get_int4_matvec_pipeline(ctx);
    if (!pipeline || pipeline.threadExecutionWidth == 0)
        return 3;

    observation->current_allocated_before =
        ctx->device.currentAllocatedSize;
    memcpy(packed_contents, packed, required_packed);
    memcpy(scales_contents, scales, scales_bytes);
    memcpy(input_contents, input, input_bytes);
    struct {
        uint32_t in_features;
        uint32_t out_features;
        uint32_t group_size;
        uint32_t group_shift;
    } dims = {
        in_features,
        out_features,
        group_size,
        __builtin_ctz(group_size),
    };

    id<MTLCommandBuffer> cb = [ctx->queue commandBuffer];
    if (!cb)
        return 4;
    id<MTLComputeCommandEncoder> enc =
        [cb computeCommandEncoder];
    if (!enc)
        return 4;
    [enc setComputePipelineState:pipeline];
    [enc setBuffer:packed_buffer offset:0 atIndex:0];
    [enc setBuffer:scales_buffer offset:0 atIndex:1];
    [enc setBuffer:input_buffer offset:0 atIndex:2];
    [enc setBuffer:output_buffer offset:0 atIndex:3];
    [enc setBytes:&dims length:sizeof(dims) atIndex:4];

    const NSUInteger width = pipeline.threadExecutionWidth;
    [enc dispatchThreadgroups:MTLSizeMake(out_features, 1, 1)
         threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    observation->current_allocated_after =
        ctx->device.currentAllocatedSize;
    observation->gpu_start_time = cb.GPUStartTime;
    observation->gpu_end_time = cb.GPUEndTime;
    observation->command_status = (uint32_t)cb.status;
    if (cb.status != MTLCommandBufferStatusCompleted)
        return 5;
    return 0;
}

int glacier_metal_int4_registered_output_read(
    GlacierMetalContext* ctx,
    const GlacierMetalBufferToken* output_token,
    float* output,
    uint64_t output_count)
{
    if (!ctx || !ctx->device || !output_token || !output ||
        output_count == 0 ||
        output_count > UINT64_MAX / sizeof(float))
        return 1;
    const uint64_t output_bytes =
        output_count * sizeof(float);
    if (output_bytes > SIZE_MAX)
        return 1;

    id<MTLBuffer> output_buffer = nil;
    void* output_contents = NULL;
    @try {
        @synchronized (ctx->device) {
            GlacierMetalBufferAllocation* allocation =
                glacier_metal_buffer_exact_locked(
                    ctx, output_token, output_bytes);
            if (!allocation)
                return 2;
            output_buffer = allocation->buffer;
            output_contents = output_buffer.contents;
            if (!output_contents)
                return 2;
        }
    } @catch (NSException* exception) {
        (void)exception;
        return 2;
    }
    memcpy(output, output_contents, (size_t)output_bytes);
    return 0;
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
    if (!ctx || !ctx->device || !ctx->queue || !ctx->library ||
        !weight || !weight->packed ||
        !weight->scales || !weight->input || !weight->output || !input ||
        !output || input_count < weight->in_features ||
        output_count < weight->out_features)
        return 1;
    id<MTLComputePipelineState> pipeline =
        glacier_metal_get_int4_matvec_pipeline(ctx);
    if (!pipeline) return 1;

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
    [enc setComputePipelineState:pipeline];
    [enc setBuffer:weight->packed offset:0 atIndex:0];
    [enc setBuffer:weight->scales offset:0 atIndex:1];
    [enc setBuffer:weight->input offset:0 atIndex:2];
    [enc setBuffer:weight->output offset:0 atIndex:3];
    [enc setBytes:&dims length:sizeof(dims) atIndex:4];

    const NSUInteger width = pipeline.threadExecutionWidth;
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
    return 0;
}

int glacier_metal_int4_matvec_dispatch(
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
