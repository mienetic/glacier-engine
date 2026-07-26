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
pub const completed_command_buffer_status: u32 = 4;

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
extern "C" fn glacier_metal_deinit(ctx: *MetalContext) void;
extern "C" fn glacier_metal_device_info(
    ctx: *MetalContext,
    out: *MetalDeviceInfo,
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
extern "C" fn glacier_metal_int4_matvec(
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

pub const MetalError = error{
    Unavailable,
    ShaderLoadFailed,
    DispatchFailed,
    MatmulFailed,
    UploadFailed,
    InvalidObservation,
};

pub const MetalBackend = struct {
    ctx: *MetalContext,
    live_weight_count: u64 = 0,
    completed_dispatch_count: u64 = 0,

    /// Initialize the Metal backend. `metallib_path` must point to a
    /// compiled .metallib (typically embedded next to the binary or built
    /// into the bundle).
    pub fn init(metallib_path: [*:0]const u8) MetalError!MetalBackend {
        const ctx = glacier_metal_init(metallib_path) orelse return MetalError.Unavailable;
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *MetalBackend) void {
        glacier_metal_deinit(self.ctx);
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
        const a_elements = std.math.mul(usize, m, k) catch return MetalError.MatmulFailed;
        const b_elements = std.math.mul(usize, n, k) catch return MetalError.MatmulFailed;
        const element_count = std.math.mul(usize, m, n) catch return MetalError.MatmulFailed;
        const expected_a = std.math.mul(usize, a_elements, @sizeOf(u16)) catch
            return MetalError.MatmulFailed;
        const expected_b = std.math.mul(usize, b_elements, @sizeOf(u16)) catch
            return MetalError.MatmulFailed;
        const expected_c = std.math.mul(usize, element_count, @sizeOf(u16)) catch
            return MetalError.MatmulFailed;
        if (a.len < expected_a or b.len < expected_b or c.len < expected_c)
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
        const rc = glacier_metal_int4_matvec(
            self.ctx,
            weight,
            input.ptr,
            input.len,
            output.ptr,
            output.len,
        );
        if (rc != 0) return MetalError.DispatchFailed;
        self.completed_dispatch_count += 1;
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
        const duration_nanoseconds_f64 = duration_seconds * 1_000_000_000.0;
        if (!std.math.isFinite(duration_nanoseconds_f64) or
            duration_nanoseconds_f64 < 1 or
            duration_nanoseconds_f64 >=
                @as(f64, @floatFromInt(std.math.maxInt(u64))))
            return MetalError.InvalidObservation;
        const duration_nanoseconds: u64 = @intFromFloat(
            duration_nanoseconds_f64,
        );
        self.completed_dispatch_count += 1;
        return .{
            .current_allocated_before = raw.current_allocated_before,
            .current_allocated_after = raw.current_allocated_after,
            .gpu_start_time_bits = @bitCast(raw.gpu_start_time),
            .gpu_end_time_bits = @bitCast(raw.gpu_end_time),
            .gpu_duration_nanoseconds = duration_nanoseconds,
            .command_status = raw.command_status,
        };
    }

    pub fn liveWeightCount(self: MetalBackend) u64 {
        return self.live_weight_count;
    }

    pub fn completedDispatchCount(self: MetalBackend) u64 {
        return self.completed_dispatch_count;
    }
};
