//! CPU backend — reference implementation, no GPU.
//!
//! Used for tests and as a correctness oracle. Weights live in a plain
//! host-side hash map keyed by PageId; "load" just records the byte count.
//! There is no dequant yet — the MVP CPU backend only validates the pager
//! mechanics, not numerical correctness.

const std = @import("std");
const core = @import("core");

pub const PageId = core.PageId;
pub const Precision = core.Precision;

pub const CpuBackend = struct {
    allocator: std.mem.Allocator,
    /// page_id -> bytes currently "resident" (we do not store the actual
    /// weight bytes in this stub).
    resident: std.AutoHashMap(PageId, u64),
    bytes_in: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) CpuBackend {
        return .{
            .allocator = allocator,
            .resident = std.AutoHashMap(PageId, u64).init(allocator),
        };
    }

    pub fn deinit(self: *CpuBackend) void {
        self.resident.deinit();
    }

    pub fn loadPage(self: *CpuBackend, page_id: PageId, precision: Precision) !void {
        // Pretend each page is 256 KiB at the requested precision.
        const bytes: u64 = @intFromFloat(@as(f32, 256 * 1024) * precision.bytesPerWeight() / 2.0);
        try self.resident.put(page_id, bytes);
        self.bytes_in += bytes;
    }

    pub fn evictPage(self: *CpuBackend, page_id: PageId) void {
        _ = self.resident.remove(page_id);
    }

    pub fn bytesTransferred(self: *const CpuBackend) u64 {
        return self.bytes_in;
    }

    /// Adapt into the pager's backend vtable.
    pub fn asBackend(self: *CpuBackend) core.Backend {
        return .{
            .ctx = self,
            .loadPageFn = loadPageShim,
            .evictPageFn = evictPageShim,
            .bytesTransferredFn = bytesTransferredShim,
        };
    }

    fn loadPageShim(ctx: *anyopaque, page_id: PageId, precision: Precision) core.Error!void {
        const self: *CpuBackend = @ptrCast(@alignCast(ctx));
        self.loadPage(page_id, precision) catch return core.Error.OutOfMemory;
    }
    fn evictPageShim(ctx: *anyopaque, page_id: PageId) core.Error!void {
        const self: *CpuBackend = @ptrCast(@alignCast(ctx));
        self.evictPage(page_id);
    }
    fn bytesTransferredShim(ctx: *anyopaque) u64 {
        const self: *CpuBackend = @ptrCast(@alignCast(ctx));
        return self.bytesTransferred();
    }
};

test "cpu backend round-trip" {
    var b = CpuBackend.init(std.testing.allocator);
    defer b.deinit();
    try b.loadPage(1, .int4);
    try std.testing.expect(b.bytes_in > 0);
    b.evictPage(1);
    try std.testing.expectEqual(@as(usize, 0), b.resident.count());
}
