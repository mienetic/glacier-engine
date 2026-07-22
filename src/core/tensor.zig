//! Dense tensor — the basic value type that flows through every backend.
//!
//! Kept deliberately minimal: row-major, owned data, one dtype at a time.
//! Backends accept `Tensor` for activations and produce `Tensor` for output;
//! the pager does not touch this — it only moves weight bytes around.
//!
//! MVP scope: FP32 only on the compute path. FP16/BF16 will be added when
//! the Metal backend lands (Metal buffers are FP16-native). We do NOT
//! attempt mixed-precision arithmetic on CPU — it is a reference path.

const std = @import("std");

pub const DType = enum {
    f32,
    f16, // stored but not yet computed on CPU
    bf16, // stored but not yet computed on CPU
};

pub const TensorError = error{
    ShapeMismatch,
    DTypeUnsupported,
    OutOfMemory,
    ExecutorBusy,
};

/// Row-major tensor. `shape.len` is the rank; we cap at 4D for now since
/// transformer weights are at most 2D and activations at most 3D (batch
/// dim is folded into rows for the MVP).
pub const Tensor = struct {
    dtype: DType,
    /// Logical dimensions, outermost first. e.g. [out_features, in_features].
    shape: []const usize,
    /// Flat row-major data. `data.len == product(shape)`.
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn shapeLen(self: Tensor) usize {
        var n: usize = 1;
        for (self.shape) |d| n *= d;
        return n;
    }

    pub fn deinit(self: *Tensor) void {
        // Free the data buffer with the alignment it was allocated at.
        // For FP32 tensors we allocated with .@"4" alignment then took
        // sliceAsBytes; free must use the matching alignment.
        if (self.dtype == .f32) {
            const n = self.data.len / @sizeOf(f32);
            const ptr: [*]align(4) f32 = @ptrCast(@alignCast(self.data.ptr));
            self.allocator.free(ptr[0..n]);
        } else {
            self.allocator.free(self.data);
        }
        self.allocator.free(self.shape);
    }

    /// View the data as f32. Asserts the dtype matches; callers must check.
    pub fn asF32(self: Tensor) []f32 {
        std.debug.assert(self.dtype == .f32);
        const n = self.shapeLen();
        const ptr: [*]f32 = @ptrCast(@alignCast(self.data.ptr));
        return ptr[0..n];
    }

    /// Same as asF32 but uses @intFromPtr to bypass alignment checks. Use
    /// ONLY when the underlying buffer is known to be f32-aligned (e.g.
    /// allocated via alloc(f32) and viewed through sliceAsBytes).
    pub fn asF32Unsafe(self: Tensor) []f32 {
        std.debug.assert(self.dtype == .f32);
        const n = self.shapeLen();
        const addr = @intFromPtr(self.data.ptr);
        if (addr % @alignOf(f32) != 0) {
            @panic("asF32Unsafe: underlying buffer not f32-aligned");
        }
        const ptr: [*]f32 = @ptrFromInt(addr);
        return ptr[0..n];
    }
};

/// Allocate an uninitialized FP32 tensor with the given shape.
/// Allocates as f32 (not u8) so the buffer is guaranteed f32-aligned,
/// which lets asF32/asF32Unsafe avoid alignment panics on every kernel.
pub fn allocF32(allocator: std.mem.Allocator, shape: []const usize) !Tensor {
    var n: usize = 1;
    for (shape) |d| n *= d;
    // Force 4-byte alignment explicitly — some allocators return 1-byte
    // alignment for small allocs, which would break f32 reinterpretation.
    const f32_data = try allocator.alignedAlloc(f32, .@"4", n);
    errdefer allocator.free(f32_data);
    const shape_copy = try allocator.dupe(usize, shape);
    errdefer allocator.free(shape_copy);
    return .{
        .dtype = .f32,
        .shape = shape_copy,
        .data = std.mem.sliceAsBytes(f32_data),
        .allocator = allocator,
    };
}

/// Allocate an FP32 tensor initialized to zero.
pub fn zerosF32(allocator: std.mem.Allocator, shape: []const usize) !Tensor {
    var t = try allocF32(allocator, shape);
    @memset(t.asF32(), 0);
    return t;
}

/// Build a tensor from an existing f32 slice (copies the data).
pub fn fromF32(allocator: std.mem.Allocator, shape: []const usize, values: []const f32) !Tensor {
    var n: usize = 1;
    for (shape) |d| n *= d;
    if (values.len != n) return TensorError.ShapeMismatch;
    var t = try allocF32(allocator, shape);
    @memcpy(t.asF32(), values);
    return t;
}
