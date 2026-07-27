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
#import <dispatch/dispatch.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define GLACIER_METAL_DEVICE_INFO_ABI 0x474d444900000001ULL
#define GLACIER_METAL_DISPATCH_ABI 0x474d445200000001ULL
#define GLACIER_METAL_ALLOCATION_LIMITS_ABI 0x474d414900000001ULL
#define GLACIER_METAL_BUFFER_INFO_ABI 0x474d424900000001ULL
#define GLACIER_METAL_ADAPTER_IDENTITY_ABI 0x474d414400000001ULL
#define GLACIER_METAL_ASYNC_SUBMISSION_ABI 0x474d415300000001ULL
#define GLACIER_METAL_ASYNC_COMPLETION_ABI 0x474d414300000001ULL
#define GLACIER_METAL_DEVICE_LIFECYCLE_ABI 0x474d444c00000001ULL
#define GLACIER_METAL_LIFECYCLE_SOURCE_IDENTITY_ABI \
    0x474d4c5300000001ULL
#define GLACIER_METAL_DISPATCH_RETIREMENT_PERMIT_ABI \
    0x474d525000000001ULL
#define GLACIER_METAL_DISPATCH_RETIREMENT_RECEIPT_ABI \
    0x474d525200000001ULL
#define GLACIER_METAL_DISPATCH_RETIREMENT_TELEMETRY_ABI \
    0x474d525400000001ULL

#define GLACIER_METAL_RETIREMENT_NATIVE_LOSS 1U
#define GLACIER_METAL_RETIREMENT_SYNTHETIC_TEST 2U

#define GLACIER_METAL_DEVICE_EVENT_INITIAL_MEMBERSHIP 1U
#define GLACIER_METAL_DEVICE_EVENT_ADDED 2U
#define GLACIER_METAL_DEVICE_EVENT_REMOVAL_REQUESTED 3U
#define GLACIER_METAL_DEVICE_EVENT_REMOVED 4U
#define GLACIER_METAL_DEVICE_EVENT_COMMAND_BUFFER_REMOVED 5U

#define GLACIER_METAL_DEVICE_SOURCE_INITIAL (1U << 0)
#define GLACIER_METAL_DEVICE_SOURCE_ADDED (1U << 1)
#define GLACIER_METAL_DEVICE_SOURCE_REMOVAL_REQUESTED (1U << 2)
#define GLACIER_METAL_DEVICE_SOURCE_REMOVED (1U << 3)
#define GLACIER_METAL_DEVICE_SOURCE_COMMAND_BUFFER_REMOVED (1U << 4)
#define GLACIER_METAL_DEVICE_SOURCE_ALL \
    (GLACIER_METAL_DEVICE_SOURCE_INITIAL | \
     GLACIER_METAL_DEVICE_SOURCE_ADDED | \
     GLACIER_METAL_DEVICE_SOURCE_REMOVAL_REQUESTED | \
     GLACIER_METAL_DEVICE_SOURCE_REMOVED | \
     GLACIER_METAL_DEVICE_SOURCE_COMMAND_BUFFER_REMOVED)

#define GLACIER_METAL_LIFECYCLE_CONSUME_INVALID 1
#define GLACIER_METAL_LIFECYCLE_CONSUME_UNAVAILABLE 2
#define GLACIER_METAL_LIFECYCLE_CONSUME_GENERATION_MISMATCH 3
#define GLACIER_METAL_LIFECYCLE_CONSUME_STALE 4

#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
#define GLACIER_METAL_TEST_FAULT_PLAN_ABI 0x474d465000000001ULL
#define GLACIER_METAL_TEST_COMPLETION_FACTS_ABI 0x474d464300000001ULL
#define GLACIER_METAL_TEST_COMPLETION_FACTS_V2_ABI \
    0x474d464300000002ULL
#define GLACIER_METAL_TEST_RETIREMENT_COMMIT_FACTS_ABI \
    0x474d524600000001ULL
#define GLACIER_METAL_TEST_COMPLETED_AS_COMMAND_ERROR 1U
#define GLACIER_METAL_TEST_REAL_COMMIT_AS_AMBIGUOUS 2U
#define GLACIER_METAL_TEST_COMPLETED_AS_UNKNOWN 3U
#define GLACIER_METAL_TEST_COMPLETED_OUTPUT_READ_REJECTION 4U
#endif

#define GLACIER_METAL_SUBMIT_SUBMITTED 1U
#define GLACIER_METAL_SUBMIT_SUBMITTED_OR_AMBIGUOUS 2U

#define GLACIER_METAL_COMMAND_PENDING 1U
#define GLACIER_METAL_COMMAND_COMPLETED 2U
#define GLACIER_METAL_COMMAND_ERROR 3U
#define GLACIER_METAL_COMMAND_UNKNOWN 4U

#define GLACIER_METAL_ERROR_DOMAIN_NONE 0U
#define GLACIER_METAL_ERROR_DOMAIN_COMMAND_BUFFER 1U
#define GLACIER_METAL_ERROR_DOMAIN_OTHER 2U

// Sticky per-counter saturation facts. Telemetry is diagnostic only: an
// exhausted counter freezes at UINT64_MAX and never blocks ownership
// retirement or receipt replay.
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SNAPSHOT_SEQUENCE \
    (1ULL << 0)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PREPARED \
    (1ULL << 1)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PREPARE_REPLAY \
    (1ULL << 2)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PREPARE_LIVE_REPLAY \
    (1ULL << 3)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PREPARE_TOMBSTONE_REPLAY \
    (1ULL << 4)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMMITTED \
    (1ULL << 5)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMMIT_REPLAY \
    (1ULL << 6)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_LIVE_PREPARED \
    (1ULL << 7)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_CALLBACK_DETACHED \
    (1ULL << 8)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMPLETION_UNOBSERVED \
    (1ULL << 9)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMPLETION_OBSERVED \
    (1ULL << 10)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PENDING \
    (1ULL << 11)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMPLETED \
    (1ULL << 12)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_ERROR \
    (1ULL << 13)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_UNKNOWN \
    (1ULL << 14)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SUBMITTED \
    (1ULL << 15)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SUBMITTED_OR_AMBIGUOUS \
    (1ULL << 16)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_NATIVE_LOSS \
    (1ULL << 17)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SYNTHETIC_TEST \
    (1ULL << 18)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_RETIRED_NATIVE_COMMAND \
    (1ULL << 19)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_RELEASED_ALLOCATION_REFERENCE \
    (1ULL << 20)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_RETAINED_TOMBSTONE \
    (1ULL << 21)
#define GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_ALL \
    ((1ULL << 22) - 1ULL)

typedef struct GlacierMetalBufferAllocation
    GlacierMetalBufferAllocation;
typedef struct GlacierMetalCommandRecord
    GlacierMetalCommandRecord;
typedef struct GlacierMetalCommandRetirementTombstone
    GlacierMetalCommandRetirementTombstone;
typedef struct GlacierMetalContext GlacierMetalContext;

// Copyable native token. It contains no pointer: the random context nonce
// rejects foreign contexts and the never-reused generation rejects stale
// copies after release.
typedef struct {
    uint64_t context_nonce[4];
    uint64_t generation;
} GlacierMetalBufferToken;

// A command token follows the same context-nonce and generation rules as a
// buffer token. It never embeds an Objective-C pointer.
typedef struct {
    uint64_t context_nonce[4];
    uint64_t generation;
} GlacierMetalCommandToken;

// Native ownership returned before the Objective-C commit boundary. A normal
// commit return is `SUBMITTED`; an exception after commit invocation is
// `SUBMITTED_OR_AMBIGUOUS`. Both dispositions retain the registry record.
typedef struct {
    uint64_t abi_version;
    GlacierMetalCommandToken token;
    uint8_t submission_binding[32];
    uint32_t disposition;
    uint32_t reserved;
} GlacierMetalAsyncSubmission;

// Stable snapshot copied by poll and wait. Pending and unknown states are not
// terminal authority. Error text is deliberately absent; only a stable domain
// classification and numeric code cross the C boundary.
typedef struct {
    uint64_t abi_version;
    GlacierMetalCommandToken token;
    uint8_t submission_binding[32];
    uint64_t current_allocated_before;
    uint64_t current_allocated_after;
    double gpu_start_time;
    double gpu_end_time;
    int64_t error_code;
    uint32_t state;
    uint32_t command_status;
    uint32_t error_domain_kind;
    uint32_t error_present;
    uint32_t callback_fault;
    uint32_t reserved;
} GlacierMetalAsyncCompletion;

// Pointer-free, level-triggered lifecycle facts for the exact selected device.
// Removal flags are monotonic for one observer generation; this observation
// does not itself authorize resource release or device migration.
typedef struct {
    uint64_t abi_version;
    uint64_t registry_id;
    uint64_t observer_generation;
    uint64_t event_sequence;
    uint32_t event_kind;
    uint32_t present;
    uint32_t removal_requested;
    uint32_t removed;
    uint32_t observer_active;
    uint32_t initial_membership;
    uint32_t observer_fault;
    uint32_t source_bits;
} GlacierMetalDeviceLifecycle;

// Immutable per-context source identity. The 256-bit context nonce provides
// restart freshness beyond the u64 observer-generation reset discriminator.
typedef struct {
    uint64_t abi_version;
    uint64_t registry_id;
    uint64_t observer_generation;
    uint64_t context_nonce[4];
} GlacierMetalDeviceLifecycleSourceIdentity;

// Pointer-free authorization retained between pre-Bank validation and
// post-Bank native ownership retirement. Callback detachment freezes the raw
// native projection without claiming command completion or output validity.
typedef struct {
    uint64_t abi_version;
    GlacierMetalCommandToken token;
    uint8_t submission_binding[32];
    uint64_t retirement_generation;
    GlacierMetalDeviceLifecycleSourceIdentity source_identity;
    uint64_t minimum_event_sequence;
    int64_t error_code;
    uint32_t authorization_kind;
    uint32_t submission_disposition;
    uint32_t native_state;
    uint32_t command_status;
    uint32_t completion_observed;
    uint32_t error_domain_kind;
    uint32_t error_present;
    uint32_t callback_fault;
    uint32_t commit_invoked;
    uint32_t callback_detached;
    uint32_t reserved0;
    uint32_t reserved1;
} GlacierMetalDispatchRetirementPermit;

// Exact replay receipt for one unlinked command record and its four released
// registry references. It is ownership evidence, never completion evidence.
typedef struct {
    uint64_t abi_version;
    GlacierMetalDispatchRetirementPermit permit;
    uint64_t retired_native_command_count;
    uint64_t released_allocation_reference_count;
    int64_t error_code;
    uint32_t completion_observed;
    uint32_t native_state;
    uint32_t command_status;
    uint32_t error_domain_kind;
    uint32_t error_present;
    uint32_t callback_fault;
    uint32_t callback_detached;
    uint32_t reserved;
} GlacierMetalDispatchRetirementReceipt;

// Context-lifetime, pointer-free operational telemetry. State, disposition,
// completion-observation, and authorization buckets freeze the exact native
// permit projection once per unique prepare. They are not completion or
// output authority and never enter a Phase-B permit, receipt, or evidence
// digest.
typedef struct {
    uint64_t abi_version;
    uint64_t device_registry_id;
    uint64_t context_nonce[4];
    uint64_t snapshot_sequence;
    uint64_t prepared_retirement_count;
    uint64_t prepare_replay_count;
    uint64_t prepare_live_record_replay_count;
    uint64_t prepare_tombstone_replay_count;
    uint64_t committed_retirement_count;
    uint64_t commit_replay_count;
    uint64_t live_prepared_retirement_count;
    uint64_t callback_detached_count;
    uint64_t completion_unobserved_prepare_count;
    uint64_t completion_observed_prepare_count;
    uint64_t pending_prepare_count;
    uint64_t completed_prepare_count;
    uint64_t error_prepare_count;
    uint64_t unknown_prepare_count;
    uint64_t submitted_prepare_count;
    uint64_t submitted_or_ambiguous_prepare_count;
    uint64_t native_loss_prepare_count;
    uint64_t synthetic_test_prepare_count;
    uint64_t retired_native_command_count;
    uint64_t released_allocation_reference_count;
    uint64_t retained_tombstone_count;
    uint64_t highest_prepared_retirement_generation;
    uint64_t highest_committed_retirement_generation;
    uint64_t overflow_mask;
    uint64_t reserved;
} GlacierMetalDispatchRetirementTelemetryV1;

// The Metal notification block captures this ARC-owned object and never the
// malloc-owned GlacierMetalContext. MTLRemoveDeviceObserver releases the block
// before the context drops its final state reference.
@interface GlacierMetalDeviceLifecycleState : NSObject {
@public
    GlacierMetalDeviceLifecycle snapshot;
    uint64_t active_admissions;
    uint64_t last_consumed_event_sequence;
}
@end

@implementation GlacierMetalDeviceLifecycleState
@end

// Every command completion block captures this ARC-owned gate rather than the
// malloc-owned context. `owner` is read only while holding the gate monitor.
// Retirement detaches it before returning, so a late callback can only leave
// its publication group and cannot dereference freed registry state.
@interface GlacierMetalCommandCallbackGate : NSObject {
@public
    GlacierMetalContext* owner;
}
@end

@implementation GlacierMetalCommandCallbackGate
@end

#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
// Build-isolated test authority. This ABI is compiled only into the
// non-installed fault shim and never enters a production header or library.
typedef struct {
    uint64_t abi_version;
    uint64_t plan_generation;
    uint32_t kind;
    uint32_t reserved;
    int64_t injected_error_code;
} GlacierMetalTestFaultPlanV1;

// Original completion-only fault facts retained byte-for-byte for the V1
// test ABI.
typedef struct {
    uint64_t abi_version;
    uint64_t plan_generation;
    uint32_t kind;
    uint32_t fault_applied;
    int64_t injected_error_code;
    GlacierMetalAsyncCompletion physical;
    GlacierMetalAsyncCompletion published;
} GlacierMetalTestCompletionFactsV1;

// V2 adds physical/published submission facts and explicit staged fault
// actions. Submission facts are ready when the native commit boundary
// returns; completion facts remain zero until callback publication.
typedef struct {
    uint64_t abi_version;
    uint64_t plan_generation;
    uint32_t kind;
    uint32_t fault_applied;
    int64_t injected_error_code;
    GlacierMetalAsyncCompletion physical;
    GlacierMetalAsyncCompletion published;
    GlacierMetalAsyncSubmission physical_submission;
    GlacierMetalAsyncSubmission published_submission;
    uint32_t commit_returned_normally;
    uint32_t commit_exception_observed;
    uint32_t submission_overlay_applied;
    uint32_t callback_snapshot_observed;
    uint32_t completion_overlay_applied;
    uint32_t output_read_rejection_applied;
    uint64_t output_read_rejection_count;
} GlacierMetalTestCompletionFactsV2;

// Test-only counters for the exact pre-unlink retirement commit boundary.
// The one-shot fault is consumed only after all fallible validation and
// tombstone allocation have completed, while the command record and its four
// allocation references are still live.
typedef struct {
    uint64_t abi_version;
    uint64_t commit_attempt_count;
    uint64_t injected_failure_count;
    uint64_t committed_retirement_count;
    uint64_t replay_count;
    uint32_t failure_armed;
    uint32_t reserved;
} GlacierMetalTestRetirementCommitFactsV1;

// Deterministic late-callback control for the private fault shim. The
// completion block captures this ARC object, so retirement may destroy the
// native command record while the callback is held without retaining or
// dereferencing the malloc-owned context.
@interface GlacierMetalTestCallbackHold : NSObject {
@public
    dispatch_semaphore_t release_semaphore;
    dispatch_group_t entered_group;
    dispatch_group_t exited_group;
    dispatch_group_t registered_waiter_entered_group;
    uint32_t entered_published;
    uint32_t released;
    uint32_t exited_published;
    uint32_t registered_waiter_entered_published;
}
@end

@implementation GlacierMetalTestCallbackHold
@end
#endif

// Opaque handle returned to Zig. The Zig side treats it as *anyopaque.
struct GlacierMetalContext {
    id<MTLDevice>       device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary>      library;
    id<MTLComputePipelineState> dequant_pipeline;
    id<MTLComputePipelineState> matmul_pipeline;
    id<MTLComputePipelineState> int4_matvec_pipeline;
    id<NSObject> device_lifecycle_observer;
    GlacierMetalDeviceLifecycleState* device_lifecycle_state;
    GlacierMetalBufferAllocation* buffer_allocations;
    GlacierMetalCommandRecord* command_records;
    GlacierMetalCommandRetirementTombstone*
        command_retirement_tombstones;
    uint64_t allocation_context_nonce[4];
    uint64_t next_allocation_adapter_instance;
    uint64_t next_buffer_generation;
    uint64_t next_command_generation;
    uint64_t next_command_retirement_generation;
    uint64_t live_buffer_allocations;
    uint64_t live_command_records;
    GlacierMetalDispatchRetirementTelemetryV1
        dispatch_retirement_telemetry;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    uint64_t next_test_fault_plan_generation;
    GlacierMetalTestFaultPlanV1 armed_test_fault_plan;
    uint32_t test_fault_plan_armed;
    GlacierMetalTestCallbackHold* test_active_callback_hold;
    uint32_t test_callback_hold_armed;
    uint64_t test_retirement_commit_attempt_count;
    uint64_t test_retirement_commit_injected_failure_count;
    uint64_t test_retirement_committed_count;
    uint64_t test_retirement_commit_replay_count;
    uint32_t test_retirement_commit_failure_armed;
#endif
};

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
    uint64_t active_command_references;
};

// Context-owned command state. The registry and every referenced allocation
// are mutated under @synchronized(ctx->device). Strong references remain here
// until a caller presents the exact terminal snapshot to finalize.
struct GlacierMetalCommandRecord {
    GlacierMetalContext* owner;
    GlacierMetalCommandRecord* next;
    GlacierMetalCommandToken token;
    uint8_t submission_binding[32];
    // Native-retained publication state. Retirement authenticates this field
    // instead of trusting a caller-supplied disposition for the same token.
    uint32_t submission_disposition;
    id<MTLCommandBuffer> command_buffer;
    id<MTLBuffer> packed;
    id<MTLBuffer> scales;
    id<MTLBuffer> input;
    id<MTLBuffer> output;
    dispatch_group_t completion_publication;
    GlacierMetalCommandCallbackGate* callback_gate;
    GlacierMetalBufferAllocation* allocations[4];
    uint64_t current_allocated_before;
    uint64_t current_allocated_after;
    double gpu_start_time;
    double gpu_end_time;
    int64_t error_code;
    uint32_t command_status;
    uint32_t error_domain_kind;
    uint32_t error_present;
    uint32_t callback_fault;
    uint32_t completion_observed;
    uint32_t commit_invoked;
    GlacierMetalDispatchRetirementPermit retirement_permit;
    uint32_t retirement_armed;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    GlacierMetalTestFaultPlanV1 test_fault_plan;
    GlacierMetalTestCompletionFactsV2 test_completion_facts;
    uint32_t test_completion_facts_ready;
    GlacierMetalTestCallbackHold* test_callback_hold;
#endif
};

struct GlacierMetalCommandRetirementTombstone {
    GlacierMetalCommandRetirementTombstone* next;
    GlacierMetalDispatchRetirementPermit permit;
    GlacierMetalDispatchRetirementReceipt receipt;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    GlacierMetalTestCompletionFactsV2 test_completion_facts;
    uint32_t test_completion_facts_ready;
#endif
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
_Static_assert(sizeof(GlacierMetalCommandToken) == 40,
    "GlacierMetalCommandToken ABI size changed");
_Static_assert(offsetof(GlacierMetalCommandToken, generation) == 32,
    "GlacierMetalCommandToken generation offset changed");
_Static_assert(sizeof(GlacierMetalAsyncSubmission) == 88,
    "GlacierMetalAsyncSubmission ABI size changed");
_Static_assert(offsetof(GlacierMetalAsyncSubmission, disposition) == 80,
    "GlacierMetalAsyncSubmission disposition offset changed");
_Static_assert(sizeof(GlacierMetalAsyncCompletion) == 144,
    "GlacierMetalAsyncCompletion ABI size changed");
_Static_assert(offsetof(GlacierMetalAsyncCompletion, gpu_start_time) == 96,
    "GlacierMetalAsyncCompletion timestamp offset changed");
_Static_assert(offsetof(GlacierMetalAsyncCompletion, state) == 120,
    "GlacierMetalAsyncCompletion state offset changed");
_Static_assert(sizeof(GlacierMetalDeviceLifecycle) == 64,
    "GlacierMetalDeviceLifecycle ABI size changed");
_Static_assert(offsetof(
        GlacierMetalDeviceLifecycle,
        registry_id) == 8,
    "GlacierMetalDeviceLifecycle registry offset changed");
_Static_assert(offsetof(
        GlacierMetalDeviceLifecycle,
        event_sequence) == 24,
    "GlacierMetalDeviceLifecycle sequence offset changed");
_Static_assert(offsetof(
        GlacierMetalDeviceLifecycle,
        event_kind) == 32,
    "GlacierMetalDeviceLifecycle event offset changed");
_Static_assert(offsetof(
        GlacierMetalDeviceLifecycle,
        source_bits) == 60,
    "GlacierMetalDeviceLifecycle source-bits offset changed");
_Static_assert(
    sizeof(GlacierMetalDeviceLifecycleSourceIdentity) == 56,
    "GlacierMetalDeviceLifecycleSourceIdentity ABI size changed");
_Static_assert(offsetof(
        GlacierMetalDeviceLifecycleSourceIdentity,
        context_nonce) == 24,
    "GlacierMetalDeviceLifecycleSourceIdentity nonce offset changed");
_Static_assert(sizeof(GlacierMetalDispatchRetirementPermit) == 208,
    "GlacierMetalDispatchRetirementPermit ABI size changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementPermit,
        retirement_generation) == 80,
    "GlacierMetalDispatchRetirementPermit generation offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementPermit,
        source_identity) == 88,
    "GlacierMetalDispatchRetirementPermit source offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementPermit,
        error_code) == 152,
    "GlacierMetalDispatchRetirementPermit error offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementPermit,
        authorization_kind) == 160,
    "GlacierMetalDispatchRetirementPermit authorization offset changed");
_Static_assert(sizeof(GlacierMetalDispatchRetirementReceipt) == 272,
    "GlacierMetalDispatchRetirementReceipt ABI size changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementReceipt,
        permit) == 8,
    "GlacierMetalDispatchRetirementReceipt permit offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementReceipt,
        retired_native_command_count) == 216,
    "GlacierMetalDispatchRetirementReceipt count offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementReceipt,
        error_code) == 232,
    "GlacierMetalDispatchRetirementReceipt error offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementReceipt,
        completion_observed) == 240,
    "GlacierMetalDispatchRetirementReceipt state offset changed");
_Static_assert(
    sizeof(GlacierMetalDispatchRetirementTelemetryV1) == 256,
    "GlacierMetalDispatchRetirementTelemetryV1 ABI size changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        device_registry_id) == 8,
    "GlacierMetalDispatchRetirementTelemetryV1 registry offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        context_nonce) == 16,
    "GlacierMetalDispatchRetirementTelemetryV1 nonce offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        snapshot_sequence) == 48,
    "GlacierMetalDispatchRetirementTelemetryV1 sequence offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        prepared_retirement_count) == 56,
    "GlacierMetalDispatchRetirementTelemetryV1 prepare offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        committed_retirement_count) == 88,
    "GlacierMetalDispatchRetirementTelemetryV1 commit offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        pending_prepare_count) == 136,
    "GlacierMetalDispatchRetirementTelemetryV1 state offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        submitted_prepare_count) == 168,
    "GlacierMetalDispatchRetirementTelemetryV1 disposition offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        native_loss_prepare_count) == 184,
    "GlacierMetalDispatchRetirementTelemetryV1 authorization offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        retired_native_command_count) == 200,
    "GlacierMetalDispatchRetirementTelemetryV1 ownership offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        highest_prepared_retirement_generation) == 224,
    "GlacierMetalDispatchRetirementTelemetryV1 generation offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        overflow_mask) == 240,
    "GlacierMetalDispatchRetirementTelemetryV1 overflow offset changed");
_Static_assert(offsetof(
        GlacierMetalDispatchRetirementTelemetryV1,
        reserved) == 248,
    "GlacierMetalDispatchRetirementTelemetryV1 reserved offset changed");
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
_Static_assert(sizeof(GlacierMetalTestFaultPlanV1) == 32,
    "GlacierMetalTestFaultPlanV1 ABI size changed");
_Static_assert(offsetof(
        GlacierMetalTestFaultPlanV1,
        injected_error_code) == 24,
    "GlacierMetalTestFaultPlanV1 error offset changed");
_Static_assert(sizeof(GlacierMetalTestCompletionFactsV1) == 320,
    "GlacierMetalTestCompletionFactsV1 ABI size changed");
_Static_assert(offsetof(
        GlacierMetalTestCompletionFactsV1,
        physical) == 32,
    "GlacierMetalTestCompletionFactsV1 physical offset changed");
_Static_assert(offsetof(
        GlacierMetalTestCompletionFactsV1,
        published) == 176,
    "GlacierMetalTestCompletionFactsV1 published offset changed");
_Static_assert(sizeof(GlacierMetalTestCompletionFactsV2) == 528,
    "GlacierMetalTestCompletionFactsV2 ABI size changed");
_Static_assert(offsetof(
        GlacierMetalTestCompletionFactsV2,
        physical) == 32,
    "GlacierMetalTestCompletionFactsV2 physical offset changed");
_Static_assert(offsetof(
        GlacierMetalTestCompletionFactsV2,
        published) == 176,
    "GlacierMetalTestCompletionFactsV2 published offset changed");
_Static_assert(offsetof(
        GlacierMetalTestCompletionFactsV2,
        physical_submission) == 320,
    "GlacierMetalTestCompletionFactsV2 submission offset changed");
_Static_assert(offsetof(
        GlacierMetalTestCompletionFactsV2,
        commit_returned_normally) == 496,
    "GlacierMetalTestCompletionFactsV2 stage offset changed");
_Static_assert(offsetof(
        GlacierMetalTestCompletionFactsV2,
        output_read_rejection_count) == 520,
    "GlacierMetalTestCompletionFactsV2 rejection offset changed");
_Static_assert(sizeof(GlacierMetalTestRetirementCommitFactsV1) == 48,
    "GlacierMetalTestRetirementCommitFactsV1 ABI size changed");
_Static_assert(offsetof(
        GlacierMetalTestRetirementCommitFactsV1,
        failure_armed) == 40,
    "GlacierMetalTestRetirementCommitFactsV1 armed offset changed");

static GlacierMetalTestCallbackHold*
glacier_metal_test_callback_hold_create(void)
{
    GlacierMetalTestCallbackHold* hold =
        [[GlacierMetalTestCallbackHold alloc] init];
    if (!hold) return nil;
    hold->release_semaphore = dispatch_semaphore_create(0);
    hold->entered_group = dispatch_group_create();
    hold->exited_group = dispatch_group_create();
    hold->registered_waiter_entered_group =
        dispatch_group_create();
    if (!hold->release_semaphore ||
        !hold->entered_group ||
        !hold->exited_group ||
        !hold->registered_waiter_entered_group)
        return nil;
    dispatch_group_enter(hold->entered_group);
    dispatch_group_enter(hold->exited_group);
    dispatch_group_enter(
        hold->registered_waiter_entered_group);
    return hold;
}

static void glacier_metal_test_callback_hold_publish_entered(
    GlacierMetalTestCallbackHold* hold)
{
    if (!hold) return;
    @synchronized (hold) {
        if (hold->entered_published == 0) {
            hold->entered_published = 1;
            dispatch_group_leave(hold->entered_group);
        }
    }
}

static void glacier_metal_test_callback_hold_release(
    GlacierMetalTestCallbackHold* hold)
{
    if (!hold) return;
    @synchronized (hold) {
        if (hold->released == 0) {
            hold->released = 1;
            dispatch_semaphore_signal(
                hold->release_semaphore);
        }
    }
}

static void glacier_metal_test_callback_hold_publish_exited(
    GlacierMetalTestCallbackHold* hold)
{
    if (!hold) return;
    @synchronized (hold) {
        if (hold->exited_published == 0) {
            hold->exited_published = 1;
            dispatch_group_leave(hold->exited_group);
        }
    }
}

static void
glacier_metal_test_callback_hold_publish_registered_waiter_entered(
    GlacierMetalTestCallbackHold* hold)
{
    if (!hold) return;
    @synchronized (hold) {
        if (hold->registered_waiter_entered_published == 0) {
            hold->registered_waiter_entered_published = 1;
            dispatch_group_leave(
                hold->registered_waiter_entered_group);
        }
    }
}

static void glacier_metal_test_callback_hold_cancel(
    GlacierMetalTestCallbackHold* hold)
{
    glacier_metal_test_callback_hold_publish_entered(hold);
    glacier_metal_test_callback_hold_release(hold);
    glacier_metal_test_callback_hold_publish_exited(hold);
}
#endif

static int glacier_metal_nonce_is_zero(const uint64_t nonce[4]) {
    return nonce[0] == 0 && nonce[1] == 0 &&
        nonce[2] == 0 && nonce[3] == 0;
}

static int glacier_metal_binding_is_zero(const uint8_t binding[32]) {
    uint8_t combined = 0;
    for (size_t index = 0; index < 32; index += 1)
        combined |= binding[index];
    return combined == 0;
}

static int glacier_metal_command_token_valid(
    const GlacierMetalCommandToken* token)
{
    return token &&
        token->generation != 0 &&
        !glacier_metal_nonce_is_zero(token->context_nonce);
}

static int glacier_metal_submission_disposition_valid(
    uint32_t disposition)
{
    return disposition == GLACIER_METAL_SUBMIT_SUBMITTED ||
        disposition ==
            GLACIER_METAL_SUBMIT_SUBMITTED_OR_AMBIGUOUS;
}

static int glacier_metal_async_submission_valid(
    const GlacierMetalAsyncSubmission* submission)
{
    return submission &&
        submission->abi_version ==
            GLACIER_METAL_ASYNC_SUBMISSION_ABI &&
        glacier_metal_command_token_valid(&submission->token) &&
        !glacier_metal_binding_is_zero(
            submission->submission_binding) &&
        glacier_metal_submission_disposition_valid(
            submission->disposition) &&
        submission->reserved == 0;
}

static int glacier_metal_lifecycle_source_identity_valid(
    const GlacierMetalDeviceLifecycleSourceIdentity* source)
{
    return source &&
        source->abi_version ==
            GLACIER_METAL_LIFECYCLE_SOURCE_IDENTITY_ABI &&
        source->registry_id != 0 &&
        source->observer_generation != 0 &&
        !glacier_metal_nonce_is_zero(source->context_nonce);
}

static int glacier_metal_lifecycle_source_identity_zero(
    const GlacierMetalDeviceLifecycleSourceIdentity* source)
{
    if (!source) return 0;
    const GlacierMetalDeviceLifecycleSourceIdentity zero = {0};
    return memcmp(source, &zero, sizeof(zero)) == 0;
}

static int glacier_metal_dispatch_retirement_permit_valid(
    const GlacierMetalDispatchRetirementPermit* permit)
{
    if (!permit ||
        permit->abi_version !=
            GLACIER_METAL_DISPATCH_RETIREMENT_PERMIT_ABI ||
        !glacier_metal_command_token_valid(&permit->token) ||
        glacier_metal_binding_is_zero(
            permit->submission_binding) ||
        permit->retirement_generation == 0 ||
        permit->retirement_generation == UINT64_MAX ||
        (permit->submission_disposition !=
                GLACIER_METAL_SUBMIT_SUBMITTED &&
            permit->submission_disposition !=
                GLACIER_METAL_SUBMIT_SUBMITTED_OR_AMBIGUOUS) ||
        (permit->native_state < GLACIER_METAL_COMMAND_PENDING ||
            permit->native_state >
                GLACIER_METAL_COMMAND_UNKNOWN) ||
        permit->completion_observed > 1 ||
        permit->error_domain_kind >
            GLACIER_METAL_ERROR_DOMAIN_OTHER ||
        permit->error_present > 1 ||
        permit->callback_fault > 1 ||
        permit->commit_invoked != 1 ||
        permit->callback_detached != 1 ||
        permit->reserved0 != 0 ||
        permit->reserved1 != 0)
        return 0;

    if ((permit->error_present == 0 &&
            (permit->error_domain_kind !=
                    GLACIER_METAL_ERROR_DOMAIN_NONE ||
                permit->error_code != 0)) ||
        (permit->error_present == 1 &&
            (permit->error_domain_kind ==
                    GLACIER_METAL_ERROR_DOMAIN_NONE ||
                permit->error_code == 0)))
        return 0;

    if (permit->completion_observed == 0 &&
        (permit->native_state !=
                GLACIER_METAL_COMMAND_PENDING ||
            permit->command_status != 0 ||
            permit->error_code != 0 ||
            permit->error_domain_kind !=
                GLACIER_METAL_ERROR_DOMAIN_NONE ||
            permit->error_present != 0 ||
            permit->callback_fault != 0))
        return 0;
    if (permit->completion_observed != 0) {
        switch (permit->native_state) {
            case GLACIER_METAL_COMMAND_COMPLETED:
                if (permit->command_status !=
                        MTLCommandBufferStatusCompleted ||
                    permit->callback_fault != 0 ||
                    permit->error_present != 0)
                    return 0;
                break;
            case GLACIER_METAL_COMMAND_ERROR:
                if (permit->command_status !=
                        MTLCommandBufferStatusError ||
                    permit->callback_fault != 0)
                    return 0;
                break;
            case GLACIER_METAL_COMMAND_UNKNOWN:
                if (permit->callback_fault == 0 &&
                    (permit->command_status ==
                            MTLCommandBufferStatusCompleted ||
                        permit->command_status ==
                            MTLCommandBufferStatusError))
                    return 0;
                break;
            case GLACIER_METAL_COMMAND_PENDING:
            default:
                return 0;
        }
    }

    switch (permit->authorization_kind) {
        case GLACIER_METAL_RETIREMENT_NATIVE_LOSS:
            return permit->minimum_event_sequence != 0 &&
                glacier_metal_lifecycle_source_identity_valid(
                    &permit->source_identity);
        case GLACIER_METAL_RETIREMENT_SYNTHETIC_TEST:
            return permit->minimum_event_sequence == 0 &&
                glacier_metal_lifecycle_source_identity_zero(
                    &permit->source_identity);
        default:
            return 0;
    }
}

static uint64_t glacier_metal_reserve_device_lifecycle_generation(void) {
    uint64_t result = 0;
    do {
        arc4random_buf(&result, sizeof(result));
    } while (result == 0 || result == UINT64_MAX);
    return result;
}

static uint32_t glacier_metal_device_lifecycle_source_for_event(
    uint32_t event_kind)
{
    switch (event_kind) {
        case GLACIER_METAL_DEVICE_EVENT_INITIAL_MEMBERSHIP:
            return GLACIER_METAL_DEVICE_SOURCE_INITIAL;
        case GLACIER_METAL_DEVICE_EVENT_ADDED:
            return GLACIER_METAL_DEVICE_SOURCE_ADDED;
        case GLACIER_METAL_DEVICE_EVENT_REMOVAL_REQUESTED:
            return GLACIER_METAL_DEVICE_SOURCE_REMOVAL_REQUESTED;
        case GLACIER_METAL_DEVICE_EVENT_REMOVED:
            return GLACIER_METAL_DEVICE_SOURCE_REMOVED;
        case GLACIER_METAL_DEVICE_EVENT_COMMAND_BUFFER_REMOVED:
            return
                GLACIER_METAL_DEVICE_SOURCE_COMMAND_BUFFER_REMOVED;
        default:
            return 0;
    }
}

// Source bits are sticky within one observer generation. The effective kind
// therefore comes from the strongest source ever observed, not necessarily
// the most recent notification retained in event_kind.
static uint32_t glacier_metal_device_lifecycle_effective_kind(
    const GlacierMetalDeviceLifecycle* lifecycle)
{
    if (!lifecycle) return 0;
    const uint32_t bits = lifecycle->source_bits;
    if (bits &
        GLACIER_METAL_DEVICE_SOURCE_COMMAND_BUFFER_REMOVED)
        return
            GLACIER_METAL_DEVICE_EVENT_COMMAND_BUFFER_REMOVED;
    if (bits & GLACIER_METAL_DEVICE_SOURCE_REMOVED)
        return GLACIER_METAL_DEVICE_EVENT_REMOVED;
    if (bits & GLACIER_METAL_DEVICE_SOURCE_REMOVAL_REQUESTED)
        return GLACIER_METAL_DEVICE_EVENT_REMOVAL_REQUESTED;
    if (bits & GLACIER_METAL_DEVICE_SOURCE_ADDED)
        return GLACIER_METAL_DEVICE_EVENT_ADDED;
    if (bits & GLACIER_METAL_DEVICE_SOURCE_INITIAL)
        return GLACIER_METAL_DEVICE_EVENT_INITIAL_MEMBERSHIP;
    return 0;
}

static void glacier_metal_device_lifecycle_apply_effective_state(
    GlacierMetalDeviceLifecycle* lifecycle)
{
    if (!lifecycle) return;
    switch (glacier_metal_device_lifecycle_effective_kind(
        lifecycle))
    {
        case GLACIER_METAL_DEVICE_EVENT_INITIAL_MEMBERSHIP:
        case GLACIER_METAL_DEVICE_EVENT_ADDED:
            lifecycle->present = 1;
            lifecycle->removal_requested = 0;
            lifecycle->removed = 0;
            break;
        case GLACIER_METAL_DEVICE_EVENT_REMOVAL_REQUESTED:
            lifecycle->present = 0;
            lifecycle->removal_requested = 1;
            lifecycle->removed = 0;
            break;
        case GLACIER_METAL_DEVICE_EVENT_REMOVED:
        case GLACIER_METAL_DEVICE_EVENT_COMMAND_BUFFER_REMOVED:
            lifecycle->present = 0;
            lifecycle->removal_requested = 1;
            lifecycle->removed = 1;
            break;
        default:
            lifecycle->observer_fault = 1;
            lifecycle->present = 0;
            lifecycle->removal_requested = 1;
            lifecycle->removed = 1;
            break;
    }
}

static int glacier_metal_device_lifecycle_shape_valid(
    const GlacierMetalDeviceLifecycle* lifecycle)
{
    if (!lifecycle ||
        lifecycle->abi_version !=
            GLACIER_METAL_DEVICE_LIFECYCLE_ABI ||
        lifecycle->registry_id == 0 ||
        lifecycle->observer_generation == 0 ||
        lifecycle->event_sequence == 0 ||
        lifecycle->present > 1 ||
        lifecycle->removal_requested > 1 ||
        lifecycle->removed > 1 ||
        lifecycle->observer_active > 1 ||
        lifecycle->initial_membership != 1 ||
        lifecycle->observer_fault > 1 ||
        lifecycle->source_bits == 0 ||
        (lifecycle->source_bits &
            ~GLACIER_METAL_DEVICE_SOURCE_ALL) != 0 ||
        (lifecycle->source_bits &
            GLACIER_METAL_DEVICE_SOURCE_INITIAL) == 0)
        return 0;

    const uint32_t latest_source =
        glacier_metal_device_lifecycle_source_for_event(
            lifecycle->event_kind);
    if (latest_source == 0 ||
        (lifecycle->source_bits & latest_source) == 0)
        return 0;

    switch (glacier_metal_device_lifecycle_effective_kind(
        lifecycle))
    {
        case GLACIER_METAL_DEVICE_EVENT_INITIAL_MEMBERSHIP:
        case GLACIER_METAL_DEVICE_EVENT_ADDED:
            return lifecycle->present == 1 &&
                lifecycle->removal_requested == 0 &&
                lifecycle->removed == 0;
        case GLACIER_METAL_DEVICE_EVENT_REMOVAL_REQUESTED:
            return lifecycle->present == 0 &&
                lifecycle->removal_requested == 1 &&
                lifecycle->removed == 0;
        case GLACIER_METAL_DEVICE_EVENT_REMOVED:
        case GLACIER_METAL_DEVICE_EVENT_COMMAND_BUFFER_REMOVED:
            return lifecycle->present == 0 &&
                lifecycle->removal_requested == 1 &&
                lifecycle->removed == 1;
        default:
            return 0;
    }
}

// Validate and release the lifecycle-state monitor before any callback gate or
// device registry monitor is acquired. Sticky loss is monotone for one source,
// so this avoids the device -> lifecycle order used by completion publication
// without weakening the retirement fence.
static int glacier_metal_exact_sticky_native_loss(
    GlacierMetalContext* ctx,
    const GlacierMetalDeviceLifecycleSourceIdentity* source,
    uint64_t minimum_event_sequence)
{
    if (!ctx ||
        !glacier_metal_lifecycle_source_identity_valid(source) ||
        minimum_event_sequence == 0 ||
        memcmp(
            source->context_nonce,
            ctx->allocation_context_nonce,
            sizeof(source->context_nonce)) != 0)
        return 0;
    GlacierMetalDeviceLifecycleState* state =
        ctx->device_lifecycle_state;
    if (!state) return 0;

    int valid = 0;
    @synchronized (state) {
        const GlacierMetalDeviceLifecycle* current =
            &state->snapshot;
        const uint32_t effective_kind =
            glacier_metal_device_lifecycle_effective_kind(
                current);
        valid =
            current->observer_active == 1 &&
            current->observer_fault == 0 &&
            glacier_metal_device_lifecycle_shape_valid(current) &&
            current->registry_id == source->registry_id &&
            current->observer_generation ==
                source->observer_generation &&
            current->event_sequence >= minimum_event_sequence &&
            (effective_kind ==
                    GLACIER_METAL_DEVICE_EVENT_REMOVED ||
                effective_kind ==
                    GLACIER_METAL_DEVICE_EVENT_COMMAND_BUFFER_REMOVED);
    }
    return valid;
}

// Reserved for lifecycle observer installation/callback integrity failures.
// Operational Metal exceptions have their own return or callback-fault fields
// and must never poison an already valid lifecycle source.
static void glacier_metal_device_lifecycle_observer_fault(
    GlacierMetalDeviceLifecycleState* state)
{
    if (!state) return;
    @synchronized (state) {
        if (state->snapshot.observer_active != 0)
            state->snapshot.observer_fault = 1;
    }
}

// Admission linearizes under the lifecycle-state monitor and releases it
// before any context registry lock, pipeline compilation, command commit, or
// Metal wait. Work already admitted may settle after a later removal event.
static int glacier_metal_device_lifecycle_begin_admission(
    GlacierMetalContext* ctx)
{
    if (!ctx) return 1;
    GlacierMetalDeviceLifecycleState* state =
        ctx->device_lifecycle_state;
    if (!state) return 1;

    int result = 1;
    @synchronized (state) {
        GlacierMetalDeviceLifecycle* lifecycle = &state->snapshot;
        const uint32_t effective_kind =
            glacier_metal_device_lifecycle_effective_kind(
                lifecycle);
        if (lifecycle->observer_active != 1 ||
            lifecycle->observer_fault != 0 ||
            !glacier_metal_device_lifecycle_shape_valid(
                lifecycle) ||
            (effective_kind !=
                GLACIER_METAL_DEVICE_EVENT_INITIAL_MEMBERSHIP &&
             effective_kind !=
                GLACIER_METAL_DEVICE_EVENT_ADDED))
        {
            result = 1;
        } else if (state->active_admissions == UINT64_MAX) {
            lifecycle->observer_fault = 1;
            result = 1;
        } else {
            state->active_admissions += 1;
            result = 0;
        }
    }
    return result;
}

static void glacier_metal_device_lifecycle_end_admission(
    GlacierMetalContext* ctx)
{
    if (!ctx) return;
    GlacierMetalDeviceLifecycleState* state =
        ctx->device_lifecycle_state;
    if (!state) return;
    @synchronized (state) {
        if (state->active_admissions == 0) {
            state->snapshot.observer_fault = 1;
            return;
        }
        state->active_admissions -= 1;
    }
}

static void glacier_metal_device_lifecycle_event(
    GlacierMetalDeviceLifecycleState* state,
    id<MTLDevice> device,
    MTLDeviceNotificationName name)
{
    if (!state) return;
    if (!device || !name) {
        glacier_metal_device_lifecycle_observer_fault(state);
        return;
    }

    uint64_t registry_id = 0;
    uint32_t event_kind = 0;
    int callback_valid = 1;
    @try {
        if (![device
                respondsToSelector:@selector(registryID)])
            callback_valid = 0;
        else
            registry_id = device.registryID;
        if (callback_valid) {
            if ([name
                    isEqualToString:MTLDeviceWasAddedNotification])
                event_kind = GLACIER_METAL_DEVICE_EVENT_ADDED;
            else if ([name isEqualToString:
                    MTLDeviceRemovalRequestedNotification])
                event_kind =
                    GLACIER_METAL_DEVICE_EVENT_REMOVAL_REQUESTED;
            else if ([name isEqualToString:
                    MTLDeviceWasRemovedNotification])
                event_kind =
                    GLACIER_METAL_DEVICE_EVENT_REMOVED;
            else
                callback_valid = 0;
        }
    } @catch (NSException* exception) {
        (void)exception;
        callback_valid = 0;
    }
    if (!callback_valid) {
        glacier_metal_device_lifecycle_observer_fault(state);
        return;
    }

    @synchronized (state) {
        GlacierMetalDeviceLifecycle* lifecycle = &state->snapshot;
        if (lifecycle->observer_active == 0 ||
            registry_id != lifecycle->registry_id)
            return;

        if (lifecycle->event_sequence == UINT64_MAX) {
            lifecycle->observer_fault = 1;
            return;
        }
        const uint32_t source =
            glacier_metal_device_lifecycle_source_for_event(
                event_kind);
        if (source == 0) {
            lifecycle->observer_fault = 1;
            return;
        }
        lifecycle->event_sequence += 1;
        lifecycle->event_kind = event_kind;
        lifecycle->source_bits |= source;
        glacier_metal_device_lifecycle_apply_effective_state(
            lifecycle);
    }
}

static void glacier_metal_device_lifecycle_command_buffer_removed(
    GlacierMetalDeviceLifecycleState* state)
{
    if (!state) return;
    @synchronized (state) {
        GlacierMetalDeviceLifecycle* lifecycle = &state->snapshot;
        if (lifecycle->observer_active == 0)
            return;
        if (lifecycle->event_sequence == UINT64_MAX) {
            lifecycle->observer_fault = 1;
            return;
        }
        lifecycle->event_sequence += 1;
        lifecycle->event_kind =
            GLACIER_METAL_DEVICE_EVENT_COMMAND_BUFFER_REMOVED;
        lifecycle->source_bits |=
            GLACIER_METAL_DEVICE_SOURCE_COMMAND_BUFFER_REMOVED;
        glacier_metal_device_lifecycle_apply_effective_state(
            lifecycle);
    }
}

static int glacier_metal_install_device_lifecycle_observer(
    GlacierMetalContext* ctx)
{
    if (!ctx || !ctx->device)
        return 1;
    if (@available(macOS 10.13, *)) {
        const uint64_t observer_generation =
            glacier_metal_reserve_device_lifecycle_generation();
        if (observer_generation == 0)
            return 1;

        uint64_t selected_registry_id = 0;
        @try {
            if (![ctx->device
                    respondsToSelector:@selector(registryID)])
                return 1;
            selected_registry_id = ctx->device.registryID;
        } @catch (NSException* exception) {
            (void)exception;
            return 1;
        }
        if (selected_registry_id == 0)
            return 1;

        GlacierMetalDeviceLifecycleState* state =
            [[GlacierMetalDeviceLifecycleState alloc] init];
        if (!state) return 1;
        memset(&state->snapshot, 0, sizeof(state->snapshot));
        state->active_admissions = 0;
        state->last_consumed_event_sequence = 0;
        state->snapshot.abi_version =
            GLACIER_METAL_DEVICE_LIFECYCLE_ABI;
        state->snapshot.registry_id = selected_registry_id;
        state->snapshot.observer_generation =
            observer_generation;
        state->snapshot.event_sequence = 1;
        state->snapshot.event_kind =
            GLACIER_METAL_DEVICE_EVENT_INITIAL_MEMBERSHIP;
        state->snapshot.present = 1;
        state->snapshot.observer_active = 1;
        state->snapshot.initial_membership = 1;
        state->snapshot.source_bits =
            GLACIER_METAL_DEVICE_SOURCE_INITIAL;

        id<NSObject> observer = nil;
        GlacierMetalDeviceLifecycleState* callback_state = state;
        NSArray<id<MTLDevice>>* initial_devices = nil;
        @try {
            initial_devices =
                MTLCopyAllDevicesWithObserver(
                    &observer,
                    ^(id<MTLDevice> device,
                        MTLDeviceNotificationName name)
                    {
                        @autoreleasepool {
                            glacier_metal_device_lifecycle_event(
                                callback_state,
                                device,
                                name);
                        }
                    });
        } @catch (NSException* exception) {
            (void)exception;
            glacier_metal_device_lifecycle_observer_fault(state);
        }

        int initial_member_found = 0;
        @try {
            for (id<MTLDevice> candidate in initial_devices) {
                if ([candidate
                        respondsToSelector:@selector(registryID)] &&
                    candidate.registryID ==
                        state->snapshot.registry_id)
                {
                    initial_member_found = 1;
                    break;
                }
            }
        } @catch (NSException* exception) {
            (void)exception;
            initial_member_found = 0;
            glacier_metal_device_lifecycle_observer_fault(state);
        }
        if (!observer || !initial_devices ||
            !initial_member_found)
        {
            @synchronized (state) {
                state->snapshot.observer_active = 0;
                state->snapshot.observer_fault = 1;
            }
            if (observer)
                MTLRemoveDeviceObserver(observer);
            return 1;
        }
        ctx->device_lifecycle_observer = observer;
        ctx->device_lifecycle_state = state;
        return 0;
    }
    return 1;
}

static void glacier_metal_remove_device_lifecycle_observer(
    GlacierMetalContext* ctx)
{
    if (!ctx) return;
    GlacierMetalDeviceLifecycleState* state =
        ctx->device_lifecycle_state;
    id<NSObject> observer = ctx->device_lifecycle_observer;
    if (state) {
        @synchronized (state) {
            state->snapshot.observer_active = 0;
        }
    }
    if (observer) {
        if (@available(macOS 10.13, *))
            MTLRemoveDeviceObserver(observer);
    }
    ctx->device_lifecycle_observer = nil;
    ctx->device_lifecycle_state = nil;
}

static void glacier_metal_command_destroy(
    GlacierMetalCommandRecord* record)
{
    if (!record) return;
    record->owner = NULL;
    record->next = NULL;
    record->command_buffer = nil;
    record->packed = nil;
    record->scales = nil;
    record->input = nil;
    record->output = nil;
    record->completion_publication = nil;
    record->callback_gate = nil;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    record->test_callback_hold = nil;
#endif
    memset(record->allocations, 0, sizeof(record->allocations));
    free(record);
}

// Context destruction is refused while native command ownership remains. The
// caller can then reconcile the exact command token instead of freeing an
// Objective-C callback target or a buffer still referenced by the GPU.
static int glacier_metal_context_destroy(GlacierMetalContext* ctx) {
    if (!ctx) return 0;
    if (ctx->command_records || ctx->live_command_records != 0)
        return 1;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    if (ctx->test_active_callback_hold)
        return 1;
#endif
    for (GlacierMetalBufferAllocation* allocation =
            ctx->buffer_allocations;
         allocation;
         allocation = allocation->next)
    {
        if (allocation->active_command_references != 0)
            return 1;
    }
    GlacierMetalDeviceLifecycleState* lifecycle_state =
        ctx->device_lifecycle_state;
    if (lifecycle_state) {
        @synchronized (lifecycle_state) {
            if (lifecycle_state->active_admissions != 0)
                return 1;
            lifecycle_state->snapshot.observer_active = 0;
        }
    }
    glacier_metal_remove_device_lifecycle_observer(ctx);
    while (ctx->command_retirement_tombstones) {
        GlacierMetalCommandRetirementTombstone* tombstone =
            ctx->command_retirement_tombstones;
        ctx->command_retirement_tombstones = tombstone->next;
        tombstone->next = NULL;
        free(tombstone);
    }
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
    return 0;
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
    if (allocation->active_command_references != 0)
        return;
    allocation->owner = NULL;
    allocation->next = NULL;
    allocation->buffer = nil;
    free(allocation);
}

// Resolve a copied command token without ever dereferencing caller memory as
// an address. Callers hold @synchronized(ctx->device).
static GlacierMetalCommandRecord** glacier_metal_command_link_locked(
    GlacierMetalContext* ctx,
    const GlacierMetalCommandToken* token)
{
    GlacierMetalCommandRecord** link = &ctx->command_records;
    while (*link && memcmp(
            &(*link)->token,
            token,
            sizeof(*token)) != 0)
        link = &(*link)->next;
    return *link ? link : NULL;
}

static GlacierMetalCommandRetirementTombstone**
glacier_metal_command_retirement_tombstone_link_locked(
    GlacierMetalContext* ctx,
    const GlacierMetalCommandToken* token)
{
    GlacierMetalCommandRetirementTombstone** link =
        &ctx->command_retirement_tombstones;
    while (*link && memcmp(
            &(*link)->permit.token,
            token,
            sizeof(*token)) != 0)
        link = &(*link)->next;
    return *link ? link : NULL;
}

static int glacier_metal_unlink_command_locked(
    GlacierMetalContext* ctx,
    GlacierMetalCommandRecord* record)
{
    if (!ctx || !record || record->owner != ctx ||
        ctx->live_command_records == 0)
        return 1;
    GlacierMetalCommandRecord** link =
        glacier_metal_command_link_locked(ctx, &record->token);
    if (!link || *link != record)
        return 1;
    for (size_t index = 0; index < 4; index += 1) {
        GlacierMetalBufferAllocation* allocation =
            record->allocations[index];
        if (!allocation || allocation->owner != ctx ||
            allocation->active_command_references == 0)
            return 1;
    }
    *link = record->next;
    record->next = NULL;
    record->owner = NULL;
    ctx->live_command_records -= 1;
    for (size_t index = 0; index < 4; index += 1)
        record->allocations[index]->active_command_references -= 1;
    return 0;
}

// A submit reserves all four exact allocations before exposing their Shared
// contents to host writes. Until the command record is linked, this helper is
// the only path allowed to release those provisional references.
static void glacier_metal_release_command_reservations(
    GlacierMetalContext* ctx,
    GlacierMetalBufferAllocation* allocations[4])
{
    if (!ctx || !ctx->device || !allocations)
        abort();
    @synchronized (ctx->device) {
        for (size_t index = 0; index < 4; index += 1) {
            if (!allocations[index] ||
                allocations[index]->owner != ctx ||
                allocations[index]->active_command_references != 1)
                abort();
        }
        for (size_t index = 0; index < 4; index += 1)
            allocations[index]->active_command_references -= 1;
    }
}

static int glacier_metal_command_matches_locked(
    GlacierMetalContext* ctx,
    GlacierMetalCommandRecord* record,
    const uint8_t submission_binding[32])
{
    return record &&
        record->owner == ctx &&
        record->command_buffer &&
        record->completion_publication &&
        glacier_metal_submission_disposition_valid(
            record->submission_disposition) &&
        !glacier_metal_binding_is_zero(submission_binding) &&
        memcmp(
            record->submission_binding,
            submission_binding,
            sizeof(record->submission_binding)) == 0;
}

static uint32_t glacier_metal_command_state_locked(
    const GlacierMetalCommandRecord* record,
    uint32_t completion_observed)
{
    if (!completion_observed)
        return GLACIER_METAL_COMMAND_PENDING;
    if (record->callback_fault != 0)
        return GLACIER_METAL_COMMAND_UNKNOWN;
    if (record->command_status == MTLCommandBufferStatusCompleted)
        return GLACIER_METAL_COMMAND_COMPLETED;
    if (record->command_status == MTLCommandBufferStatusError)
        return GLACIER_METAL_COMMAND_ERROR;
    return GLACIER_METAL_COMMAND_UNKNOWN;
}

static void glacier_metal_fill_completion_locked(
    const GlacierMetalCommandRecord* record,
    uint32_t completion_observed,
    GlacierMetalAsyncCompletion* out)
{
    memset(out, 0, sizeof(*out));
    out->abi_version = GLACIER_METAL_ASYNC_COMPLETION_ABI;
    out->token = record->token;
    memcpy(
        out->submission_binding,
        record->submission_binding,
        sizeof(out->submission_binding));
    out->state = glacier_metal_command_state_locked(
        record,
        completion_observed);
    if (!completion_observed)
        return;
    out->current_allocated_before =
        record->current_allocated_before;
    out->current_allocated_after =
        record->current_allocated_after;
    out->gpu_start_time = record->gpu_start_time;
    out->gpu_end_time = record->gpu_end_time;
    out->error_code = record->error_code;
    out->command_status = record->command_status;
    out->error_domain_kind = record->error_domain_kind;
    out->error_present = record->error_present;
    out->callback_fault = record->callback_fault;
}

static void glacier_metal_fill_dispatch_retirement_permit_locked(
    const GlacierMetalCommandRecord* record,
    uint64_t retirement_generation,
    uint32_t authorization_kind,
    const GlacierMetalDeviceLifecycleSourceIdentity* source,
    uint64_t minimum_event_sequence,
    GlacierMetalDispatchRetirementPermit* out)
{
    memset(out, 0, sizeof(*out));
    out->abi_version =
        GLACIER_METAL_DISPATCH_RETIREMENT_PERMIT_ABI;
    out->token = record->token;
    memcpy(
        out->submission_binding,
        record->submission_binding,
        sizeof(out->submission_binding));
    out->retirement_generation = retirement_generation;
    if (source)
    out->source_identity = *source;
    out->minimum_event_sequence = minimum_event_sequence;
    out->error_code = record->error_code;
    out->authorization_kind = authorization_kind;
    out->submission_disposition =
        record->submission_disposition;
    out->native_state = glacier_metal_command_state_locked(
        record,
        record->completion_observed);
    out->command_status = record->command_status;
    out->completion_observed = record->completion_observed;
    out->error_domain_kind = record->error_domain_kind;
    out->error_present = record->error_present;
    out->callback_fault = record->callback_fault;
    out->commit_invoked = record->commit_invoked;
    out->callback_detached = 1;
}

static int glacier_metal_dispatch_retirement_request_matches(
    const GlacierMetalDispatchRetirementPermit* retained,
    const GlacierMetalAsyncSubmission* submission,
    uint32_t authorization_kind,
    const GlacierMetalDeviceLifecycleSourceIdentity* source,
    uint64_t minimum_event_sequence)
{
    if (!retained || !submission ||
        memcmp(
            &retained->token,
            &submission->token,
            sizeof(retained->token)) != 0 ||
        memcmp(
            retained->submission_binding,
            submission->submission_binding,
            sizeof(retained->submission_binding)) != 0 ||
        retained->submission_disposition !=
            submission->disposition ||
        retained->authorization_kind != authorization_kind ||
        retained->minimum_event_sequence !=
            minimum_event_sequence)
        return 0;
    if (source)
        return memcmp(
            &retained->source_identity,
            source,
            sizeof(*source)) == 0;
    return glacier_metal_lifecycle_source_identity_zero(
        &retained->source_identity);
}

static void glacier_metal_fill_dispatch_retirement_receipt_locked(
    const GlacierMetalCommandRecord* record,
    GlacierMetalDispatchRetirementReceipt* out)
{
    memset(out, 0, sizeof(*out));
    out->abi_version =
        GLACIER_METAL_DISPATCH_RETIREMENT_RECEIPT_ABI;
    out->permit = record->retirement_permit;
    out->retired_native_command_count = 1;
    out->released_allocation_reference_count = 4;
    out->error_code = record->error_code;
    out->completion_observed = record->completion_observed;
    out->native_state = glacier_metal_command_state_locked(
        record,
        record->completion_observed);
    out->command_status = record->command_status;
    out->error_domain_kind = record->error_domain_kind;
    out->error_present = record->error_present;
    out->callback_fault = record->callback_fault;
    out->callback_detached = 1;
}

// All retirement telemetry mutations occur under @synchronized(ctx->device).
// Saturation is sticky and deliberately non-fallible: diagnostics cannot
// weaken callback detachment, native unlink, or exact replay.
static void
glacier_metal_retirement_telemetry_add_locked(
    GlacierMetalContext* ctx,
    uint64_t* field,
    uint64_t delta,
    uint64_t overflow_bit)
{
    if (!ctx || !field || delta == 0 ||
        overflow_bit == 0 ||
        (overflow_bit &
            ~GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_ALL) != 0 ||
        (overflow_bit & (overflow_bit - 1)) != 0)
        abort();
    GlacierMetalDispatchRetirementTelemetryV1* telemetry =
        &ctx->dispatch_retirement_telemetry;
    if ((telemetry->overflow_mask & overflow_bit) != 0) {
        *field = UINT64_MAX;
        return;
    }
    if (*field > UINT64_MAX - delta) {
        *field = UINT64_MAX;
        telemetry->overflow_mask |= overflow_bit;
        return;
    }
    *field += delta;
}

static void
glacier_metal_retirement_telemetry_decrement_live_locked(
    GlacierMetalContext* ctx)
{
    if (!ctx) abort();
    GlacierMetalDispatchRetirementTelemetryV1* telemetry =
        &ctx->dispatch_retirement_telemetry;
    if ((telemetry->overflow_mask &
            GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_LIVE_PREPARED) != 0)
    {
        telemetry->live_prepared_retirement_count = UINT64_MAX;
        return;
    }
    if (telemetry->live_prepared_retirement_count == 0)
        abort();
    telemetry->live_prepared_retirement_count -= 1;
}

static void
glacier_metal_retirement_telemetry_record_prepare_replay_locked(
    GlacierMetalContext* ctx,
    int tombstone_replay)
{
    GlacierMetalDispatchRetirementTelemetryV1* telemetry =
        &ctx->dispatch_retirement_telemetry;
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->snapshot_sequence,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SNAPSHOT_SEQUENCE);
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->prepare_replay_count,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PREPARE_REPLAY);
    if (tombstone_replay) {
        glacier_metal_retirement_telemetry_add_locked(
            ctx,
            &telemetry->prepare_tombstone_replay_count,
            1,
            GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PREPARE_TOMBSTONE_REPLAY);
    } else {
        glacier_metal_retirement_telemetry_add_locked(
            ctx,
            &telemetry->prepare_live_record_replay_count,
            1,
            GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PREPARE_LIVE_REPLAY);
    }
}

static void
glacier_metal_retirement_telemetry_record_prepare_locked(
    GlacierMetalContext* ctx,
    const GlacierMetalDispatchRetirementPermit* permit)
{
    if (!ctx ||
        !glacier_metal_dispatch_retirement_permit_valid(permit))
        abort();
    GlacierMetalDispatchRetirementTelemetryV1* telemetry =
        &ctx->dispatch_retirement_telemetry;
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->snapshot_sequence,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SNAPSHOT_SEQUENCE);
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->prepared_retirement_count,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PREPARED);
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->live_prepared_retirement_count,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_LIVE_PREPARED);
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->callback_detached_count,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_CALLBACK_DETACHED);

    if (permit->completion_observed == 0) {
        glacier_metal_retirement_telemetry_add_locked(
            ctx,
            &telemetry->completion_unobserved_prepare_count,
            1,
            GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMPLETION_UNOBSERVED);
    } else {
        glacier_metal_retirement_telemetry_add_locked(
            ctx,
            &telemetry->completion_observed_prepare_count,
            1,
            GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMPLETION_OBSERVED);
    }

    switch (permit->native_state) {
        case GLACIER_METAL_COMMAND_PENDING:
            glacier_metal_retirement_telemetry_add_locked(
                ctx,
                &telemetry->pending_prepare_count,
                1,
                GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_PENDING);
            break;
        case GLACIER_METAL_COMMAND_COMPLETED:
            glacier_metal_retirement_telemetry_add_locked(
                ctx,
                &telemetry->completed_prepare_count,
                1,
                GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMPLETED);
            break;
        case GLACIER_METAL_COMMAND_ERROR:
            glacier_metal_retirement_telemetry_add_locked(
                ctx,
                &telemetry->error_prepare_count,
                1,
                GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_ERROR);
            break;
        case GLACIER_METAL_COMMAND_UNKNOWN:
            glacier_metal_retirement_telemetry_add_locked(
                ctx,
                &telemetry->unknown_prepare_count,
                1,
                GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_UNKNOWN);
            break;
        default:
            abort();
    }

    switch (permit->submission_disposition) {
        case GLACIER_METAL_SUBMIT_SUBMITTED:
            glacier_metal_retirement_telemetry_add_locked(
                ctx,
                &telemetry->submitted_prepare_count,
                1,
                GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SUBMITTED);
            break;
        case GLACIER_METAL_SUBMIT_SUBMITTED_OR_AMBIGUOUS:
            glacier_metal_retirement_telemetry_add_locked(
                ctx,
                &telemetry->submitted_or_ambiguous_prepare_count,
                1,
                GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SUBMITTED_OR_AMBIGUOUS);
            break;
        default:
            abort();
    }

    switch (permit->authorization_kind) {
        case GLACIER_METAL_RETIREMENT_NATIVE_LOSS:
            glacier_metal_retirement_telemetry_add_locked(
                ctx,
                &telemetry->native_loss_prepare_count,
                1,
                GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_NATIVE_LOSS);
            break;
        case GLACIER_METAL_RETIREMENT_SYNTHETIC_TEST:
            glacier_metal_retirement_telemetry_add_locked(
                ctx,
                &telemetry->synthetic_test_prepare_count,
                1,
                GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SYNTHETIC_TEST);
            break;
        default:
            abort();
    }

    if (permit->retirement_generation >
        telemetry->highest_prepared_retirement_generation)
    {
        telemetry->highest_prepared_retirement_generation =
            permit->retirement_generation;
    }
}

static void
glacier_metal_retirement_telemetry_record_commit_replay_locked(
    GlacierMetalContext* ctx)
{
    GlacierMetalDispatchRetirementTelemetryV1* telemetry =
        &ctx->dispatch_retirement_telemetry;
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->snapshot_sequence,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SNAPSHOT_SEQUENCE);
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->commit_replay_count,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMMIT_REPLAY);
}

static void
glacier_metal_retirement_telemetry_record_commit_locked(
    GlacierMetalContext* ctx,
    const GlacierMetalDispatchRetirementPermit* permit)
{
    if (!ctx ||
        !glacier_metal_dispatch_retirement_permit_valid(permit))
        abort();
    GlacierMetalDispatchRetirementTelemetryV1* telemetry =
        &ctx->dispatch_retirement_telemetry;
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->snapshot_sequence,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_SNAPSHOT_SEQUENCE);
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->committed_retirement_count,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_COMMITTED);
    glacier_metal_retirement_telemetry_decrement_live_locked(ctx);
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->retired_native_command_count,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_RETIRED_NATIVE_COMMAND);
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->released_allocation_reference_count,
        4,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_RELEASED_ALLOCATION_REFERENCE);
    glacier_metal_retirement_telemetry_add_locked(
        ctx,
        &telemetry->retained_tombstone_count,
        1,
        GLACIER_METAL_RETIREMENT_TELEMETRY_OVERFLOW_RETAINED_TOMBSTONE);
    if (permit->retirement_generation >
        telemetry->highest_committed_retirement_generation)
    {
        telemetry->highest_committed_retirement_generation =
            permit->retirement_generation;
    }
}

#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
static int glacier_metal_test_fault_plan_valid(
    const GlacierMetalTestFaultPlanV1* plan)
{
    if (!plan ||
        plan->abi_version != GLACIER_METAL_TEST_FAULT_PLAN_ABI ||
        plan->plan_generation == 0 ||
        plan->plan_generation == UINT64_MAX ||
        plan->reserved != 0)
        return 0;
    switch (plan->kind) {
        case GLACIER_METAL_TEST_COMPLETED_AS_COMMAND_ERROR:
            return plan->injected_error_code != 0;
        case GLACIER_METAL_TEST_REAL_COMMIT_AS_AMBIGUOUS:
        case GLACIER_METAL_TEST_COMPLETED_AS_UNKNOWN:
        case GLACIER_METAL_TEST_COMPLETED_OUTPUT_READ_REJECTION:
            return plan->injected_error_code == 0;
        default:
            return 0;
    }
}

static void glacier_metal_test_initialize_completion_facts_locked(
    GlacierMetalCommandRecord* record)
{
    if (!record ||
        !glacier_metal_test_fault_plan_valid(
            &record->test_fault_plan))
        return;
    memset(
        &record->test_completion_facts,
        0,
        sizeof(record->test_completion_facts));
    record->test_completion_facts.abi_version =
        GLACIER_METAL_TEST_COMPLETION_FACTS_V2_ABI;
    record->test_completion_facts.plan_generation =
        record->test_fault_plan.plan_generation;
    record->test_completion_facts.kind =
        record->test_fault_plan.kind;
    record->test_completion_facts.injected_error_code =
        record->test_fault_plan.injected_error_code;
    record->test_completion_facts_ready = 0;
}

// Publish the real commit outcome before applying a test-only outward
// disposition. The record retains the published disposition, so retirement
// cannot authenticate a caller-manufactured ambiguous copy.
static void glacier_metal_test_publish_submission_facts_locked(
    GlacierMetalCommandRecord* record,
    GlacierMetalAsyncSubmission* submission,
    uint32_t commit_returned_normally)
{
    if (!record || !submission ||
        !glacier_metal_test_fault_plan_valid(
            &record->test_fault_plan))
        return;
    if (commit_returned_normally > 1 ||
        !glacier_metal_async_submission_valid(submission) ||
        memcmp(
            &record->token,
            &submission->token,
            sizeof(record->token)) != 0 ||
        memcmp(
            record->submission_binding,
            submission->submission_binding,
            sizeof(record->submission_binding)) != 0)
        abort();

    GlacierMetalTestCompletionFactsV2* facts =
        &record->test_completion_facts;
    facts->physical_submission = *submission;
    facts->published_submission = *submission;
    facts->commit_returned_normally =
        commit_returned_normally;
    facts->commit_exception_observed =
        1U - commit_returned_normally;

    if (record->test_fault_plan.kind ==
            GLACIER_METAL_TEST_REAL_COMMIT_AS_AMBIGUOUS &&
        commit_returned_normally == 1 &&
        submission->disposition ==
            GLACIER_METAL_SUBMIT_SUBMITTED)
    {
        facts->published_submission.disposition =
            GLACIER_METAL_SUBMIT_SUBMITTED_OR_AMBIGUOUS;
        facts->submission_overlay_applied = 1;
        facts->fault_applied = 1;
    }
    record->submission_disposition =
        facts->published_submission.disposition;
    *submission = facts->published_submission;
    // Submission facts are useful while a callback is deliberately held.
    // Completion structs remain canonical zero values until the callback
    // snapshot stage flips callback_snapshot_observed.
    record->test_completion_facts_ready = 1;
}

static int glacier_metal_test_exact_physical_success(
    const GlacierMetalAsyncCompletion* completion)
{
    return completion &&
        completion->abi_version ==
            GLACIER_METAL_ASYNC_COMPLETION_ABI &&
        completion->state == GLACIER_METAL_COMMAND_COMPLETED &&
        completion->command_status ==
            MTLCommandBufferStatusCompleted &&
        completion->error_domain_kind ==
            GLACIER_METAL_ERROR_DOMAIN_NONE &&
        completion->error_present == 0 &&
        completion->callback_fault == 0 &&
        completion->current_allocated_before != 0 &&
        completion->current_allocated_after != 0 &&
        isfinite(completion->gpu_start_time) &&
        isfinite(completion->gpu_end_time) &&
        completion->gpu_start_time > 0 &&
        completion->gpu_end_time >
            completion->gpu_start_time;
}
#endif

static int glacier_metal_exact_command_buffer_device_removed(
    uint32_t command_status,
    uint32_t error_present,
    uint32_t error_domain_kind,
    int64_t error_code,
    uint32_t property_fault)
{
    return property_fault == 0 &&
        command_status == MTLCommandBufferStatusError &&
        error_present != 0 &&
        error_domain_kind ==
            GLACIER_METAL_ERROR_DOMAIN_COMMAND_BUFFER &&
        error_code ==
            (int64_t)MTLCommandBufferErrorDeviceRemoved;
}

// Observe the exact direct-command terminal properties before callers fold
// every non-completed result into their legacy generic failure code.
static int glacier_metal_observe_direct_command_buffer(
    GlacierMetalContext* ctx,
    id<MTLCommandBuffer> command_buffer,
    uint32_t* command_status_out)
{
    if (command_status_out) *command_status_out = 0;
    if (!ctx || !command_buffer || !command_status_out)
        return 1;

    uint32_t command_status = 0;
    uint32_t error_present = 0;
    uint32_t error_domain_kind =
        GLACIER_METAL_ERROR_DOMAIN_NONE;
    int64_t error_code = 0;
    @try {
        command_status = (uint32_t)command_buffer.status;
        NSError* error = command_buffer.error;
        if (error) {
            error_present = 1;
            error_code = (int64_t)error.code;
            error_domain_kind =
                [error.domain
                    isEqualToString:MTLCommandBufferErrorDomain]
                ? GLACIER_METAL_ERROR_DOMAIN_COMMAND_BUFFER
                : GLACIER_METAL_ERROR_DOMAIN_OTHER;
        }
    } @catch (NSException* exception) {
        (void)exception;
        return 1;
    }

    *command_status_out = command_status;
    if (glacier_metal_exact_command_buffer_device_removed(
            command_status,
            error_present,
            error_domain_kind,
            error_code,
            0))
    {
        glacier_metal_device_lifecycle_command_buffer_removed(
            ctx->device_lifecycle_state);
    }
    return 0;
}

// Publish one immutable final snapshot. The completed handler is the normal
// caller; wait uses this helper only as a fallback if Metal has reached a
// final status before the handler acquires the registry lock.
static void glacier_metal_snapshot_completion_locked(
    GlacierMetalContext* ctx,
    GlacierMetalCommandRecord* record,
    id<MTLCommandBuffer> command_buffer)
{
    if (!ctx || !record || record->completion_observed ||
        !command_buffer)
        return;

    uint64_t current_allocated_after = 0;
    double gpu_start_time = 0;
    double gpu_end_time = 0;
    int64_t error_code = 0;
    uint32_t command_status = 0;
    uint32_t error_domain_kind =
        GLACIER_METAL_ERROR_DOMAIN_NONE;
    uint32_t error_present = 0;
    uint32_t callback_fault = 0;
    // Read terminal classification first. Error paths intentionally leave
    // allocation and GPU timing telemetry unavailable so an exact
    // device-removed error never triggers another query on the dead device.
    @try {
        command_status = (uint32_t)command_buffer.status;
        NSError* error = command_buffer.error;
        if (error) {
            error_present = 1;
            error_code = (int64_t)error.code;
            error_domain_kind =
                [error.domain
                    isEqualToString:MTLCommandBufferErrorDomain]
                ? GLACIER_METAL_ERROR_DOMAIN_COMMAND_BUFFER
                : GLACIER_METAL_ERROR_DOMAIN_OTHER;
        }
    } @catch (NSException* exception) {
        (void)exception;
        current_allocated_after = 0;
        gpu_start_time = 0;
        gpu_end_time = 0;
        error_code = 0;
        error_domain_kind =
            GLACIER_METAL_ERROR_DOMAIN_NONE;
        error_present = 0;
        callback_fault = 1;
    }
    if (callback_fault == 0 &&
        command_status == MTLCommandBufferStatusCompleted)
    {
        @try {
            current_allocated_after =
                ctx->device.currentAllocatedSize;
            gpu_start_time = command_buffer.GPUStartTime;
            gpu_end_time = command_buffer.GPUEndTime;
        } @catch (NSException* exception) {
            (void)exception;
            current_allocated_after = 0;
            gpu_start_time = 0;
            gpu_end_time = 0;
            callback_fault = 1;
        }
    }

    record->current_allocated_after = current_allocated_after;
    record->gpu_start_time = gpu_start_time;
    record->gpu_end_time = gpu_end_time;
    record->error_code = error_code;
    record->command_status = command_status;
    record->error_domain_kind = error_domain_kind;
    record->error_present = error_present;
    record->callback_fault = callback_fault;
    if (glacier_metal_exact_command_buffer_device_removed(
            command_status,
            error_present,
            error_domain_kind,
            error_code,
            callback_fault))
    {
        glacier_metal_device_lifecycle_command_buffer_removed(
            ctx->device_lifecycle_state);
    }
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    if (glacier_metal_test_fault_plan_valid(
            &record->test_fault_plan))
    {
        GlacierMetalTestCompletionFactsV2* facts =
            &record->test_completion_facts;
        glacier_metal_fill_completion_locked(
            record,
            1,
            &facts->physical);
        facts->callback_snapshot_observed = 1;

        // Never relabel a physical error, unknown state, or malformed
        // completion. Every callback overlay is eligible only after an
        // independently valid physical success exists.
        if (glacier_metal_test_exact_physical_success(
                &facts->physical))
        {
            switch (record->test_fault_plan.kind) {
                case GLACIER_METAL_TEST_COMPLETED_AS_COMMAND_ERROR:
                    record->command_status =
                        MTLCommandBufferStatusError;
                    record->error_code =
                        record->test_fault_plan.injected_error_code;
                    record->error_domain_kind =
                        GLACIER_METAL_ERROR_DOMAIN_COMMAND_BUFFER;
                    record->error_present = 1;
                    record->callback_fault = 0;
                    facts->fault_applied = 1;
                    facts->completion_overlay_applied = 1;
                    break;
                case GLACIER_METAL_TEST_COMPLETED_AS_UNKNOWN:
                    // Keep the real completed status and telemetry, but mark
                    // the callback projection as unauthenticated. The public
                    // state derivation is therefore UNKNOWN rather than a
                    // manufactured terminal.
                    record->callback_fault = 1;
                    facts->fault_applied = 1;
                    facts->completion_overlay_applied = 1;
                    break;
                default:
                    break;
            }
        }
        glacier_metal_fill_completion_locked(
            record,
            1,
            &facts->published);
    }
#endif
    // Publish last. Readers currently hold the same Objective-C monitor, and
    // retaining this ordering also keeps a future lock-free observer from
    // seeing fields before the test-only overlay is complete.
    record->completion_observed = 1;
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
        (void)glacier_metal_context_destroy(ctx);
        return NULL;
    }
    if (glacier_metal_install_device_lifecycle_observer(ctx) != 0) {
        (void)glacier_metal_context_destroy(ctx);
        return NULL;
    }
    do {
        arc4random_buf(
            ctx->allocation_context_nonce,
            sizeof(ctx->allocation_context_nonce));
    } while (glacier_metal_nonce_is_zero(
        ctx->allocation_context_nonce));
    ctx->dispatch_retirement_telemetry.abi_version =
        GLACIER_METAL_DISPATCH_RETIREMENT_TELEMETRY_ABI;
    GlacierMetalDeviceLifecycleState* telemetry_lifecycle_state =
        ctx->device_lifecycle_state;
    if (!telemetry_lifecycle_state) {
        (void)glacier_metal_context_destroy(ctx);
        return NULL;
    }
    @synchronized (telemetry_lifecycle_state) {
        ctx->dispatch_retirement_telemetry.device_registry_id =
            telemetry_lifecycle_state->snapshot.registry_id;
    }
    if (ctx->dispatch_retirement_telemetry.device_registry_id == 0) {
        (void)glacier_metal_context_destroy(ctx);
        return NULL;
    }
    memcpy(
        ctx->dispatch_retirement_telemetry.context_nonce,
        ctx->allocation_context_nonce,
        sizeof(ctx->dispatch_retirement_telemetry.context_nonce));
    ctx->next_allocation_adapter_instance = 1;
    ctx->next_buffer_generation = 1;
    ctx->next_command_generation = 1;
    ctx->next_command_retirement_generation = 1;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    ctx->next_test_fault_plan_generation = 1;
#endif
    ctx->queue = [ctx->device newCommandQueue];
    if (!ctx->queue) {
        (void)glacier_metal_context_destroy(ctx);
        return NULL;
    }

    NSString* path = [NSString stringWithUTF8String:metallib_path];
    if (!path) {
        (void)glacier_metal_context_destroy(ctx);
        return NULL;
    }
    NSError* err = nil;
    ctx->library = [ctx->device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
    if (!ctx->library) {
        (void)glacier_metal_context_destroy(ctx);
        return NULL;
    }
    return ctx;
}

int glacier_metal_deinit(GlacierMetalContext* ctx) {
    return glacier_metal_context_destroy(ctx);
}

int glacier_metal_device_lifecycle_snapshot(
    GlacierMetalContext* ctx,
    GlacierMetalDeviceLifecycle* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version = GLACIER_METAL_DEVICE_LIFECYCLE_ABI;
    }
    if (!ctx || !out)
        return 1;
    GlacierMetalDeviceLifecycleState* state =
        ctx->device_lifecycle_state;
    if (!state)
        return 2;

    @synchronized (state) {
        *out = state->snapshot;
    }
    return 0;
}

int glacier_metal_device_lifecycle_source_identity(
    GlacierMetalContext* ctx,
    GlacierMetalDeviceLifecycleSourceIdentity* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version =
            GLACIER_METAL_LIFECYCLE_SOURCE_IDENTITY_ABI;
    }
    if (!ctx || !out)
        return 1;
    GlacierMetalDeviceLifecycleState* state =
        ctx->device_lifecycle_state;
    if (!state ||
        glacier_metal_nonce_is_zero(
            ctx->allocation_context_nonce))
        return 2;

    int result = 0;
    @synchronized (state) {
        const GlacierMetalDeviceLifecycle* lifecycle =
            &state->snapshot;
        if (lifecycle->observer_active != 1 ||
            lifecycle->observer_fault != 0 ||
            !glacier_metal_device_lifecycle_shape_valid(
                lifecycle))
        {
            result = 3;
        } else {
            out->registry_id = lifecycle->registry_id;
            out->observer_generation =
                lifecycle->observer_generation;
            memcpy(
                out->context_nonce,
                ctx->allocation_context_nonce,
                sizeof(out->context_nonce));
        }
    }
    return result;
}

// Consume one exact immutable snapshot sequence. The observer generation and
// event sequence must still be current, and a sequence can be consumed only
// once. Snapshot publication itself remains level-triggered and unchanged.
int glacier_metal_device_lifecycle_consume(
    GlacierMetalContext* ctx,
    const GlacierMetalDeviceLifecycle* expected,
    uint64_t* consumed_event_sequence)
{
    if (consumed_event_sequence)
        *consumed_event_sequence = 0;
    if (!ctx || !expected || !consumed_event_sequence)
        return GLACIER_METAL_LIFECYCLE_CONSUME_INVALID;
    const GlacierMetalDeviceLifecycle expected_copy = *expected;
    if (!glacier_metal_device_lifecycle_shape_valid(
            &expected_copy) ||
        expected_copy.observer_active != 1 ||
        expected_copy.observer_fault != 0)
        return GLACIER_METAL_LIFECYCLE_CONSUME_INVALID;

    GlacierMetalDeviceLifecycleState* state =
        ctx->device_lifecycle_state;
    if (!state)
        return GLACIER_METAL_LIFECYCLE_CONSUME_UNAVAILABLE;

    int result = 0;
    @synchronized (state) {
        const GlacierMetalDeviceLifecycle* current =
            &state->snapshot;
        if (current->observer_active != 1 ||
            current->observer_fault != 0 ||
            !glacier_metal_device_lifecycle_shape_valid(current))
        {
            result =
                GLACIER_METAL_LIFECYCLE_CONSUME_UNAVAILABLE;
        } else if (expected_copy.observer_generation !=
            current->observer_generation)
        {
            result =
                GLACIER_METAL_LIFECYCLE_CONSUME_GENERATION_MISMATCH;
        } else if (expected_copy.event_sequence !=
                current->event_sequence ||
            expected_copy.event_sequence <=
                state->last_consumed_event_sequence ||
            memcmp(
                &expected_copy,
                current,
                sizeof(expected_copy)) != 0)
        {
            result = GLACIER_METAL_LIFECYCLE_CONSUME_STALE;
        } else {
            state->last_consumed_event_sequence =
                expected_copy.event_sequence;
            *consumed_event_sequence =
                expected_copy.event_sequence;
        }
    }
    return result;
}

#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
static int
glacier_metal_test_arm_next_fault_plan_v1_admitted(
    GlacierMetalContext* ctx,
    uint32_t kind,
    GlacierMetalTestFaultPlanV1* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version =
            GLACIER_METAL_TEST_FAULT_PLAN_ABI;
    }
    if (!ctx || !ctx->device || !out ||
        (kind != GLACIER_METAL_TEST_COMPLETED_AS_COMMAND_ERROR &&
            kind != GLACIER_METAL_TEST_REAL_COMMIT_AS_AMBIGUOUS &&
            kind != GLACIER_METAL_TEST_COMPLETED_AS_UNKNOWN &&
            kind !=
                GLACIER_METAL_TEST_COMPLETED_OUTPUT_READ_REJECTION))
        return 1;

    int result = 0;
    @synchronized (ctx->device) {
        if (ctx->test_fault_plan_armed != 0 ||
            ctx->command_records ||
            ctx->live_command_records != 0)
        {
            result = 2;
        } else if (
            ctx->next_test_fault_plan_generation == 0 ||
            ctx->next_test_fault_plan_generation ==
                UINT64_MAX ||
            (kind ==
                    GLACIER_METAL_TEST_COMPLETED_AS_COMMAND_ERROR &&
                (int64_t)MTLCommandBufferErrorDeviceRemoved == 0))
        {
            result = 3;
        } else {
            GlacierMetalTestFaultPlanV1 plan;
            memset(&plan, 0, sizeof(plan));
            plan.abi_version =
                GLACIER_METAL_TEST_FAULT_PLAN_ABI;
            plan.plan_generation =
                ctx->next_test_fault_plan_generation;
            plan.kind = kind;
            if (kind ==
                GLACIER_METAL_TEST_COMPLETED_AS_COMMAND_ERROR)
            {
                // Publish the exact command-specific 5/1/11 shape required
                // by the reconciliation contract. Lifecycle classification
                // occurs before this fault-only overlay.
                plan.injected_error_code =
                    (int64_t)MTLCommandBufferErrorDeviceRemoved;
            }
            ctx->next_test_fault_plan_generation += 1;
            ctx->armed_test_fault_plan = plan;
            ctx->test_fault_plan_armed = 1;
            *out = plan;
        }
    }
    return result;
}

static int glacier_metal_test_arm_next_fault_plan_v1(
    GlacierMetalContext* ctx,
    uint32_t kind,
    GlacierMetalTestFaultPlanV1* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version =
            GLACIER_METAL_TEST_FAULT_PLAN_ABI;
    }
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 5;
    @try {
        return
            glacier_metal_test_arm_next_fault_plan_v1_admitted(
                ctx,
                kind,
                out);
    } @catch (NSException* exception) {
        (void)exception;
        return 5;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
}

int glacier_metal_test_arm_next_completed_as_command_error_v1(
    GlacierMetalContext* ctx,
    GlacierMetalTestFaultPlanV1* out)
{
    return glacier_metal_test_arm_next_fault_plan_v1(
        ctx,
        GLACIER_METAL_TEST_COMPLETED_AS_COMMAND_ERROR,
        out);
}

int glacier_metal_test_arm_next_real_commit_as_ambiguous_v1(
    GlacierMetalContext* ctx,
    GlacierMetalTestFaultPlanV1* out)
{
    return glacier_metal_test_arm_next_fault_plan_v1(
        ctx,
        GLACIER_METAL_TEST_REAL_COMMIT_AS_AMBIGUOUS,
        out);
}

int glacier_metal_test_arm_next_completed_as_unknown_v1(
    GlacierMetalContext* ctx,
    GlacierMetalTestFaultPlanV1* out)
{
    return glacier_metal_test_arm_next_fault_plan_v1(
        ctx,
        GLACIER_METAL_TEST_COMPLETED_AS_UNKNOWN,
        out);
}

int glacier_metal_test_arm_next_completed_output_read_rejection_v1(
    GlacierMetalContext* ctx,
    GlacierMetalTestFaultPlanV1* out)
{
    return glacier_metal_test_arm_next_fault_plan_v1(
        ctx,
        GLACIER_METAL_TEST_COMPLETED_OUTPUT_READ_REJECTION,
        out);
}

// Caller holds the native device monitor. Return codes retain the original
// unavailable/ambiguous/pending contract.
static int glacier_metal_test_completion_facts_lookup_locked(
    GlacierMetalContext* ctx,
    const uint8_t submission_binding[32],
    const GlacierMetalTestCompletionFactsV2** out)
{
    if (out) *out = NULL;
    if (!ctx || !submission_binding ||
        glacier_metal_binding_is_zero(submission_binding) || !out)
        return 1;

    int result = 0;
    const GlacierMetalTestCompletionFactsV2* match = NULL;
    uint32_t match_ready = 0;
    for (GlacierMetalCommandRecord* record =
            ctx->command_records;
         record;
         record = record->next)
    {
        if (memcmp(
                record->submission_binding,
                submission_binding,
                sizeof(record->submission_binding)) != 0)
            continue;
        if (match) {
            result = 3;
            break;
        }
        match = &record->test_completion_facts;
        match_ready =
            record->test_completion_facts_ready;
    }
    for (GlacierMetalCommandRetirementTombstone* tombstone =
            ctx->command_retirement_tombstones;
         result == 0 && tombstone;
         tombstone = tombstone->next)
    {
        if (memcmp(
                tombstone->permit.submission_binding,
                submission_binding,
                sizeof(tombstone->permit.submission_binding)) != 0)
            continue;
        if (match) {
            result = 3;
            break;
        }
        match = &tombstone->test_completion_facts;
        match_ready =
            tombstone->test_completion_facts_ready;
    }
    if (result == 0 && !match)
        result = 2;
    if (result == 0 && match_ready == 0)
        result = 4;
    if (result == 0)
        *out = match;
    return result;
}

int glacier_metal_test_completion_facts_for_binding_v1(
    GlacierMetalContext* ctx,
    const uint8_t submission_binding[32],
    GlacierMetalTestCompletionFactsV1* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version =
            GLACIER_METAL_TEST_COMPLETION_FACTS_ABI;
    }
    if (!ctx || !ctx->device || !submission_binding ||
        glacier_metal_binding_is_zero(submission_binding) || !out)
        return 1;

    int result = 0;
    @synchronized (ctx->device) {
        const GlacierMetalTestCompletionFactsV2* match = NULL;
        result = glacier_metal_test_completion_facts_lookup_locked(
            ctx,
            submission_binding,
            &match);
        // V1 remains the original completion-only command-error campaign.
        if (result == 0 &&
            (match->kind !=
                    GLACIER_METAL_TEST_COMPLETED_AS_COMMAND_ERROR ||
                match->callback_snapshot_observed != 1))
        {
            result = 4;
        }
        if (result == 0) {
            out->plan_generation = match->plan_generation;
            out->kind = match->kind;
            out->fault_applied = match->fault_applied;
            out->injected_error_code =
                match->injected_error_code;
            out->physical = match->physical;
            out->published = match->published;
        }
    }
    return result;
}

int glacier_metal_test_completion_facts_for_binding_v2(
    GlacierMetalContext* ctx,
    const uint8_t submission_binding[32],
    GlacierMetalTestCompletionFactsV2* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version =
            GLACIER_METAL_TEST_COMPLETION_FACTS_V2_ABI;
    }
    if (!ctx || !ctx->device || !submission_binding ||
        glacier_metal_binding_is_zero(submission_binding) || !out)
        return 1;

    int result = 0;
    @synchronized (ctx->device) {
        const GlacierMetalTestCompletionFactsV2* match = NULL;
        result = glacier_metal_test_completion_facts_lookup_locked(
            ctx,
            submission_binding,
            &match);
        if (result == 0)
            *out = *match;
    }
    return result;
}

int glacier_metal_test_arm_next_completion_callback_hold(
    GlacierMetalContext* ctx)
{
    if (!ctx || !ctx->device) return 1;
    int result = 0;
    @synchronized (ctx->device) {
        if (ctx->test_callback_hold_armed != 0 ||
            ctx->test_active_callback_hold ||
            ctx->command_records ||
            ctx->live_command_records != 0)
        {
            result = 2;
        } else {
            ctx->test_callback_hold_armed = 1;
        }
    }
    return result;
}

int glacier_metal_test_wait_for_held_completion_callback(
    GlacierMetalContext* ctx)
{
    if (!ctx || !ctx->device) return 1;
    GlacierMetalTestCallbackHold* hold = nil;
    @synchronized (ctx->device) {
        hold = ctx->test_active_callback_hold;
    }
    if (!hold) return 2;
    const dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW,
        5LL * NSEC_PER_SEC);
    return dispatch_group_wait(
        hold->entered_group,
        deadline) == 0 ? 0 : 3;
}

int glacier_metal_test_wait_for_registered_dispatch_waiter(
    GlacierMetalContext* ctx)
{
    if (!ctx || !ctx->device) return 1;
    GlacierMetalTestCallbackHold* hold = nil;
    @synchronized (ctx->device) {
        hold = ctx->test_active_callback_hold;
    }
    if (!hold) return 2;
    const dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW,
        5LL * NSEC_PER_SEC);
    return dispatch_group_wait(
        hold->registered_waiter_entered_group,
        deadline) == 0 ? 0 : 3;
}

int glacier_metal_test_release_held_completion_callback(
    GlacierMetalContext* ctx)
{
    if (!ctx || !ctx->device) return 1;
    GlacierMetalTestCallbackHold* hold = nil;
    @synchronized (ctx->device) {
        hold = ctx->test_active_callback_hold;
    }
    if (!hold) return 2;
    glacier_metal_test_callback_hold_release(hold);
    const dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW,
        5LL * NSEC_PER_SEC);
    if (dispatch_group_wait(
            hold->exited_group,
            deadline) != 0)
        return 3;
    @synchronized (ctx->device) {
        if (ctx->test_active_callback_hold != hold)
            return 4;
        ctx->test_active_callback_hold = nil;
    }
    return 0;
}

int glacier_metal_test_arm_next_dispatch_retirement_commit_failure(
    GlacierMetalContext* ctx)
{
    if (!ctx || !ctx->device) return 1;
    int result = 0;
    @synchronized (ctx->device) {
        GlacierMetalCommandRecord* record =
            ctx->command_records;
        if (ctx->test_retirement_commit_failure_armed != 0) {
            result = 2;
        } else if (!record ||
            record->next ||
            ctx->live_command_records != 1 ||
            record->retirement_armed != 1 ||
            !glacier_metal_dispatch_retirement_permit_valid(
                &record->retirement_permit))
        {
            result = 3;
        } else {
            ctx->test_retirement_commit_failure_armed = 1;
        }
    }
    return result;
}

int glacier_metal_test_dispatch_retirement_commit_facts(
    GlacierMetalContext* ctx,
    GlacierMetalTestRetirementCommitFactsV1* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version =
            GLACIER_METAL_TEST_RETIREMENT_COMMIT_FACTS_ABI;
    }
    if (!ctx || !ctx->device || !out)
        return 1;
    @synchronized (ctx->device) {
        out->commit_attempt_count =
            ctx->test_retirement_commit_attempt_count;
        out->injected_failure_count =
            ctx->test_retirement_commit_injected_failure_count;
        out->committed_retirement_count =
            ctx->test_retirement_committed_count;
        out->replay_count =
            ctx->test_retirement_commit_replay_count;
        out->failure_armed =
            ctx->test_retirement_commit_failure_armed;
    }
    return 0;
}
#endif

static int glacier_metal_device_info_admitted(
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

int glacier_metal_device_info(
    GlacierMetalContext* ctx,
    GlacierMetalDeviceInfo* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version = GLACIER_METAL_DEVICE_INFO_ABI;
    }
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 3;
    @try {
        return glacier_metal_device_info_admitted(ctx, out);
    } @catch (NSException* exception) {
        (void)exception;
        if (out) {
            memset(out, 0, sizeof(*out));
            out->abi_version =
                GLACIER_METAL_DEVICE_INFO_ABI;
        }
        return 3;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
}

static int glacier_metal_allocation_limits_admitted(
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

int glacier_metal_allocation_limits(
    GlacierMetalContext* ctx,
    GlacierMetalAllocationLimits* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version =
            GLACIER_METAL_ALLOCATION_LIMITS_ABI;
    }
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 3;
    @try {
        return glacier_metal_allocation_limits_admitted(
            ctx,
            out);
    } @catch (NSException* exception) {
        (void)exception;
        if (out) {
            memset(out, 0, sizeof(*out));
            out->abi_version =
                GLACIER_METAL_ALLOCATION_LIMITS_ABI;
        }
        return 3;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
}

static int glacier_metal_claim_allocation_adapter_admitted(
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

int glacier_metal_claim_allocation_adapter(
    GlacierMetalContext* ctx,
    GlacierMetalAdapterIdentity* out)
{
    if (out) memset(out, 0, sizeof(*out));
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 3;
    @try {
        return glacier_metal_claim_allocation_adapter_admitted(
            ctx,
            out);
    } @catch (NSException* exception) {
        (void)exception;
        return 3;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
}

static int glacier_metal_buffer_create_admitted(
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

int glacier_metal_buffer_create(
    GlacierMetalContext* ctx,
    uint64_t requested_length,
    GlacierMetalBufferToken* out)
{
    if (out) memset(out, 0, sizeof(*out));
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 4;
    @try {
        return glacier_metal_buffer_create_admitted(
            ctx,
            requested_length,
            out);
    } @catch (NSException* exception) {
        (void)exception;
        if (out) memset(out, 0, sizeof(*out));
        return 4;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
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
        if ((*link)->active_command_references != 0)
            return 4;
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

static int glacier_metal_require_int4_matvec_support_admitted(
    GlacierMetalContext* ctx)
{
    return glacier_metal_get_int4_matvec_pipeline(ctx) ? 0 : 1;
}

int glacier_metal_require_int4_matvec_support(
    GlacierMetalContext* ctx)
{
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 2;
    @try {
        return
            glacier_metal_require_int4_matvec_support_admitted(
                ctx);
    } @catch (NSException* exception) {
        (void)exception;
        return 2;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
}

// Dispatch the INT4 → FP16 dequant kernel.
//   payload: pointer to qio-encoded bytes (host memory)
//   payload_bytes: length of payload
//   out: caller-allocated FP16 buffer (host memory), num_elements * 2 bytes
//   num_elements: number of weights to decode
// Returns 0 on success, non-zero on error.
static int glacier_metal_dequant_int4_admitted(
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
    uint32_t command_status = 0;
    if (glacier_metal_observe_direct_command_buffer(
            ctx,
            cb,
            &command_status) != 0 ||
        command_status != MTLCommandBufferStatusCompleted)
        return 3;

    memcpy(out, out_buf.contents, num_elements * sizeof(uint16_t));
    return 0;
}

int glacier_metal_dequant_int4(
    GlacierMetalContext* ctx,
    const uint8_t* payload,
    uint64_t payload_bytes,
    void* out,
    uint32_t num_elements)
{
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 4;
    @try {
        return glacier_metal_dequant_int4_admitted(
            ctx,
            payload,
            payload_bytes,
            out,
            num_elements);
    } @catch (NSException* exception) {
        (void)exception;
        return 4;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
}

// Dispatch matmul_f16_tiled: C[M,N] = A[M,K] × B^T[N,K].
// A and B are half* (FP16), C is half* output.
// Returns 0 on success, non-zero on error.
static int glacier_metal_matmul_admitted(
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
    uint32_t command_status = 0;
    if (glacier_metal_observe_direct_command_buffer(
            ctx,
            cb,
            &command_status) != 0 ||
        command_status != MTLCommandBufferStatusCompleted)
        return 4;

    memcpy(C_bytes, c_buf.contents, c_length);
    return 0;
}

int glacier_metal_matmul(
    GlacierMetalContext* ctx,
    const void* A_bytes,
    const void* B_bytes,
    void* C_bytes,
    uint32_t M,
    uint32_t K,
    uint32_t N)
{
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 5;
    @try {
        return glacier_metal_matmul_admitted(
            ctx,
            A_bytes,
            B_bytes,
            C_bytes,
            M,
            K,
            N);
    } @catch (NSException* exception) {
        (void)exception;
        return 5;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
}

// Upload one packed INT4 matrix and its scales once. The returned handle owns
// reusable activation/output buffers and is valid until explicitly destroyed.
static GlacierMetalInt4Weight*
glacier_metal_int4_weight_create_admitted(
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

    @try {
        weight->packed = [ctx->device
            newBufferWithBytes:packed
                        length:required_packed
                       options:MTLResourceStorageModeShared];
        weight->scales = [ctx->device
            newBufferWithBytes:scales
                        length:required_scales * sizeof(float)
                       options:MTLResourceStorageModeShared];
        weight->input = [ctx->device
            newBufferWithLength:
                (uint64_t)in_features * sizeof(float)
                         options:MTLResourceStorageModeShared];
        weight->output = [ctx->device
            newBufferWithLength:
                (uint64_t)out_features * sizeof(float)
                         options:MTLResourceStorageModeShared];
    } @catch (NSException* exception) {
        glacier_metal_weight_destroy(weight);
        @throw exception;
    }
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
    if (!ctx) return NULL;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return NULL;
    @try {
        return glacier_metal_int4_weight_create_admitted(
            ctx,
            packed,
            packed_bytes,
            scales,
            scale_count,
            group_size,
            in_features,
            out_features);
    } @catch (NSException* exception) {
        (void)exception;
        return NULL;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
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

// Submit using four exact resources owned by the native allocation registry.
// Host output is intentionally absent. The returned command token owns the
// command buffer and all four buffers until exact terminal finalization.
static int
glacier_metal_int4_registered_buffers_submit_async_admitted(
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
    const uint8_t submission_binding[32],
    GlacierMetalAsyncSubmission* submission)
{
    if (submission) {
        memset(submission, 0, sizeof(*submission));
        submission->abi_version =
            GLACIER_METAL_ASYNC_SUBMISSION_ABI;
    }
    if (!ctx || !ctx->device || !ctx->queue || !ctx->library ||
        !packed_token || !scales_token || !input_token ||
        !output_token || !packed || !scales || !input ||
        !submission_binding ||
        glacier_metal_binding_is_zero(submission_binding) ||
        !submission || group_size == 0 ||
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
    GlacierMetalBufferAllocation* packed_allocation = NULL;
    GlacierMetalBufferAllocation* scales_allocation = NULL;
    GlacierMetalBufferAllocation* input_allocation = NULL;
    GlacierMetalBufferAllocation* output_allocation = NULL;
    GlacierMetalBufferAllocation* reserved_allocations[4] = {
        NULL,
        NULL,
        NULL,
        NULL,
    };
    int reservations_held = 0;
    @try {
        @synchronized (ctx->device) {
            packed_allocation =
                glacier_metal_buffer_exact_locked(
                    ctx, packed_token, required_packed);
            scales_allocation =
                glacier_metal_buffer_exact_locked(
                    ctx, scales_token, scales_bytes);
            input_allocation =
                glacier_metal_buffer_exact_locked(
                    ctx, input_token, input_bytes);
            output_allocation =
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
            reserved_allocations[0] = packed_allocation;
            reserved_allocations[1] = scales_allocation;
            reserved_allocations[2] = input_allocation;
            reserved_allocations[3] = output_allocation;
            for (size_t index = 0; index < 4; index += 1) {
                if (reserved_allocations[index]
                        ->active_command_references != 0)
                    return 5;
            }
            for (size_t index = 0; index < 4; index += 1)
                reserved_allocations[index]
                    ->active_command_references += 1;
            reservations_held = 1;
        }
    } @catch (NSException* exception) {
        (void)exception;
        if (reservations_held)
            glacier_metal_release_command_reservations(
                ctx,
                reserved_allocations);
        return 2;
    }

    id<MTLComputePipelineState> pipeline = nil;
    NSUInteger pipeline_width = 0;
    @try {
        pipeline =
            glacier_metal_get_int4_matvec_pipeline(ctx);
        pipeline_width = pipeline
            ? pipeline.threadExecutionWidth
            : 0;
    } @catch (NSException* exception) {
        (void)exception;
        pipeline = nil;
        pipeline_width = 0;
    }
    if (!pipeline || pipeline_width == 0) {
        glacier_metal_release_command_reservations(
            ctx,
            reserved_allocations);
        return 3;
    }

    uint64_t current_allocated_before = 0;
    @try {
        current_allocated_before =
            ctx->device.currentAllocatedSize;
        memcpy(packed_contents, packed, required_packed);
        memcpy(scales_contents, scales, scales_bytes);
        memcpy(input_contents, input, input_bytes);
    } @catch (NSException* exception) {
        (void)exception;
        glacier_metal_release_command_reservations(
            ctx,
            reserved_allocations);
        return 3;
    }
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

    id<MTLCommandBuffer> cb = nil;
    @try {
        cb = [ctx->queue commandBuffer];
        if (!cb) {
            glacier_metal_release_command_reservations(
                ctx,
                reserved_allocations);
            return 4;
        }
        id<MTLComputeCommandEncoder> enc =
            [cb computeCommandEncoder];
        if (!enc) {
            glacier_metal_release_command_reservations(
                ctx,
                reserved_allocations);
            return 4;
        }
        [enc setComputePipelineState:pipeline];
        [enc setBuffer:packed_buffer offset:0 atIndex:0];
        [enc setBuffer:scales_buffer offset:0 atIndex:1];
        [enc setBuffer:input_buffer offset:0 atIndex:2];
        [enc setBuffer:output_buffer offset:0 atIndex:3];
        [enc setBytes:&dims length:sizeof(dims) atIndex:4];

        [enc dispatchThreadgroups:MTLSizeMake(out_features, 1, 1)
             threadsPerThreadgroup:
                MTLSizeMake(pipeline_width, 1, 1)];
        [enc endEncoding];
    } @catch (NSException* exception) {
        (void)exception;
        glacier_metal_release_command_reservations(
            ctx,
            reserved_allocations);
        return 4;
    }

    GlacierMetalCommandRecord* record =
        (GlacierMetalCommandRecord*)calloc(
            1,
            sizeof(GlacierMetalCommandRecord));
    if (!record) {
        glacier_metal_release_command_reservations(
            ctx,
            reserved_allocations);
        return 4;
    }
    record->owner = ctx;
    memcpy(
        record->submission_binding,
        submission_binding,
        sizeof(record->submission_binding));
    record->command_buffer = cb;
    record->packed = packed_buffer;
    record->scales = scales_buffer;
    record->input = input_buffer;
    record->output = output_buffer;
    record->allocations[0] = packed_allocation;
    record->allocations[1] = scales_allocation;
    record->allocations[2] = input_allocation;
    record->allocations[3] = output_allocation;
    record->current_allocated_before =
        current_allocated_before;
    record->callback_gate =
        [[GlacierMetalCommandCallbackGate alloc] init];
    if (!record->callback_gate) {
        glacier_metal_command_destroy(record);
        glacier_metal_release_command_reservations(
            ctx,
            reserved_allocations);
        return 4;
    }
    record->callback_gate->owner = ctx;
    record->completion_publication =
        dispatch_group_create();
    if (!record->completion_publication) {
        glacier_metal_command_destroy(record);
        glacier_metal_release_command_reservations(
            ctx,
            reserved_allocations);
        return 4;
    }
    dispatch_group_enter(record->completion_publication);

#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    int test_callback_hold_requested = 0;
    @synchronized (ctx->device) {
        test_callback_hold_requested =
            ctx->test_callback_hold_armed != 0;
    }
    GlacierMetalTestCallbackHold*
        test_callback_hold_candidate = nil;
    if (test_callback_hold_requested) {
        test_callback_hold_candidate =
            glacier_metal_test_callback_hold_create();
        if (!test_callback_hold_candidate) {
            dispatch_group_leave(
                record->completion_publication);
            glacier_metal_command_destroy(record);
            glacier_metal_release_command_reservations(
                ctx,
                reserved_allocations);
            return 4;
        }
    }
#endif

    int registry_inserted = 0;
    @synchronized (ctx->device) {
        int registry_ready =
            ctx->next_command_generation != 0 &&
            ctx->next_command_generation != UINT64_MAX &&
            ctx->live_command_records != UINT64_MAX;
        for (size_t index = 0; index < 4; index += 1) {
            GlacierMetalBufferAllocation* allocation =
                record->allocations[index];
            if (!allocation || allocation->owner != ctx ||
                allocation->active_command_references != 1)
                registry_ready = 0;
        }
        if (registry_ready) {
            memcpy(
                record->token.context_nonce,
                ctx->allocation_context_nonce,
                sizeof(record->token.context_nonce));
            record->token.generation =
                ctx->next_command_generation;
            ctx->next_command_generation += 1;
            // Conservative until the native commit outcome is published.
            record->submission_disposition =
                GLACIER_METAL_SUBMIT_SUBMITTED_OR_AMBIGUOUS;
            record->next = ctx->command_records;
            ctx->command_records = record;
            ctx->live_command_records += 1;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
            if (ctx->test_callback_hold_armed != 0 &&
                test_callback_hold_candidate &&
                !ctx->test_active_callback_hold)
            {
                record->test_callback_hold =
                    test_callback_hold_candidate;
                ctx->test_active_callback_hold =
                    test_callback_hold_candidate;
                ctx->test_callback_hold_armed = 0;
            }
            if (ctx->test_fault_plan_armed != 0) {
                // Consumption is deliberately registration-scoped. If later
                // pre-commit setup fails, the failed submission consumes the
                // plan rather than silently injecting a different command.
                record->test_fault_plan =
                    ctx->armed_test_fault_plan;
                memset(
                    &ctx->armed_test_fault_plan,
                    0,
                    sizeof(ctx->armed_test_fault_plan));
                ctx->test_fault_plan_armed = 0;
                glacier_metal_test_initialize_completion_facts_locked(
                    record);
            }
#endif

            submission->token = record->token;
            memcpy(
                submission->submission_binding,
                record->submission_binding,
                sizeof(submission->submission_binding));
            // Conservative until commit returns normally. The token is
            // already caller-visible and registry-owned before invocation.
            submission->disposition =
                GLACIER_METAL_SUBMIT_SUBMITTED_OR_AMBIGUOUS;
            registry_inserted = 1;
        }
    }
    if (!registry_inserted) {
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
        glacier_metal_test_callback_hold_cancel(
            test_callback_hold_candidate);
#endif
        dispatch_group_leave(record->completion_publication);
        glacier_metal_command_destroy(record);
        glacier_metal_release_command_reservations(
            ctx,
            reserved_allocations);
        return 4;
    }
    reservations_held = 0;

    const GlacierMetalCommandToken callback_token =
        record->token;
    GlacierMetalCommandCallbackGate* callback_gate =
        record->callback_gate;
    dispatch_group_t completion_publication =
        record->completion_publication;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    GlacierMetalTestCallbackHold* callback_hold =
        record->test_callback_hold;
    if (test_callback_hold_candidate &&
        test_callback_hold_candidate != callback_hold)
        glacier_metal_test_callback_hold_cancel(
            test_callback_hold_candidate);
#endif
    @try {
        [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
            if (callback_hold) {
                glacier_metal_test_callback_hold_publish_entered(
                    callback_hold);
                dispatch_semaphore_wait(
                    callback_hold->release_semaphore,
                    DISPATCH_TIME_FOREVER);
            }
#endif
            @autoreleasepool {
                @try {
                    @synchronized (callback_gate) {
                        GlacierMetalContext* callback_ctx =
                            callback_gate->owner;
                        if (!callback_ctx ||
                            !callback_ctx->device)
                            return;
                        @synchronized (callback_ctx->device) {
                            GlacierMetalCommandRecord** link =
                                glacier_metal_command_link_locked(
                                    callback_ctx,
                                    &callback_token);
                            if (!link ||
                                (*link)->owner != callback_ctx ||
                                (*link)->callback_gate !=
                                    callback_gate)
                                return;
                            glacier_metal_snapshot_completion_locked(
                                callback_ctx,
                                *link,
                                completed);
                        }
                    }
                } @finally {
                    // Waiters cannot treat command-buffer completion as
                    // registry authority until this publication fence opens.
                    dispatch_group_leave(
                        completion_publication);
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
                    glacier_metal_test_callback_hold_publish_exited(
                        callback_hold);
#endif
                }
            }
        }];
    } @catch (NSException* exception) {
        (void)exception;
        int unlinked = 0;
        @synchronized (callback_gate) {
            @synchronized (ctx->device) {
                if (callback_gate->owner == ctx)
                    callback_gate->owner = NULL;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
                if (ctx->test_active_callback_hold ==
                        callback_hold)
                    ctx->test_active_callback_hold = nil;
#endif
                unlinked =
                    glacier_metal_unlink_command_locked(
                        ctx,
                        record) == 0;
            }
        }
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
        glacier_metal_test_callback_hold_cancel(
            callback_hold);
#endif
        dispatch_group_leave(completion_publication);
        if (!unlinked)
            abort();
        glacier_metal_command_destroy(record);
        memset(submission, 0, sizeof(*submission));
        submission->abi_version =
            GLACIER_METAL_ASYNC_SUBMISSION_ABI;
        return 4;
    }

    @synchronized (ctx->device) {
        record->commit_invoked = 1;
    }
    uint32_t commit_returned_normally = 0;
    @try {
        [cb commit];
        commit_returned_normally = 1;
        submission->disposition =
            GLACIER_METAL_SUBMIT_SUBMITTED;
    } @catch (NSException* exception) {
        (void)exception;
        // Invocation crossed the ambiguity boundary. The exact token and all
        // references remain live for poll/wait or later quarantine.
        submission->disposition =
            GLACIER_METAL_SUBMIT_SUBMITTED_OR_AMBIGUOUS;
    }
    @synchronized (ctx->device) {
        GlacierMetalCommandRecord** exact =
            glacier_metal_command_link_locked(
                ctx,
                &record->token);
        if (!exact || *exact != record ||
            record->owner != ctx ||
            record->commit_invoked != 1)
            abort();
        record->submission_disposition =
            submission->disposition;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
        glacier_metal_test_publish_submission_facts_locked(
            record,
            submission,
            commit_returned_normally);
#endif
    }
    return 0;
}

int glacier_metal_int4_registered_buffers_submit_async(
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
    const uint8_t submission_binding[32],
    GlacierMetalAsyncSubmission* submission)
{
    if (submission) {
        memset(submission, 0, sizeof(*submission));
        submission->abi_version =
            GLACIER_METAL_ASYNC_SUBMISSION_ABI;
    }
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 5;
    @try {
        return
            glacier_metal_int4_registered_buffers_submit_async_admitted(
                ctx,
                packed_token,
                scales_token,
                input_token,
                output_token,
                packed,
                packed_bytes,
                scales,
                scale_count,
                input,
                input_count,
                group_size,
                in_features,
                out_features,
                submission_binding,
                submission);
    } @catch (NSException* exception) {
        (void)exception;
        if (submission) {
            memset(submission, 0, sizeof(*submission));
            submission->abi_version =
                GLACIER_METAL_ASYNC_SUBMISSION_ABI;
        }
        return 5;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
}

int glacier_metal_registered_dispatch_poll(
    GlacierMetalContext* ctx,
    const GlacierMetalCommandToken* token,
    const uint8_t submission_binding[32],
    GlacierMetalAsyncCompletion* completion)
{
    if (completion) {
        memset(completion, 0, sizeof(*completion));
        completion->abi_version =
            GLACIER_METAL_ASYNC_COMPLETION_ABI;
    }
    if (!ctx || !ctx->device || !token ||
        token->generation == 0 || !submission_binding ||
        glacier_metal_binding_is_zero(submission_binding) ||
        !completion)
        return 1;
    @synchronized (ctx->device) {
        GlacierMetalCommandRecord** link =
            glacier_metal_command_link_locked(ctx, token);
        if (!link || !glacier_metal_command_matches_locked(
                ctx,
                *link,
                submission_binding))
            return 2;
        glacier_metal_fill_completion_locked(
            *link,
            (*link)->completion_observed,
            completion);
    }
    return 0;
}

int glacier_metal_registered_dispatch_wait(
    GlacierMetalContext* ctx,
    const GlacierMetalCommandToken* token,
    const uint8_t submission_binding[32],
    GlacierMetalAsyncCompletion* completion)
{
    if (completion) {
        memset(completion, 0, sizeof(*completion));
        completion->abi_version =
            GLACIER_METAL_ASYNC_COMPLETION_ABI;
    }
    if (!ctx || !ctx->device || !token ||
        token->generation == 0 || !submission_binding ||
        glacier_metal_binding_is_zero(submission_binding) ||
        !completion)
        return 1;

    id<MTLCommandBuffer> command_buffer = nil;
    dispatch_group_t completion_publication = nil;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    GlacierMetalTestCallbackHold* test_callback_hold = nil;
#endif
    @synchronized (ctx->device) {
        GlacierMetalCommandRecord** link =
            glacier_metal_command_link_locked(ctx, token);
        if (!link || !glacier_metal_command_matches_locked(
                ctx,
                *link,
                submission_binding))
            return 2;
        if ((*link)->completion_observed) {
            glacier_metal_fill_completion_locked(
                *link,
                (*link)->completion_observed,
                completion);
            return 0;
        }
        // This local ARC strong reference keeps the command buffer alive
        // while the registry monitor is deliberately not held.
        command_buffer = (*link)->command_buffer;
        completion_publication =
            (*link)->completion_publication;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
        test_callback_hold = (*link)->test_callback_hold;
#endif
        if (!completion_publication)
            return 3;
    }

    int wait_returned = 0;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
    // Publish only after the registry monitor is released and the waiter has
    // copied both strong references. Some Metal implementations do not return
    // from waitUntilCompleted until completion handlers exit, so signalling
    // after that call would not prove the intended lock boundary.
    glacier_metal_test_callback_hold_publish_registered_waiter_entered(
        test_callback_hold);
#endif
    @try {
        [command_buffer waitUntilCompleted];
        wait_returned = 1;
    } @catch (NSException* exception) {
        (void)exception;
        // The exact registry record remains authoritative. Re-read it below;
        // a non-final status remains pending/unknown rather than becoming a
        // manufactured terminal.
    }
    if (wait_returned) {
        dispatch_group_wait(
            completion_publication,
            DISPATCH_TIME_FOREVER);
    }

    @synchronized (ctx->device) {
        GlacierMetalCommandRecord** link =
            glacier_metal_command_link_locked(ctx, token);
        if (!link || !glacier_metal_command_matches_locked(
                ctx,
                *link,
                submission_binding))
            return 2;
        // Only the completed handler may publish terminal authority. In the
        // exceptional wait path this therefore replays pending/unknown; after
        // a normal wait the publication group guarantees the handler snapshot
        // is already immutable.
        glacier_metal_fill_completion_locked(
            *link,
            (*link)->completion_observed,
            completion);
    }
    return 0;
}

int glacier_metal_registered_dispatch_finalize(
    GlacierMetalContext* ctx,
    const GlacierMetalCommandToken* token,
    const uint8_t submission_binding[32],
    const GlacierMetalAsyncCompletion* expected_completion)
{
    if (!ctx || !ctx->device || !token ||
        token->generation == 0 || !submission_binding ||
        glacier_metal_binding_is_zero(submission_binding) ||
        !expected_completion ||
        expected_completion->abi_version !=
            GLACIER_METAL_ASYNC_COMPLETION_ABI ||
        expected_completion->reserved != 0 ||
        memcmp(
            &expected_completion->token,
            token,
            sizeof(*token)) != 0 ||
        memcmp(
            expected_completion->submission_binding,
            submission_binding,
            sizeof(expected_completion->submission_binding)) != 0)
        return 1;

    GlacierMetalCommandCallbackGate* callback_gate = nil;
    @synchronized (ctx->device) {
        GlacierMetalCommandRecord** link =
            glacier_metal_command_link_locked(ctx, token);
        if (!link || !glacier_metal_command_matches_locked(
                ctx,
                *link,
                submission_binding))
            return 2;
        callback_gate = (*link)->callback_gate;
        if (!callback_gate)
            return 4;
    }

    GlacierMetalCommandRecord* record = NULL;
    @synchronized (callback_gate) {
        if (callback_gate->owner != ctx)
            return 2;
        @synchronized (ctx->device) {
            GlacierMetalCommandRecord** link =
                glacier_metal_command_link_locked(ctx, token);
            if (!link || !glacier_metal_command_matches_locked(
                    ctx,
                    *link,
                    submission_binding) ||
                (*link)->callback_gate != callback_gate)
                return 2;
            GlacierMetalAsyncCompletion exact;
            glacier_metal_fill_completion_locked(
                *link,
                (*link)->completion_observed,
                &exact);
            if ((exact.state !=
                        GLACIER_METAL_COMMAND_COMPLETED &&
                    exact.state !=
                        GLACIER_METAL_COMMAND_ERROR) ||
                memcmp(
                    &exact,
                    expected_completion,
                    sizeof(exact)) != 0)
                return 3;
            record = *link;
            callback_gate->owner = NULL;
            if (glacier_metal_unlink_command_locked(
                    ctx,
                    record) != 0)
                abort();
        }
    }
    glacier_metal_command_destroy(record);
    return 0;
}

static int
glacier_metal_registered_dispatch_retirement_prepare_internal(
    GlacierMetalContext* ctx,
    const GlacierMetalAsyncSubmission* submission,
    uint32_t authorization_kind,
    const GlacierMetalDeviceLifecycleSourceIdentity* source,
    uint64_t minimum_event_sequence,
    GlacierMetalDispatchRetirementPermit* permit)
{
    if (permit) {
        memset(permit, 0, sizeof(*permit));
        permit->abi_version =
            GLACIER_METAL_DISPATCH_RETIREMENT_PERMIT_ABI;
    }
    if (!ctx || !ctx->device ||
        !glacier_metal_async_submission_valid(submission) ||
        !permit)
        return 1;
    if (authorization_kind ==
            GLACIER_METAL_RETIREMENT_NATIVE_LOSS)
    {
        if (!source ||
            !glacier_metal_exact_sticky_native_loss(
                ctx,
                source,
                minimum_event_sequence))
            return 5;
    } else if (
        authorization_kind ==
            GLACIER_METAL_RETIREMENT_SYNTHETIC_TEST)
    {
        if (source || minimum_event_sequence != 0)
            return 1;
    } else {
        return 1;
    }

    GlacierMetalCommandCallbackGate* callback_gate = nil;
    @synchronized (ctx->device) {
        GlacierMetalCommandRetirementTombstone** retired =
            glacier_metal_command_retirement_tombstone_link_locked(
                ctx,
                &submission->token);
        if (retired) {
            if (!glacier_metal_dispatch_retirement_request_matches(
                    &(*retired)->permit,
                    submission,
                    authorization_kind,
                    source,
                    minimum_event_sequence))
                return 3;
            glacier_metal_retirement_telemetry_record_prepare_replay_locked(
                ctx,
                1);
            *permit = (*retired)->permit;
            return 0;
        }
        GlacierMetalCommandRecord** link =
            glacier_metal_command_link_locked(
                ctx,
                &submission->token);
        if (!link || !glacier_metal_command_matches_locked(
                ctx,
                *link,
                submission->submission_binding) ||
            (*link)->submission_disposition !=
                submission->disposition)
            return 2;
        callback_gate = (*link)->callback_gate;
        if (!callback_gate)
            return 2;
    }

    @synchronized (callback_gate) {
        @synchronized (ctx->device) {
            GlacierMetalCommandRecord** link =
                glacier_metal_command_link_locked(
                    ctx,
                    &submission->token);
            if (!link || !glacier_metal_command_matches_locked(
                    ctx,
                    *link,
                    submission->submission_binding) ||
                (*link)->callback_gate != callback_gate ||
                (*link)->submission_disposition !=
                    submission->disposition)
            {
                GlacierMetalCommandRetirementTombstone** retired =
                    glacier_metal_command_retirement_tombstone_link_locked(
                        ctx,
                        &submission->token);
                if (!retired ||
                    !glacier_metal_dispatch_retirement_request_matches(
                        &(*retired)->permit,
                        submission,
                        authorization_kind,
                        source,
                        minimum_event_sequence))
                    return 2;
                glacier_metal_retirement_telemetry_record_prepare_replay_locked(
                    ctx,
                    1);
                *permit = (*retired)->permit;
                return 0;
            }
            GlacierMetalCommandRecord* record = *link;
            if (record->retirement_armed != 0) {
                if (callback_gate->owner != NULL ||
                    !glacier_metal_dispatch_retirement_permit_valid(
                        &record->retirement_permit) ||
                    !glacier_metal_dispatch_retirement_request_matches(
                        &record->retirement_permit,
                        submission,
                        authorization_kind,
                        source,
                        minimum_event_sequence))
                    return 3;
                glacier_metal_retirement_telemetry_record_prepare_replay_locked(
                    ctx,
                    0);
                *permit = record->retirement_permit;
                return 0;
            }
            if (callback_gate->owner != ctx ||
                record->owner != ctx ||
                !record->command_buffer ||
                !record->completion_publication ||
                record->commit_invoked != 1 ||
                ctx->next_command_retirement_generation == 0 ||
                ctx->next_command_retirement_generation ==
                    UINT64_MAX)
                return 4;
            for (size_t index = 0; index < 4; index += 1) {
                GlacierMetalBufferAllocation* allocation =
                    record->allocations[index];
                if (!allocation ||
                    allocation->owner != ctx ||
                    allocation->active_command_references != 1)
                    return 2;
            }

            GlacierMetalDispatchRetirementPermit prepared;
            glacier_metal_fill_dispatch_retirement_permit_locked(
                record,
                ctx->next_command_retirement_generation,
                authorization_kind,
                source,
                minimum_event_sequence,
                &prepared);
            if (!glacier_metal_dispatch_retirement_permit_valid(
                    &prepared))
                return 2;
            record->retirement_permit = prepared;
            record->retirement_armed = 1;
            ctx->next_command_retirement_generation += 1;
            // Publish detachment last while both monitors are held. A callback
            // already inside the gate completed its registry access first; a
            // later callback observes NULL and cannot reach `ctx`.
            callback_gate->owner = NULL;
            glacier_metal_retirement_telemetry_record_prepare_locked(
                ctx,
                &prepared);
            *permit = prepared;
        }
    }
    return 0;
}

int glacier_metal_registered_dispatch_retirement_prepare_after_loss(
    GlacierMetalContext* ctx,
    const GlacierMetalAsyncSubmission* submission,
    const GlacierMetalDeviceLifecycleSourceIdentity* source,
    uint64_t minimum_event_sequence,
    GlacierMetalDispatchRetirementPermit* permit)
{
    return
        glacier_metal_registered_dispatch_retirement_prepare_internal(
            ctx,
            submission,
            GLACIER_METAL_RETIREMENT_NATIVE_LOSS,
            source,
            minimum_event_sequence,
            permit);
}

#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
int glacier_metal_test_registered_dispatch_retirement_prepare(
    GlacierMetalContext* ctx,
    const GlacierMetalAsyncSubmission* submission,
    GlacierMetalDispatchRetirementPermit* permit)
{
    return
        glacier_metal_registered_dispatch_retirement_prepare_internal(
            ctx,
            submission,
            GLACIER_METAL_RETIREMENT_SYNTHETIC_TEST,
            NULL,
            0,
            permit);
}
#endif

int glacier_metal_registered_dispatch_retirement_commit(
    GlacierMetalContext* ctx,
    const GlacierMetalDispatchRetirementPermit* permit,
    GlacierMetalDispatchRetirementReceipt* receipt)
{
    if (receipt) {
        memset(receipt, 0, sizeof(*receipt));
        receipt->abi_version =
            GLACIER_METAL_DISPATCH_RETIREMENT_RECEIPT_ABI;
    }
    if (!ctx || !ctx->device ||
        !glacier_metal_dispatch_retirement_permit_valid(permit) ||
        !receipt)
        return 1;

    // A completed exact replay is allocation-free and cannot fail merely
    // because the process is under memory pressure after the first commit.
    @synchronized (ctx->device) {
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
        ctx->test_retirement_commit_attempt_count += 1;
#endif
        GlacierMetalCommandRetirementTombstone** retired =
            glacier_metal_command_retirement_tombstone_link_locked(
                ctx,
                &permit->token);
        if (retired) {
            if (memcmp(
                    &(*retired)->permit,
                    permit,
                    sizeof(*permit)) != 0)
                return 3;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
            ctx->test_retirement_commit_replay_count += 1;
#endif
            glacier_metal_retirement_telemetry_record_commit_replay_locked(
                ctx);
            *receipt = (*retired)->receipt;
            return 0;
        }
    }

    GlacierMetalCommandRetirementTombstone* candidate =
        (GlacierMetalCommandRetirementTombstone*)calloc(
            1,
            sizeof(*candidate));
    if (!candidate)
        return 4;

    GlacierMetalCommandCallbackGate* callback_gate = nil;
    @synchronized (ctx->device) {
        GlacierMetalCommandRetirementTombstone** retired =
            glacier_metal_command_retirement_tombstone_link_locked(
                ctx,
                &permit->token);
        if (retired) {
            if (memcmp(
                    &(*retired)->permit,
                    permit,
                    sizeof(*permit)) != 0)
            {
                free(candidate);
                return 3;
            }
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
            ctx->test_retirement_commit_replay_count += 1;
#endif
            glacier_metal_retirement_telemetry_record_commit_replay_locked(
                ctx);
            *receipt = (*retired)->receipt;
            free(candidate);
            return 0;
        }
        GlacierMetalCommandRecord** link =
            glacier_metal_command_link_locked(
                ctx,
                &permit->token);
        if (!link || !glacier_metal_command_matches_locked(
                ctx,
                *link,
                permit->submission_binding))
        {
            free(candidate);
            return 2;
        }
        callback_gate = (*link)->callback_gate;
        if (!callback_gate) {
            free(candidate);
            return 2;
        }
    }

    GlacierMetalCommandRecord* record = NULL;
    @synchronized (callback_gate) {
        @synchronized (ctx->device) {
            GlacierMetalCommandRecord** link =
                glacier_metal_command_link_locked(
                    ctx,
                    &permit->token);
            if (!link || !glacier_metal_command_matches_locked(
                    ctx,
                    *link,
                    permit->submission_binding) ||
                (*link)->callback_gate != callback_gate)
            {
                free(candidate);
                return 2;
            }
            record = *link;
            if (callback_gate->owner != NULL ||
                record->retirement_armed != 1 ||
                memcmp(
                    &record->retirement_permit,
                    permit,
                    sizeof(*permit)) != 0)
            {
                free(candidate);
                return 3;
            }
            for (size_t index = 0; index < 4; index += 1) {
                GlacierMetalBufferAllocation* allocation =
                    record->allocations[index];
                if (!allocation ||
                    allocation->owner != ctx ||
                    allocation->active_command_references != 1)
                {
                    free(candidate);
                    return 2;
                }
            }

            candidate->permit = *permit;
            glacier_metal_fill_dispatch_retirement_receipt_locked(
                record,
                &candidate->receipt);
            if (candidate->receipt.retired_native_command_count != 1 ||
                candidate->receipt
                    .released_allocation_reference_count != 4 ||
                candidate->receipt.callback_detached != 1)
            {
                free(candidate);
                return 2;
            }

#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
            candidate->test_completion_facts =
                record->test_completion_facts;
            candidate->test_completion_facts_ready =
                record->test_completion_facts_ready;
            if (ctx->test_retirement_commit_failure_armed != 0) {
                // Consume the one-shot only at the last fallible boundary.
                // No registry link, allocation reference, or tombstone has
                // changed, so the exact permit remains retryable.
                ctx->test_retirement_commit_failure_armed = 0;
                ctx->test_retirement_commit_injected_failure_count += 1;
                free(candidate);
                return 5;
            }
#endif

            // Every fallible check and allocation is complete. From unlink
            // onward only bounded assignments and ownership drops remain.
            if (glacier_metal_unlink_command_locked(
                    ctx,
                    record) != 0)
                abort();
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
            ctx->test_retirement_committed_count += 1;
#endif
            candidate->next =
                ctx->command_retirement_tombstones;
            ctx->command_retirement_tombstones = candidate;
            glacier_metal_retirement_telemetry_record_commit_locked(
                ctx,
                permit);
            *receipt = candidate->receipt;
        }
    }
    glacier_metal_command_destroy(record);
    return 0;
}

int glacier_metal_dispatch_retirement_telemetry_v1(
    GlacierMetalContext* ctx,
    GlacierMetalDispatchRetirementTelemetryV1* out)
{
    if (out) {
        memset(out, 0, sizeof(*out));
        out->abi_version =
            GLACIER_METAL_DISPATCH_RETIREMENT_TELEMETRY_ABI;
    }
    if (!ctx || !ctx->device || !out)
        return 1;
    @synchronized (ctx->device) {
        *out = ctx->dispatch_retirement_telemetry;
    }
    return 0;
}

int glacier_metal_live_command_count(
    GlacierMetalContext* ctx,
    uint64_t* out)
{
    if (!ctx || !ctx->device || !out)
        return 1;
    @synchronized (ctx->device) {
        *out = ctx->live_command_records;
    }
    return 0;
}

int glacier_metal_int4_registered_output_read(
    GlacierMetalContext* ctx,
    const GlacierMetalCommandToken* command_token,
    const uint8_t submission_binding[32],
    const GlacierMetalAsyncCompletion* expected_completion,
    const GlacierMetalBufferToken* output_token,
    float* output,
    uint64_t output_count)
{
    if (!ctx || !ctx->device || !command_token ||
        command_token->generation == 0 ||
        !submission_binding ||
        glacier_metal_binding_is_zero(submission_binding) ||
        !expected_completion ||
        expected_completion->abi_version !=
            GLACIER_METAL_ASYNC_COMPLETION_ABI ||
        expected_completion->reserved != 0 ||
        memcmp(
            &expected_completion->token,
            command_token,
            sizeof(*command_token)) != 0 ||
        memcmp(
            expected_completion->submission_binding,
            submission_binding,
            sizeof(expected_completion->submission_binding)) != 0 ||
        !output_token || !output ||
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
            GlacierMetalCommandRecord** link =
                glacier_metal_command_link_locked(
                    ctx,
                    command_token);
            if (!link ||
                !glacier_metal_command_matches_locked(
                    ctx,
                    *link,
                    submission_binding))
                return 2;
            GlacierMetalAsyncCompletion exact;
            glacier_metal_fill_completion_locked(
                *link,
                (*link)->completion_observed,
                &exact);
            if (exact.state !=
                    GLACIER_METAL_COMMAND_COMPLETED ||
                memcmp(
                    &exact,
                    expected_completion,
                    sizeof(exact)) != 0)
                return 3;
            GlacierMetalBufferAllocation* allocation =
                (*link)->allocations[3];
            if (!allocation ||
                allocation->owner != ctx ||
                allocation->active_command_references == 0 ||
                memcmp(
                    &allocation->token,
                    output_token,
                    sizeof(*output_token)) != 0 ||
                allocation->resource_length != output_bytes)
                return 4;
#if defined(GLACIER_METAL_TEST_FAULTS) && \
    GLACIER_METAL_TEST_FAULTS == 1
            GlacierMetalCommandRecord* record = *link;
            GlacierMetalTestCompletionFactsV2* facts =
                &record->test_completion_facts;
            if (record->test_completion_facts_ready == 1 &&
                glacier_metal_test_fault_plan_valid(
                    &record->test_fault_plan) &&
                record->test_fault_plan.kind ==
                    GLACIER_METAL_TEST_COMPLETED_OUTPUT_READ_REJECTION &&
                facts->callback_snapshot_observed == 1 &&
                facts->completion_overlay_applied == 0 &&
                glacier_metal_test_exact_physical_success(
                    &facts->physical) &&
                memcmp(
                    &facts->physical,
                    &facts->published,
                    sizeof(facts->physical)) == 0)
            {
                // The exact output role and completion have been
                // authenticated, but no pointer has been copied and caller
                // output remains untouched. Rejection stays sticky for this
                // command so an accidental retry cannot manufacture output
                // authority after the adapter quarantines it.
                facts->fault_applied = 1;
                facts->output_read_rejection_applied = 1;
                if (facts->output_read_rejection_count != UINT64_MAX)
                    facts->output_read_rejection_count += 1;
                return 6;
            }
#endif
            output_buffer = allocation->buffer;
            output_contents = output_buffer.contents;
            if (!output_contents)
                return 4;
        }
    } @catch (NSException* exception) {
        (void)exception;
        return 5;
    }
    memcpy(output, output_contents, (size_t)output_bytes);
    return 0;
}

static int glacier_metal_int4_matvec_observed_admitted(
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
    uint32_t command_status = 0;
    if (glacier_metal_observe_direct_command_buffer(
            ctx,
            cb,
            &command_status) != 0)
        return 3;
    if (observation)
        observation->command_status = command_status;
    if (command_status != MTLCommandBufferStatusCompleted)
        return 3;
    if (observation) {
        observation->current_allocated_after =
            ctx->device.currentAllocatedSize;
        observation->gpu_start_time = cb.GPUStartTime;
        observation->gpu_end_time = cb.GPUEndTime;
    }
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
        observation->abi_version =
            GLACIER_METAL_DISPATCH_ABI;
    }
    if (!ctx) return 1;
    if (glacier_metal_device_lifecycle_begin_admission(ctx) != 0)
        return 4;
    @try {
        return glacier_metal_int4_matvec_observed_admitted(
            ctx,
            weight,
            input,
            input_count,
            output,
            output_count,
            observation);
    } @catch (NSException* exception) {
        (void)exception;
        if (observation) {
            memset(observation, 0, sizeof(*observation));
            observation->abi_version =
                GLACIER_METAL_DISPATCH_ABI;
        }
        return 4;
    } @finally {
        glacier_metal_device_lifecycle_end_admission(ctx);
    }
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
