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

extern "C" fn glacier_metal_init(metallib_path: [*:0]const u8) ?*MetalContext;
extern "C" fn glacier_metal_deinit(ctx: *MetalContext) void;
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

pub const MetalError = error{
    Unavailable,
    ShaderLoadFailed,
    DispatchFailed,
    MatmulFailed,
    UploadFailed,
};

pub const MetalBackend = struct {
    ctx: *MetalContext,

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
        return glacier_metal_int4_weight_create(
            self.ctx,
            packed_weights.ptr,
            packed_weights.len,
            scales.ptr,
            scales.len,
            group_size,
            in_features,
            out_features,
        ) orelse MetalError.UploadFailed;
    }

    pub fn destroyInt4Weight(_: *MetalBackend, weight: *MetalInt4Weight) void {
        glacier_metal_int4_weight_destroy(weight);
    }

    pub fn matvecInt4(
        self: *MetalBackend,
        weight: *MetalInt4Weight,
        input: []const f32,
        output: []f32,
    ) MetalError!void {
        const rc = glacier_metal_int4_matvec(
            self.ctx,
            weight,
            input.ptr,
            input.len,
            output.ptr,
            output.len,
        );
        if (rc != 0) return MetalError.DispatchFailed;
    }
};
