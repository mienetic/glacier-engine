//! Backend interface — what every hardware target must implement.
//!
//! The core pager talks only to `core.Backend`. This file is the canonical
//! helper for constructing that vtable from a concrete backend struct, so
//! each backend (metal, cpu, ...) does not reinvent the glue.

const std = @import("std");
const core = @import("core");

pub const Backend = core.Backend;
pub const PageId = core.PageId;
pub const Precision = core.Precision;
pub const Error = core.Error;

/// Generic vtable target every concrete backend implements. The pager
/// calls these; the backend does the real work on its hardware.
pub const BackendImpl = struct {
    /// Called by the pager to make `page_id` resident at `precision`.
    /// Must dequantize from the on-disk precision if needed.
    loadPage: *const fn (ctx: *anyopaque, page_id: PageId, precision: Precision) Error!void,
    /// Called by the pager to drop `page_id` from fast memory.
    evictPage: *const fn (ctx: *anyopaque, page_id: PageId) Error!void,
    /// Total bytes the backend has pulled across the bus. Used by the
    /// scheduler / bench to measure the thing we are optimizing for.
    bytesTransferred: *const fn (ctx: *anyopaque) u64,
};

/// Wrap a concrete backend struct into the pager's vtable.
pub fn adapt(concrete: anytype, comptime impl: BackendImpl) Backend {
    const T = @TypeOf(concrete);
    const Ptr = *T;
    // Stash the static vtable in a comptime-generated closure namespace.
    return .{
        .ctx = @ptrCast(concrete),
        .loadPageFn = struct {
            fn call(ctx: *anyopaque, page_id: PageId, p: Precision) Error!void {
                const self: Ptr = @ptrCast(@alignCast(ctx));
                try impl.loadPage(@ptrCast(self), page_id, p);
            }
        }.call,
        .evictPageFn = struct {
            fn call(ctx: *anyopaque, page_id: PageId) Error!void {
                const self: Ptr = @ptrCast(@alignCast(ctx));
                try impl.evictPage(@ptrCast(self), page_id);
            }
        }.call,
        .bytesTransferredFn = struct {
            fn call(ctx: *anyopaque) u64 {
                const self: Ptr = @ptrCast(@alignCast(ctx));
                return impl.bytesTransferred(@ptrCast(self));
            }
        }.call,
    };
}
