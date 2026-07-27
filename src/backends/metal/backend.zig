//! Metal backend — Zig bindings to the Objective-C shim.
//!
//! The bridge functions live in shim.m (compiled as Objective-C). This
//! module declares them as extern "C" and provides a thin Zig wrapper
//! that the rest of the engine uses. Eventually this file grows into a
//! full backend implementing the core.Backend vtable; for now it just
//! exposes the dequant path so we can validate the Metal pipeline
//! end-to-end against the CPU reference.
//!
//! Build wiring (build.zig) handles:
//!   1. Compiling shaders/*.metal → shaders.metallib via xcrun.
//!   2. Compiling shim.m with -fobjc-arc and linking Metal.framework.
//!   3. Embedding the metallib path so this module can find it at runtime.

const std = @import("std");

/// Opaque handle to the Objective-C context (GlacierMetalContext*).
pub const MetalContext = opaque {};
pub const MetalInt4Weight = opaque {};

pub const device_info_abi: u64 = 0x474d_4449_0000_0001;
pub const dispatch_observation_abi: u64 = 0x474d_4452_0000_0001;
pub const allocation_limits_abi: u64 = 0x474d_4149_0000_0001;
pub const buffer_info_abi: u64 = 0x474d_4249_0000_0001;
pub const adapter_identity_abi: u64 = 0x474d_4144_0000_0001;
pub const async_submission_abi: u64 = 0x474d_4153_0000_0001;
pub const async_completion_abi: u64 = 0x474d_4143_0000_0001;
pub const completed_command_buffer_status: u32 = 4;
pub const error_command_buffer_status: u32 = 5;
pub const shared_storage_mode: u32 = 0;
pub const default_cpu_cache_mode: u32 = 0;

pub const MetalDeviceInfo = extern struct {
    abi_version: u64 = 0,
    registry_id: u64 = 0,
    current_allocated_size: u64 = 0,
    recommended_max_working_set_size: u64 = 0,
    location: u64 = 0,
    location_number: u64 = 0,
    max_threads_x: u64 = 0,
    max_threads_y: u64 = 0,
    max_threads_z: u64 = 0,
    low_power: u32 = 0,
    headless: u32 = 0,
    removable: u32 = 0,
    unified_memory: u32 = 0,
};

const RawDispatchObservation = extern struct {
    abi_version: u64 = 0,
    current_allocated_before: u64 = 0,
    current_allocated_after: u64 = 0,
    gpu_start_time: f64 = 0,
    gpu_end_time: f64 = 0,
    command_status: u32 = 0,
    reserved: u32 = 0,
};

pub const MetalAllocationLimits = extern struct {
    abi_version: u64 = 0,
    device_registry_id: u64 = 0,
    max_buffer_length: u64 = 0,
    resource_granularity: u64 = 0,
    storage_mode: u32 = 0,
    cpu_cache_mode: u32 = 0,
};

pub const MetalBufferInfo = extern struct {
    abi_version: u64 = 0,
    device_registry_id: u64 = 0,
    requested_length: u64 = 0,
    resource_length: u64 = 0,
    allocated_size: u64 = 0,
    storage_mode: u32 = 0,
    cpu_cache_mode: u32 = 0,
};

pub const MetalBufferToken = extern struct {
    context_nonce: [4]u64 = [_]u64{0} ** 4,
    generation: u64 = 0,

    pub fn isZero(self: MetalBufferToken) bool {
        return self.generation == 0 and
            self.context_nonce[0] == 0 and
            self.context_nonce[1] == 0 and
            self.context_nonce[2] == 0 and
            self.context_nonce[3] == 0;
    }
};

pub const MetalCommandToken = extern struct {
    context_nonce: [4]u64 = [_]u64{0} ** 4,
    generation: u64 = 0,

    pub fn isZero(self: MetalCommandToken) bool {
        return self.generation == 0 and
            self.context_nonce[0] == 0 and
            self.context_nonce[1] == 0 and
            self.context_nonce[2] == 0 and
            self.context_nonce[3] == 0;
    }
};

pub const MetalAsyncSubmissionDisposition = enum(u32) {
    submitted = 1,
    submitted_or_ambiguous = 2,
    _,
};

pub const MetalAsyncCommandState = enum(u32) {
    pending = 1,
    completed = 2,
    @"error" = 3,
    unknown = 4,
    _,
};

pub const MetalCommandErrorDomainKind = enum(u32) {
    none = 0,
    command_buffer = 1,
    other = 2,
    _,
};

pub const MetalAsyncSubmission = extern struct {
    abi_version: u64 = async_submission_abi,
    token: MetalCommandToken = .{},
    submission_binding: [32]u8 = [_]u8{0} ** 32,
    disposition: MetalAsyncSubmissionDisposition =
        .submitted_or_ambiguous,
    reserved: u32 = 0,
};

pub const MetalAsyncCompletion = extern struct {
    abi_version: u64 = async_completion_abi,
    token: MetalCommandToken = .{},
    submission_binding: [32]u8 = [_]u8{0} ** 32,
    current_allocated_before: u64 = 0,
    current_allocated_after: u64 = 0,
    gpu_start_time: f64 = 0,
    gpu_end_time: f64 = 0,
    error_code: i64 = 0,
    state: MetalAsyncCommandState = .pending,
    command_status: u32 = 0,
    error_domain_kind: MetalCommandErrorDomainKind = .none,
    error_present: u32 = 0,
    callback_fault: u32 = 0,
    reserved: u32 = 0,
};

pub const MetalAllocationAdapterIdentity = extern struct {
    abi_version: u64 = 0,
    context_nonce: [4]u64 = [_]u64{0} ** 4,
    adapter_instance: u64 = 0,
};

comptime {
    if (@sizeOf(MetalDeviceInfo) != 88 or
        @offsetOf(MetalDeviceInfo, "registry_id") != 8 or
        @offsetOf(MetalDeviceInfo, "current_allocated_size") != 16 or
        @offsetOf(MetalDeviceInfo, "low_power") != 72)
        @compileError("MetalDeviceInfo ABI layout changed");
    if (@sizeOf(RawDispatchObservation) != 48 or
        @offsetOf(RawDispatchObservation, "gpu_start_time") != 24 or
        @offsetOf(RawDispatchObservation, "command_status") != 40)
        @compileError("RawDispatchObservation ABI layout changed");
    if (@sizeOf(MetalAllocationLimits) != 40 or
        @offsetOf(MetalAllocationLimits, "storage_mode") != 32)
        @compileError("MetalAllocationLimits ABI layout changed");
    if (@sizeOf(MetalBufferInfo) != 48 or
        @offsetOf(MetalBufferInfo, "allocated_size") != 32)
        @compileError("MetalBufferInfo ABI layout changed");
    if (@sizeOf(MetalBufferToken) != 40 or
        @offsetOf(MetalBufferToken, "generation") != 32)
        @compileError("MetalBufferToken ABI layout changed");
    if (@sizeOf(MetalCommandToken) != 40 or
        @offsetOf(MetalCommandToken, "generation") != 32)
        @compileError("MetalCommandToken ABI layout changed");
    if (@sizeOf(MetalAsyncSubmission) != 88 or
        @offsetOf(MetalAsyncSubmission, "disposition") != 80)
        @compileError("MetalAsyncSubmission ABI layout changed");
    if (@sizeOf(MetalAsyncCompletion) != 144 or
        @offsetOf(MetalAsyncCompletion, "gpu_start_time") != 96 or
        @offsetOf(MetalAsyncCompletion, "state") != 120)
        @compileError("MetalAsyncCompletion ABI layout changed");
    if (@sizeOf(MetalAllocationAdapterIdentity) != 48 or
        @offsetOf(
            MetalAllocationAdapterIdentity,
            "adapter_instance",
        ) != 40)
        @compileError("MetalAllocationAdapterIdentity ABI layout changed");
}

pub const MetalDispatchTelemetry = struct {
    current_allocated_before: u64,
    current_allocated_after: u64,
    gpu_start_time_bits: u64,
    gpu_end_time_bits: u64,
    gpu_duration_nanoseconds: u64,
    command_status: u32,
};

extern "C" fn glacier_metal_init(metallib_path: [*:0]const u8) ?*MetalContext;
extern "C" fn glacier_metal_deinit(ctx: *MetalContext) c_int;
extern "C" fn glacier_metal_device_info(
    ctx: *MetalContext,
    out: *MetalDeviceInfo,
) c_int;
extern "C" fn glacier_metal_allocation_limits(
    ctx: *MetalContext,
    out: *MetalAllocationLimits,
) c_int;
extern "C" fn glacier_metal_claim_allocation_adapter(
    ctx: *MetalContext,
    out: *MetalAllocationAdapterIdentity,
) c_int;
extern "C" fn glacier_metal_buffer_create(
    ctx: *MetalContext,
    requested_length: u64,
    out: *MetalBufferToken,
) c_int;
extern "C" fn glacier_metal_buffer_info(
    ctx: *MetalContext,
    token: *const MetalBufferToken,
    out: *MetalBufferInfo,
) c_int;
extern "C" fn glacier_metal_buffer_release(
    ctx: *MetalContext,
    token: *const MetalBufferToken,
) c_int;
extern "C" fn glacier_metal_live_buffer_count(
    ctx: *MetalContext,
    out: *u64,
) c_int;
extern "C" fn glacier_metal_require_int4_matvec_support(
    ctx: *MetalContext,
) c_int;
extern "C" fn glacier_metal_dequant_int4(
    ctx: *MetalContext,
    payload: [*]const u8,
    payload_bytes: u64,
    out: [*]u8,
    num_elements: u32,
) c_int;

extern "C" fn glacier_metal_matmul(
    ctx: *MetalContext,
    a_bytes: [*]const u8,
    b_bytes: [*]const u8,
    c_bytes: [*]u8,
    m: u32,
    k: u32,
    n: u32,
) c_int;
extern "C" fn glacier_metal_int4_weight_create(
    ctx: *MetalContext,
    packed_weights: [*]const u8,
    packed_bytes: u64,
    scales: [*]const f32,
    scale_count: u64,
    group_size: u32,
    in_features: u32,
    out_features: u32,
) ?*MetalInt4Weight;
extern "C" fn glacier_metal_int4_weight_destroy(weight: *MetalInt4Weight) void;
extern "C" fn glacier_metal_int4_weight_read_output(
    weight: *MetalInt4Weight,
    output: [*]f32,
    output_count: u64,
) c_int;
extern "C" fn glacier_metal_int4_matvec_dispatch(
    ctx: *MetalContext,
    weight: *MetalInt4Weight,
    input: [*]const f32,
    input_count: u64,
    output: [*]f32,
    output_count: u64,
) c_int;
extern "C" fn glacier_metal_int4_matvec_observed(
    ctx: *MetalContext,
    weight: *MetalInt4Weight,
    input: [*]const f32,
    input_count: u64,
    output: [*]f32,
    output_count: u64,
    observation: *RawDispatchObservation,
) c_int;
extern "C" fn glacier_metal_int4_registered_buffers_submit_async(
    ctx: *MetalContext,
    packed_token: *const MetalBufferToken,
    scales_token: *const MetalBufferToken,
    input_token: *const MetalBufferToken,
    output_token: *const MetalBufferToken,
    packed_weights: [*]const u8,
    packed_bytes: u64,
    scales: [*]const f32,
    scale_count: u64,
    input: [*]const f32,
    input_count: u64,
    group_size: u32,
    in_features: u32,
    out_features: u32,
    submission_binding: *const [32]u8,
    submission: *MetalAsyncSubmission,
) c_int;
extern "C" fn glacier_metal_registered_dispatch_poll(
    ctx: *MetalContext,
    token: *const MetalCommandToken,
    submission_binding: *const [32]u8,
    completion: *MetalAsyncCompletion,
) c_int;
extern "C" fn glacier_metal_registered_dispatch_wait(
    ctx: *MetalContext,
    token: *const MetalCommandToken,
    submission_binding: *const [32]u8,
    completion: *MetalAsyncCompletion,
) c_int;
extern "C" fn glacier_metal_registered_dispatch_finalize(
    ctx: *MetalContext,
    token: *const MetalCommandToken,
    submission_binding: *const [32]u8,
    expected_completion: *const MetalAsyncCompletion,
) c_int;
extern "C" fn glacier_metal_live_command_count(
    ctx: *MetalContext,
    out: *u64,
) c_int;
extern "C" fn glacier_metal_int4_registered_output_read(
    ctx: *MetalContext,
    command_token: *const MetalCommandToken,
    submission_binding: *const [32]u8,
    expected_completion: *const MetalAsyncCompletion,
    output_token: *const MetalBufferToken,
    output: [*]f32,
    output_count: u64,
) c_int;

pub const MetalError = error{
    Unavailable,
    ShaderLoadFailed,
    DispatchFailed,
    MatmulFailed,
    UploadFailed,
    AllocationFailed,
    InvalidObservation,
};

fn digestIsZero(value: [32]u8) bool {
    return std.mem.eql(
        u8,
        &value,
        &([_]u8{0} ** 32),
    );
}

fn commandTokenValid(token: MetalCommandToken) bool {
    return token.generation != 0 and
        !(token.context_nonce[0] == 0 and
            token.context_nonce[1] == 0 and
            token.context_nonce[2] == 0 and
            token.context_nonce[3] == 0);
}

pub fn validateMetalAsyncSubmission(
    submission: MetalAsyncSubmission,
) MetalError!void {
    if (submission.abi_version != async_submission_abi or
        !commandTokenValid(submission.token) or
        digestIsZero(submission.submission_binding) or
        submission.reserved != 0)
        return MetalError.InvalidObservation;
    switch (submission.disposition) {
        .submitted, .submitted_or_ambiguous => {},
        _ => return MetalError.InvalidObservation,
    }
}

fn asyncErrorFieldsValid(
    completion: MetalAsyncCompletion,
) bool {
    if (completion.error_present > 1 or
        completion.callback_fault > 1)
        return false;
    if (completion.error_present == 0)
        return completion.error_domain_kind == .none and
            completion.error_code == 0;
    return completion.error_domain_kind == .command_buffer or
        completion.error_domain_kind == .other;
}

pub fn validateMetalAsyncCompletion(
    completion: MetalAsyncCompletion,
) MetalError!void {
    if (completion.abi_version != async_completion_abi or
        !commandTokenValid(completion.token) or
        digestIsZero(completion.submission_binding) or
        completion.reserved != 0 or
        !asyncErrorFieldsValid(completion))
        return MetalError.InvalidObservation;

    switch (completion.state) {
        .pending => {
            if (completion.current_allocated_before != 0 or
                completion.current_allocated_after != 0 or
                completion.gpu_start_time != 0 or
                completion.gpu_end_time != 0 or
                completion.command_status != 0 or
                completion.error_present != 0 or
                completion.callback_fault != 0)
                return MetalError.InvalidObservation;
        },
        .completed => {
            if (completion.command_status !=
                completed_command_buffer_status or
                completion.callback_fault != 0 or
                completion.error_present != 0 or
                completion.current_allocated_before == 0 or
                completion.current_allocated_after == 0 or
                !std.math.isFinite(completion.gpu_start_time) or
                !std.math.isFinite(completion.gpu_end_time) or
                completion.gpu_start_time <= 0 or
                completion.gpu_end_time <=
                    completion.gpu_start_time)
                return MetalError.InvalidObservation;
        },
        .@"error" => {
            if (completion.command_status !=
                error_command_buffer_status or
                completion.callback_fault != 0 or
                completion.current_allocated_before == 0)
                return MetalError.InvalidObservation;
        },
        .unknown => {
            if (completion.callback_fault == 0 and
                (completion.command_status ==
                    completed_command_buffer_status or
                    completion.command_status ==
                        error_command_buffer_status))
                return MetalError.InvalidObservation;
        },
        _ => return MetalError.InvalidObservation,
    }
}

fn validateCompletionForSubmission(
    submission: MetalAsyncSubmission,
    completion: MetalAsyncCompletion,
) MetalError!void {
    try validateMetalAsyncSubmission(submission);
    try validateMetalAsyncCompletion(completion);
    if (!std.meta.eql(submission.token, completion.token) or
        !std.mem.eql(
            u8,
            &submission.submission_binding,
            &completion.submission_binding,
        ))
        return MetalError.InvalidObservation;
}

fn recordPhysicalCompletion(
    completed_dispatch_count: *u64,
) MetalError!void {
    completed_dispatch_count.* = std.math.add(
        u64,
        completed_dispatch_count.*,
        1,
    ) catch return MetalError.DispatchFailed;
}

fn recordPhysicalCompletionSaturating(
    completed_dispatch_count: *u64,
) void {
    if (completed_dispatch_count.* != std.math.maxInt(u64))
        completed_dispatch_count.* += 1;
}

/// Account for a command that the native bridge reports as physically
/// completed before interpreting optional observation evidence. Keeping this
/// helper independent of caller output makes it impossible for invalid
/// telemetry to publish a candidate through this step.
fn recordCompletedObservation(
    completed_dispatch_count: *u64,
    raw: RawDispatchObservation,
) MetalError!MetalDispatchTelemetry {
    try recordPhysicalCompletion(completed_dispatch_count);
    return telemetryFromCompletedObservation(raw);
}

fn telemetryFromCompletedObservation(
    raw: RawDispatchObservation,
) MetalError!MetalDispatchTelemetry {
    if (raw.abi_version != dispatch_observation_abi or
        raw.command_status != completed_command_buffer_status or
        raw.reserved != 0 or
        raw.current_allocated_before == 0 or
        raw.current_allocated_after == 0 or
        !std.math.isFinite(raw.gpu_start_time) or
        !std.math.isFinite(raw.gpu_end_time) or
        raw.gpu_start_time <= 0 or
        raw.gpu_end_time <= raw.gpu_start_time)
        return MetalError.InvalidObservation;
    const duration_seconds = raw.gpu_end_time - raw.gpu_start_time;
    const duration_nanoseconds_f64 =
        duration_seconds * 1_000_000_000.0;
    if (!std.math.isFinite(duration_nanoseconds_f64) or
        duration_nanoseconds_f64 < 1 or
        duration_nanoseconds_f64 >=
            @as(f64, @floatFromInt(std.math.maxInt(u64))))
        return MetalError.InvalidObservation;
    return .{
        .current_allocated_before = raw.current_allocated_before,
        .current_allocated_after = raw.current_allocated_after,
        .gpu_start_time_bits = @bitCast(raw.gpu_start_time),
        .gpu_end_time_bits = @bitCast(raw.gpu_end_time),
        .gpu_duration_nanoseconds = @intFromFloat(
            duration_nanoseconds_f64,
        ),
        .command_status = raw.command_status,
    };
}

/// Convert an exact final asynchronous success snapshot into the existing
/// completed-dispatch telemetry. Pending, error, and unknown states remain
/// distinct and cannot be relabelled as successful completion.
pub fn telemetryForAsyncCompletion(
    completion: MetalAsyncCompletion,
) MetalError!MetalDispatchTelemetry {
    try validateMetalAsyncCompletion(completion);
    if (completion.state != .completed)
        return MetalError.InvalidObservation;
    return telemetryFromCompletedObservation(.{
        .abi_version = dispatch_observation_abi,
        .current_allocated_before = completion.current_allocated_before,
        .current_allocated_after = completion.current_allocated_after,
        .gpu_start_time = completion.gpu_start_time,
        .gpu_end_time = completion.gpu_end_time,
        .command_status = completion.command_status,
    });
}

fn finalizeObservedDispatch(
    completed_dispatch_count: *u64,
    raw: RawDispatchObservation,
    weight: *MetalInt4Weight,
    output: []f32,
    comptime read_output: anytype,
) MetalError!MetalDispatchTelemetry {
    const telemetry = try recordCompletedObservation(
        completed_dispatch_count,
        raw,
    );
    if (read_output(weight, output.ptr, output.len) != 0)
        return MetalError.DispatchFailed;
    return telemetry;
}

const RegisteredMatvecGeometry = struct {
    packed_bytes: u64,
    scale_count: u64,
    scales_bytes: u64,
    input_count: u64,
    input_bytes: u64,
    output_count: u64,
    output_bytes: u64,
};

fn registeredMatvecGeometry(
    group_size: u32,
    in_features: u32,
    out_features: u32,
) MetalError!RegisteredMatvecGeometry {
    if (group_size == 0 or
        !std.math.isPowerOfTwo(group_size) or
        in_features == 0 or
        out_features == 0)
        return MetalError.DispatchFailed;

    const elements =
        @as(u64, in_features) * @as(u64, out_features);
    if (elements > std.math.maxInt(u32))
        return MetalError.DispatchFailed;
    const scale_count =
        (elements + @as(u64, group_size) - 1) /
        @as(u64, group_size);
    return .{
        .packed_bytes = (elements + 1) / 2,
        .scale_count = scale_count,
        .scales_bytes = scale_count * @sizeOf(f32),
        .input_count = in_features,
        .input_bytes = @as(u64, in_features) * @sizeOf(f32),
        .output_count = out_features,
        .output_bytes = @as(u64, out_features) * @sizeOf(f32),
    };
}

fn validateRegisteredMatvecTokens(
    tokens: [4]MetalBufferToken,
) MetalError!void {
    for (tokens, 0..) |token, index| {
        if (token.generation == 0 or
            (token.context_nonce[0] == 0 and
                token.context_nonce[1] == 0 and
                token.context_nonce[2] == 0 and
                token.context_nonce[3] == 0))
            return MetalError.InvalidObservation;
        if (!std.mem.eql(
            u64,
            &tokens[0].context_nonce,
            &token.context_nonce,
        ))
            return MetalError.InvalidObservation;
        for (tokens[0..index]) |prior| {
            if (std.meta.eql(prior, token))
                return MetalError.InvalidObservation;
        }
    }
}

fn synchronousRegisteredDispatchBinding(
    tokens: [4]MetalBufferToken,
    geometry: RegisteredMatvecGeometry,
    packed_weights: []const u8,
    scales: []const f32,
    input: []const f32,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-metal-synchronous-registered-dispatch-v1\x00",
    );
    for (tokens) |token| {
        hash.update(std.mem.asBytes(&token.context_nonce));
        hash.update(std.mem.asBytes(&token.generation));
    }
    hash.update(std.mem.asBytes(&geometry));
    hash.update(packed_weights);
    hash.update(std.mem.sliceAsBytes(scales));
    hash.update(std.mem.sliceAsBytes(input));
    var result: [32]u8 = undefined;
    hash.final(&result);
    // SHA-256 producing zero is cryptographically negligible, but the native
    // token ABI reserves zero as invalid. Keep this private compatibility
    // binding total without changing caller-owned data.
    if (digestIsZero(result)) result[0] = 1;
    return result;
}

pub const MetalBackend = struct {
    ctx: *MetalContext,
    live_weight_count: u64 = 0,
    live_buffer_count: u64 = 0,
    completed_dispatch_count: u64 = 0,
    compatibility_unresolved_submission: ?MetalAsyncSubmission = null,
    compatibility_dispatch_mutex: std.Thread.Mutex = .{},
    allocation_mutex: std.Thread.Mutex = .{},

    /// Initialize the Metal backend. `metallib_path` must point to a
    /// compiled .metallib (typically embedded next to the binary or built
    /// into the bundle).
    pub fn init(metallib_path: [*:0]const u8) MetalError!MetalBackend {
        const ctx = glacier_metal_init(metallib_path) orelse return MetalError.Unavailable;
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *MetalBackend) void {
        self.compatibility_dispatch_mutex.lock();
        defer self.compatibility_dispatch_mutex.unlock();
        if (self.live_weight_count != 0)
            @panic("Metal backend deinit with live weights");
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        const zig_live_buffers = self.live_buffer_count;
        const native_live_buffers =
            self.nativeLiveBufferCountUnlocked() catch
                std.math.maxInt(u64);
        const native_live_commands =
            self.nativeLiveCommandCountUnlocked() catch
                std.math.maxInt(u64);
        if (self.compatibility_unresolved_submission != null or
            zig_live_buffers != 0 or
            native_live_buffers != 0 or
            native_live_commands != 0)
            @panic("Metal backend deinit with live native ownership");
        if (glacier_metal_deinit(self.ctx) != 0)
            @panic("Metal shim refused context deinit");
    }

    /// Resolve the exact persistent INT4 matrix-vector pipeline without
    /// allocating weights or dispatching work. Capability adapters call this
    /// before advertising that operation and repeat it before acquisition.
    pub fn requireInt4MatvecSupport(
        self: *MetalBackend,
    ) MetalError!void {
        if (glacier_metal_require_int4_matvec_support(self.ctx) != 0)
            return MetalError.ShaderLoadFailed;
    }

    /// Return bounded, fixed-width facts for the exact selected Metal device.
    /// `recommended_max_working_set_size` is capability context, not a
    /// residency measurement.
    pub fn deviceInfo(self: *MetalBackend) MetalError!MetalDeviceInfo {
        var result: MetalDeviceInfo = .{};
        if (glacier_metal_device_info(self.ctx, &result) != 0)
            return MetalError.InvalidObservation;
        if (result.abi_version != device_info_abi or
            result.registry_id == 0 or
            result.max_threads_x == 0 or
            result.max_threads_y == 0 or
            result.max_threads_z == 0 or
            result.low_power > 1 or
            result.headless > 1 or
            result.removable > 1 or
            result.unified_memory > 1)
            return MetalError.InvalidObservation;
        return result;
    }

    /// Return immutable policy facts for direct Shared MTLBuffer resources.
    /// Resource bytes are exact `MTLBuffer.length` bytes. This does not
    /// predict `MTLResource.allocatedSize`, which Metal exposes only after
    /// creation.
    pub fn allocationLimits(
        self: *MetalBackend,
    ) MetalError!MetalAllocationLimits {
        var result: MetalAllocationLimits = .{};
        if (glacier_metal_allocation_limits(self.ctx, &result) != 0)
            return MetalError.InvalidObservation;
        if (result.abi_version != allocation_limits_abi or
            result.device_registry_id == 0 or
            result.max_buffer_length == 0 or
            result.resource_granularity != 1 or
            result.storage_mode != shared_storage_mode or
            result.cpu_cache_mode != default_cpu_cache_mode)
            return MetalError.InvalidObservation;
        return result;
    }

    /// Claim a collision-resistant context identity plus a never-reused
    /// instance number for one allocation adapter authority.
    pub fn claimAllocationAdapterIdentity(
        self: *MetalBackend,
    ) MetalError!MetalAllocationAdapterIdentity {
        var result: MetalAllocationAdapterIdentity = .{};
        if (glacier_metal_claim_allocation_adapter(
            self.ctx,
            &result,
        ) != 0)
            return MetalError.Unavailable;
        if (result.abi_version != adapter_identity_abi or
            result.adapter_instance == 0 or
            (result.context_nonce[0] == 0 and
                result.context_nonce[1] == 0 and
                result.context_nonce[2] == 0 and
                result.context_nonce[3] == 0))
            return MetalError.InvalidObservation;
        return result;
    }

    fn releaseCreatedBufferOrPanic(
        self: *MetalBackend,
        token: MetalBufferToken,
    ) void {
        if (glacier_metal_buffer_release(self.ctx, &token) != 0)
            @panic(
                "Metal shim rejected a token it just created",
            );
    }

    /// Create one real direct Shared MTLBuffer. The opaque native handle must
    /// remain private to the owning adapter and be released exactly once.
    pub fn createBufferAllocation(
        self: *MetalBackend,
        requested_length: u64,
    ) MetalError!MetalBufferToken {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        const limits = try self.allocationLimits();
        if (requested_length == 0 or
            requested_length > limits.max_buffer_length)
            return MetalError.AllocationFailed;
        var token: MetalBufferToken = .{};
        if (glacier_metal_buffer_create(
            self.ctx,
            requested_length,
            &token,
        ) != 0)
            return MetalError.AllocationFailed;
        if (token.isZero())
            @panic("Metal shim returned a zero successful token");
        const info = self.inspectBufferAllocation(token) catch {
            self.releaseCreatedBufferOrPanic(token);
            return MetalError.AllocationFailed;
        };
        if (info.device_registry_id != limits.device_registry_id or
            info.requested_length != requested_length or
            info.resource_length != requested_length)
        {
            self.releaseCreatedBufferOrPanic(token);
            return MetalError.AllocationFailed;
        }
        self.live_buffer_count = std.math.add(
            u64,
            self.live_buffer_count,
            1,
        ) catch {
            self.releaseCreatedBufferOrPanic(token);
            return MetalError.AllocationFailed;
        };
        return token;
    }

    /// Observe the exact live resource. `allocated_size` is per-object Metal
    /// evidence, not a device-wide delta and not a residency claim.
    pub fn inspectBufferAllocation(
        self: *MetalBackend,
        token: MetalBufferToken,
    ) MetalError!MetalBufferInfo {
        if (token.isZero()) return MetalError.InvalidObservation;
        var result: MetalBufferInfo = .{};
        if (glacier_metal_buffer_info(
            self.ctx,
            &token,
            &result,
        ) != 0)
            return MetalError.InvalidObservation;
        if (result.abi_version != buffer_info_abi or
            result.device_registry_id == 0 or
            result.requested_length == 0 or
            result.resource_length != result.requested_length or
            result.allocated_size < result.resource_length or
            result.storage_mode != shared_storage_mode or
            result.cpu_cache_mode != default_cpu_cache_mode)
            return MetalError.InvalidObservation;
        return result;
    }

    pub fn destroyBufferAllocation(
        self: *MetalBackend,
        token: MetalBufferToken,
    ) MetalError!void {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        if (token.isZero() or self.live_buffer_count == 0)
            return MetalError.InvalidObservation;
        if (glacier_metal_buffer_release(self.ctx, &token) != 0)
            return MetalError.InvalidObservation;
        self.live_buffer_count -= 1;
    }

    fn nativeLiveBufferCountUnlocked(
        self: *MetalBackend,
    ) MetalError!u64 {
        var result: u64 = 0;
        if (glacier_metal_live_buffer_count(
            self.ctx,
            &result,
        ) != 0)
            return MetalError.InvalidObservation;
        return result;
    }

    /// Native shim registry count, independent from Zig adapter slots and the
    /// Zig-side bookkeeping counter.
    pub fn nativeLiveBufferCount(
        self: *MetalBackend,
    ) MetalError!u64 {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        return self.nativeLiveBufferCountUnlocked();
    }

    fn nativeLiveCommandCountUnlocked(
        self: *MetalBackend,
    ) MetalError!u64 {
        var result: u64 = 0;
        if (glacier_metal_live_command_count(
            self.ctx,
            &result,
        ) != 0)
            return MetalError.InvalidObservation;
        return result;
    }

    /// Authoritative native registry count. Pending, ambiguous, completed, and
    /// error commands remain live until exact finalization.
    pub fn nativeLiveCommandCount(
        self: *MetalBackend,
    ) MetalError!u64 {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        return self.nativeLiveCommandCountUnlocked();
    }

    /// Dispatch the INT4→FP16 dequant kernel. `out` must be at least
    /// `num_elements * 2` bytes. Returns the decoded FP16 bytes.
    pub fn dequantInt4(
        self: *MetalBackend,
        payload: []const u8,
        out: []u8,
        num_elements: u32,
    ) MetalError!void {
        const header_size: usize = 16;
        if (payload.len < header_size) return MetalError.DispatchFailed;
        if (std.mem.readInt(u32, payload[0..4], .little) != 0x514F4954)
            return MetalError.DispatchFailed;
        const header_elements = std.mem.readInt(u32, payload[4..8], .little);
        const group_size = std.mem.readInt(u32, payload[8..12], .little);
        if (header_elements != num_elements or group_size == 0 or payload[12] != 1)
            return MetalError.DispatchFailed;

        const element_count: usize = num_elements;
        const group_size_usize: usize = group_size;
        const group_count = element_count / group_size_usize +
            @intFromBool(element_count % group_size_usize != 0);
        const scales_bytes = std.math.mul(usize, group_count, @sizeOf(f32)) catch
            return MetalError.DispatchFailed;
        const packed_bytes = element_count / 2 + @intFromBool(element_count % 2 != 0);
        const payload_body = std.math.add(usize, scales_bytes, packed_bytes) catch
            return MetalError.DispatchFailed;
        const required_payload = std.math.add(usize, header_size, payload_body) catch
            return MetalError.DispatchFailed;
        const required_output = std.math.mul(usize, element_count, @sizeOf(u16)) catch
            return MetalError.DispatchFailed;
        if (payload.len < required_payload or out.len < required_output)
            return MetalError.DispatchFailed;
        const rc = glacier_metal_dequant_int4(
            self.ctx,
            payload.ptr,
            payload.len,
            out.ptr,
            num_elements,
        );
        if (rc != 0) return MetalError.DispatchFailed;
    }

    /// Dispatch the tiled FP16 matmul: C[M,N] = A[M,K] × B^T[N,K].
    /// A and B are FP16 buffers (row-major), C is FP16 output.
    /// Each buffer is raw bytes (half = 2 bytes per element).
    pub fn matmulF16(
        self: *MetalBackend,
        a: []const u8, // [M*K*2] bytes
        b: []const u8, // [N*K*2] bytes
        c: []u8, // [M*N*2] bytes output
        m: u32,
        k: u32,
        n: u32,
    ) MetalError!void {
        if (m == 0 or k == 0 or n == 0)
            return MetalError.MatmulFailed;
        const m_size = std.math.cast(usize, m) orelse
            return MetalError.MatmulFailed;
        const k_size = std.math.cast(usize, k) orelse
            return MetalError.MatmulFailed;
        const n_size = std.math.cast(usize, n) orelse
            return MetalError.MatmulFailed;
        const a_elements = std.math.mul(usize, m_size, k_size) catch
            return MetalError.MatmulFailed;
        const b_elements = std.math.mul(usize, n_size, k_size) catch
            return MetalError.MatmulFailed;
        const element_count = std.math.mul(usize, m_size, n_size) catch
            return MetalError.MatmulFailed;
        const expected_a = std.math.mul(usize, a_elements, @sizeOf(u16)) catch
            return MetalError.MatmulFailed;
        const expected_b = std.math.mul(usize, b_elements, @sizeOf(u16)) catch
            return MetalError.MatmulFailed;
        const expected_c = std.math.mul(usize, element_count, @sizeOf(u16)) catch
            return MetalError.MatmulFailed;
        // Exact lengths keep shape mistakes fail-closed and guarantee that a
        // rejected call cannot partially initialize a caller's output slice.
        if (a.len != expected_a or b.len != expected_b or c.len != expected_c)
            return MetalError.MatmulFailed;
        const rc = glacier_metal_matmul(
            self.ctx,
            a.ptr,
            b.ptr,
            c.ptr,
            m,
            k,
            n,
        );
        if (rc != 0) return MetalError.MatmulFailed;
    }

    /// Upload a packed INT4 matrix to a persistent Metal buffer. The caller
    /// must destroy the returned handle before deinitializing the backend.
    pub fn createInt4Weight(
        self: *MetalBackend,
        packed_weights: []const u8,
        scales: []const f32,
        group_size: u32,
        in_features: u32,
        out_features: u32,
    ) MetalError!*MetalInt4Weight {
        const result = glacier_metal_int4_weight_create(
            self.ctx,
            packed_weights.ptr,
            packed_weights.len,
            scales.ptr,
            scales.len,
            group_size,
            in_features,
            out_features,
        ) orelse return MetalError.UploadFailed;
        self.live_weight_count = std.math.add(
            u64,
            self.live_weight_count,
            1,
        ) catch {
            glacier_metal_int4_weight_destroy(result);
            return MetalError.UploadFailed;
        };
        return result;
    }

    pub fn destroyInt4Weight(self: *MetalBackend, weight: *MetalInt4Weight) void {
        glacier_metal_int4_weight_destroy(weight);
        if (self.live_weight_count > 0) self.live_weight_count -= 1;
    }

    pub fn matvecInt4(
        self: *MetalBackend,
        weight: *MetalInt4Weight,
        input: []const f32,
        output: []f32,
    ) MetalError!void {
        if (self.completed_dispatch_count ==
            std.math.maxInt(u64))
            return MetalError.DispatchFailed;
        const rc = glacier_metal_int4_matvec_dispatch(
            self.ctx,
            weight,
            input.ptr,
            input.len,
            output.ptr,
            output.len,
        );
        if (rc != 0) return MetalError.DispatchFailed;
        try recordPhysicalCompletion(
            &self.completed_dispatch_count,
        );
        if (glacier_metal_int4_weight_read_output(
            weight,
            output.ptr,
            output.len,
        ) != 0)
            return MetalError.DispatchFailed;
    }

    /// Dispatch the same persistent INT4 path while retaining the command
    /// buffer's completed GPU interval and direct Metal allocation samples.
    pub fn matvecInt4Observed(
        self: *MetalBackend,
        weight: *MetalInt4Weight,
        input: []const f32,
        output: []f32,
    ) MetalError!MetalDispatchTelemetry {
        if (self.completed_dispatch_count ==
            std.math.maxInt(u64))
            return MetalError.DispatchFailed;
        var raw: RawDispatchObservation = .{};
        const rc = glacier_metal_int4_matvec_observed(
            self.ctx,
            weight,
            input.ptr,
            input.len,
            output.ptr,
            output.len,
            &raw,
        );
        if (rc != 0) return MetalError.DispatchFailed;
        return finalizeObservedDispatch(
            &self.completed_dispatch_count,
            raw,
            weight,
            output,
            glacier_metal_int4_weight_read_output,
        );
    }

    /// Non-blocking submission through four exact live registry allocations.
    /// The caller-supplied binding is retained by the native registry and is
    /// required unchanged by poll, wait, and finalization. No host output
    /// pointer survives this call.
    pub fn submitMatvecInt4RegisteredBuffers(
        self: *MetalBackend,
        submission_binding: [32]u8,
        packed_token: MetalBufferToken,
        scales_token: MetalBufferToken,
        input_token: MetalBufferToken,
        output_token: MetalBufferToken,
        packed_weights: []const u8,
        scales: []const f32,
        input: []const f32,
        output_count: u64,
        group_size: u32,
        in_features: u32,
        out_features: u32,
    ) MetalError!MetalAsyncSubmission {
        const geometry = try registeredMatvecGeometry(
            group_size,
            in_features,
            out_features,
        );
        if (@as(u64, @intCast(packed_weights.len)) !=
            geometry.packed_bytes or
            @as(u64, @intCast(scales.len)) !=
                geometry.scale_count or
            @as(u64, @intCast(input.len)) !=
                geometry.input_count or
            output_count != geometry.output_count or
            digestIsZero(submission_binding))
            return MetalError.DispatchFailed;

        const tokens = [4]MetalBufferToken{
            packed_token,
            scales_token,
            input_token,
            output_token,
        };
        try validateRegisteredMatvecTokens(tokens);

        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        if (self.completed_dispatch_count ==
            std.math.maxInt(u64))
            return MetalError.DispatchFailed;

        const infos = [4]MetalBufferInfo{
            try self.inspectBufferAllocation(packed_token),
            try self.inspectBufferAllocation(scales_token),
            try self.inspectBufferAllocation(input_token),
            try self.inspectBufferAllocation(output_token),
        };
        const expected_lengths = [4]u64{
            geometry.packed_bytes,
            geometry.scales_bytes,
            geometry.input_bytes,
            geometry.output_bytes,
        };
        for (infos, expected_lengths) |info, expected_length| {
            if (info.device_registry_id !=
                infos[0].device_registry_id)
                return MetalError.InvalidObservation;
            if (info.resource_length != expected_length)
                return MetalError.DispatchFailed;
        }

        var submission: MetalAsyncSubmission = .{};
        if (glacier_metal_int4_registered_buffers_submit_async(
            self.ctx,
            &packed_token,
            &scales_token,
            &input_token,
            &output_token,
            packed_weights.ptr,
            geometry.packed_bytes,
            scales.ptr,
            geometry.scale_count,
            input.ptr,
            geometry.input_count,
            group_size,
            in_features,
            out_features,
            &submission_binding,
            &submission,
        ) != 0)
            return MetalError.DispatchFailed;
        validateMetalAsyncSubmission(submission) catch
            @panic(
                "native Metal submit returned success without a valid registry token",
            );
        if (!std.mem.eql(
            u8,
            &submission.submission_binding,
            &submission_binding,
        ))
            @panic(
                "native Metal submit returned success with a mismatched binding",
            );
        return submission;
    }

    /// Non-blocking exact replay of the native completed-handler snapshot.
    pub fn pollRegisteredDispatch(
        self: *MetalBackend,
        submission: MetalAsyncSubmission,
    ) MetalError!MetalAsyncCompletion {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        try validateMetalAsyncSubmission(submission);
        var completion: MetalAsyncCompletion = .{};
        if (glacier_metal_registered_dispatch_poll(
            self.ctx,
            &submission.token,
            &submission.submission_binding,
            &completion,
        ) != 0)
            return MetalError.InvalidObservation;
        try validateCompletionForSubmission(
            submission,
            completion,
        );
        return completion;
    }

    /// Wait for the exact native command without holding the native registry
    /// monitor. A driver exception or non-final status remains `unknown` or
    /// `pending`; neither is converted into terminal evidence.
    pub fn waitRegisteredDispatch(
        self: *MetalBackend,
        submission: MetalAsyncSubmission,
    ) MetalError!MetalAsyncCompletion {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        try validateMetalAsyncSubmission(submission);
        if (submission.disposition != .submitted)
            return MetalError.InvalidObservation;
        var completion: MetalAsyncCompletion = .{};
        if (glacier_metal_registered_dispatch_wait(
            self.ctx,
            &submission.token,
            &submission.submission_binding,
            &completion,
        ) != 0)
            return MetalError.InvalidObservation;
        try validateCompletionForSubmission(
            submission,
            completion,
        );
        return completion;
    }

    /// Copy output only for the exact completed command snapshot and exact
    /// registered output role while both native records remain live.
    pub fn readMatvecInt4RegisteredOutput(
        self: *MetalBackend,
        submission: MetalAsyncSubmission,
        completion: MetalAsyncCompletion,
        output_token: MetalBufferToken,
        output: []f32,
    ) MetalError!void {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        try validateCompletionForSubmission(
            submission,
            completion,
        );
        if (completion.state != .completed or output.len == 0)
            return MetalError.DispatchFailed;
        if (glacier_metal_int4_registered_output_read(
            self.ctx,
            &submission.token,
            &submission.submission_binding,
            &completion,
            &output_token,
            output.ptr,
            output.len,
        ) != 0)
            return MetalError.DispatchFailed;
    }

    /// Consume one exact completed/error command snapshot. Pending, unknown,
    /// foreign, stale, binding-changed, or snapshot-changed calls retain the
    /// native record. A successful call increments the completed counter once
    /// unless that diagnostic counter has already saturated.
    pub fn finalizeRegisteredDispatch(
        self: *MetalBackend,
        submission: MetalAsyncSubmission,
        completion: MetalAsyncCompletion,
    ) MetalError!void {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        try validateCompletionForSubmission(
            submission,
            completion,
        );
        if (completion.state != .completed and
            completion.state != .@"error")
            return MetalError.InvalidObservation;

        if (glacier_metal_registered_dispatch_finalize(
            self.ctx,
            &submission.token,
            &submission.submission_binding,
            &completion,
        ) != 0)
            return MetalError.InvalidObservation;
        if (self.compatibility_unresolved_submission) |retained| {
            if (std.meta.eql(retained, submission))
                self.compatibility_unresolved_submission = null;
        }
        recordPhysicalCompletionSaturating(
            &self.completed_dispatch_count,
        );
    }

    fn retainCompatibilityUnresolvedSubmission(
        self: *MetalBackend,
        submission: MetalAsyncSubmission,
    ) void {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        if (self.compatibility_unresolved_submission) |retained| {
            if (!std.meta.eql(retained, submission))
                @panic(
                    "Metal compatibility dispatch replaced unresolved ownership",
                );
            return;
        }
        self.compatibility_unresolved_submission = submission;
    }

    fn finalizeCompatibilityRegisteredDispatch(
        self: *MetalBackend,
        submission: MetalAsyncSubmission,
        completion: MetalAsyncCompletion,
    ) MetalError!void {
        self.finalizeRegisteredDispatch(
            submission,
            completion,
        ) catch |err| {
            self.retainCompatibilityUnresolvedSubmission(
                submission,
            );
            return err;
        };
    }

    /// Return the exact native token retained after the synchronous
    /// compatibility API encounters a nonterminal or ambiguous state.
    /// Callers may use the normal poll/finalize API; the token is cleared only
    /// by exact native finalization.
    pub fn compatibilityUnresolvedSubmission(
        self: *MetalBackend,
    ) ?MetalAsyncSubmission {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        return self.compatibility_unresolved_submission;
    }

    /// Synchronous compatibility path implemented entirely through the native
    /// command registry. New lifetime-aware callers should retain the returned
    /// async token until their private Bank settlement callback.
    pub fn matvecInt4RegisteredBuffersObserved(
        self: *MetalBackend,
        packed_token: MetalBufferToken,
        scales_token: MetalBufferToken,
        input_token: MetalBufferToken,
        output_token: MetalBufferToken,
        packed_weights: []const u8,
        scales: []const f32,
        input: []const f32,
        output: []f32,
        group_size: u32,
        in_features: u32,
        out_features: u32,
    ) MetalError!MetalDispatchTelemetry {
        self.compatibility_dispatch_mutex.lock();
        defer self.compatibility_dispatch_mutex.unlock();
        if (self.compatibilityUnresolvedSubmission() != null)
            return MetalError.DispatchFailed;
        const geometry = try registeredMatvecGeometry(
            group_size,
            in_features,
            out_features,
        );
        const tokens = [4]MetalBufferToken{
            packed_token,
            scales_token,
            input_token,
            output_token,
        };
        const binding = synchronousRegisteredDispatchBinding(
            tokens,
            geometry,
            packed_weights,
            scales,
            input,
        );
        const submission =
            try self.submitMatvecInt4RegisteredBuffers(
                binding,
                packed_token,
                scales_token,
                input_token,
                output_token,
                packed_weights,
                scales,
                input,
                @intCast(output.len),
                group_size,
                in_features,
                out_features,
            );
        if (submission.disposition != .submitted) {
            self.retainCompatibilityUnresolvedSubmission(
                submission,
            );
            return MetalError.DispatchFailed;
        }
        const completion =
            self.waitRegisteredDispatch(submission) catch |err| {
                self.retainCompatibilityUnresolvedSubmission(
                    submission,
                );
                return err;
            };
        switch (completion.state) {
            .completed => {},
            .@"error" => {
                try self.finalizeCompatibilityRegisteredDispatch(
                    submission,
                    completion,
                );
                return MetalError.DispatchFailed;
            },
            .pending, .unknown => {
                self.retainCompatibilityUnresolvedSubmission(
                    submission,
                );
                return MetalError.DispatchFailed;
            },
            _ => return MetalError.InvalidObservation,
        }

        const telemetry =
            telemetryForAsyncCompletion(completion) catch |err| {
                try self.finalizeCompatibilityRegisteredDispatch(
                    submission,
                    completion,
                );
                return err;
            };
        self.readMatvecInt4RegisteredOutput(
            submission,
            completion,
            output_token,
            output,
        ) catch |err| {
            try self.finalizeCompatibilityRegisteredDispatch(
                submission,
                completion,
            );
            return err;
        };
        try self.finalizeCompatibilityRegisteredDispatch(
            submission,
            completion,
        );
        return telemetry;
    }

    pub fn liveWeightCount(self: MetalBackend) u64 {
        return self.live_weight_count;
    }

    pub fn liveBufferCount(self: *MetalBackend) u64 {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        return self.live_buffer_count;
    }

    pub fn completedDispatchCount(self: *MetalBackend) u64 {
        self.allocation_mutex.lock();
        defer self.allocation_mutex.unlock();
        return self.completed_dispatch_count;
    }
};

const MutatingOutputReader = struct {
    fn read(
        _: *MetalInt4Weight,
        output: [*]f32,
        _: u64,
    ) c_int {
        output[0] = 99.0;
        return 0;
    }
};

test "invalid completed observation is counted before output publication" {
    var completed_dispatch_count: u64 = 0;
    var output = [_]f32{ 11.0, -7.0, 3.5 };
    const sentinel = output;
    const invalid: RawDispatchObservation = .{
        .abi_version = dispatch_observation_abi,
        .current_allocated_before = 4096,
        .current_allocated_after = 4096,
        .gpu_start_time = 1.0,
        .gpu_end_time = 1.0,
        .command_status = completed_command_buffer_status,
    };

    try std.testing.expectError(
        MetalError.InvalidObservation,
        finalizeObservedDispatch(
            &completed_dispatch_count,
            invalid,
            @ptrFromInt(1),
            &output,
            MutatingOutputReader.read,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        completed_dispatch_count,
    );
    try std.testing.expectEqualSlices(f32, &sentinel, &output);
}

test "async completion accounting saturates without blocking finalization" {
    var completed_dispatch_count: u64 =
        std.math.maxInt(u64) - 1;
    recordPhysicalCompletionSaturating(
        &completed_dispatch_count,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        completed_dispatch_count,
    );
    recordPhysicalCompletionSaturating(
        &completed_dispatch_count,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        completed_dispatch_count,
    );
}

test "registered matvec geometry requires exact shader-safe dimensions" {
    const geometry = try registeredMatvecGeometry(64, 37, 5);
    try std.testing.expectEqual(@as(u64, 93), geometry.packed_bytes);
    try std.testing.expectEqual(@as(u64, 3), geometry.scale_count);
    try std.testing.expectEqual(@as(u64, 12), geometry.scales_bytes);
    try std.testing.expectEqual(@as(u64, 148), geometry.input_bytes);
    try std.testing.expectEqual(@as(u64, 20), geometry.output_bytes);

    try std.testing.expectError(
        MetalError.DispatchFailed,
        registeredMatvecGeometry(0, 37, 5),
    );
    try std.testing.expectError(
        MetalError.DispatchFailed,
        registeredMatvecGeometry(63, 37, 5),
    );
    try std.testing.expectError(
        MetalError.DispatchFailed,
        registeredMatvecGeometry(
            64,
            std.math.maxInt(u32),
            2,
        ),
    );
}

test "registered matvec roles reject zero foreign and duplicate tokens" {
    const nonce = [4]u64{ 1, 2, 3, 4 };
    try validateRegisteredMatvecTokens(.{
        .{ .context_nonce = nonce, .generation = 1 },
        .{ .context_nonce = nonce, .generation = 2 },
        .{ .context_nonce = nonce, .generation = 3 },
        .{ .context_nonce = nonce, .generation = 4 },
    });
    try std.testing.expectError(
        MetalError.InvalidObservation,
        validateRegisteredMatvecTokens(.{
            .{},
            .{ .context_nonce = nonce, .generation = 2 },
            .{ .context_nonce = nonce, .generation = 3 },
            .{ .context_nonce = nonce, .generation = 4 },
        }),
    );
    try std.testing.expectError(
        MetalError.InvalidObservation,
        validateRegisteredMatvecTokens(.{
            .{ .context_nonce = nonce, .generation = 1 },
            .{ .context_nonce = nonce, .generation = 1 },
            .{ .context_nonce = nonce, .generation = 3 },
            .{ .context_nonce = nonce, .generation = 4 },
        }),
    );
    try std.testing.expectError(
        MetalError.InvalidObservation,
        validateRegisteredMatvecTokens(.{
            .{ .context_nonce = nonce, .generation = 1 },
            .{ .context_nonce = nonce, .generation = 2 },
            .{
                .context_nonce = .{ 9, 8, 7, 6 },
                .generation = 3,
            },
            .{ .context_nonce = nonce, .generation = 4 },
        }),
    );
}
