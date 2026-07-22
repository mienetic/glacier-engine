//! Demand-paged weight store (W + P axes).
//!
//! This is the heart of the MVP. See docs/PAGING.md.
//!
//! The pager owns a page table and a resident set. It does NOT know about
//! hardware — all I/O goes through a Backend interface so this module is
//! fully testable with a fake backend on any platform.

const std = @import("std");
const precision_mod = @import("precision.zig");

pub const Precision = precision_mod.Precision;

/// Opaque identifier for a weight page. Matches the page index in the
/// Glacier file format (docs/FORMAT_SPEC.md).
pub const PageId = u64;

/// Where a page currently lives.
pub const Location = enum {
    cold, // only on disk / mmap; not resident
    hot, // resident in fast memory
};

/// A single slot in the resident set.
pub const ResidentSlot = struct {
    page_id: PageId,
    precision: Precision, // precision at which it is currently resident
    bytes: u64,
    last_used: u64, // monotonic tick; higher = more recent
};

/// Counter handed to the pager for LRU ordering. The pager does not care
/// what it represents — wall clock, token index, or a test fixture.
pub const Tick = u64;

pub const Error = error{
    PageUnknown,
    PrecisionUnavailable,
    BudgetExceeded,
    BackendFailed,
    OutOfMemory,
};

/// Contract every backend must satisfy. The pager calls into this; the
/// backend does the actual dequant + copy into fast memory.
pub const Backend = struct {
    ctx: *anyopaque,
    loadPageFn: *const fn (ctx: *anyopaque, page_id: PageId, precision: Precision) Error!void,
    evictPageFn: *const fn (ctx: *anyopaque, page_id: PageId) Error!void,
    bytesTransferredFn: *const fn (ctx: *anyopaque) u64,

    pub fn loadPage(self: Backend, page_id: PageId, precision: Precision) Error!void {
        return self.loadPageFn(self.ctx, page_id, precision);
    }
    pub fn evictPage(self: Backend, page_id: PageId) Error!void {
        return self.evictPageFn(self.ctx, page_id);
    }
    pub fn bytesTransferred(self: Backend) u64 {
        return self.bytesTransferredFn(self.ctx);
    }
};

/// One entry in the page table. Populated from the model's page index at
/// load time. Stores the *stored* precision(s) and payload size; the pager
/// tracks the *resident* precision separately in `ResidentSlot`.
pub const PageEntry = struct {
    page_id: PageId,
    layer_idx: u32,
    payload_bytes: u64,
    /// Largest precision available on disk for this page (cheapest upgrade
    /// ceiling). For the MVP every page has exactly one stored precision.
    stored_precision: Precision,
};

pub const PageTable = struct {
    entries: []PageEntry,
    /// Fast lookup by id. For small models a linear scan is fine; this is
    /// here so we can scale without changing the pager API.
    id_to_index: std.AutoHashMap(PageId, usize),

    pub fn deinit(self: *PageTable, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.id_to_index.deinit();
    }

    pub fn get(self: *const PageTable, id: PageId) Error!*const PageEntry {
        const idx = self.id_to_index.get(id) orelse return Error.PageUnknown;
        return &self.entries[idx];
    }
};

pub const Config = struct {
    /// Maximum bytes allowed in the resident set at once. Acts like RAM
    /// size in OS paging.
    budget_bytes: u64 = 512 * 1024 * 1024, // 512 MiB default
};

/// The pager itself. Owns the resident set and the eviction policy.
pub const Pager = struct {
    allocator: std.mem.Allocator,
    table: *PageTable,
    backend: Backend,
    config: Config,

    resident: std.AutoHashMap(PageId, ResidentSlot),
    bytes_resident: u64 = 0,
    tick: Tick = 0,

    // stats
    loads: u64 = 0,
    evictions: u64 = 0,
    hits: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        table: *PageTable,
        backend: Backend,
        config: Config,
    ) Pager {
        return .{
            .allocator = allocator,
            .table = table,
            .backend = backend,
            .config = config,
            .resident = std.AutoHashMap(PageId, ResidentSlot).init(allocator),
        };
    }

    pub fn deinit(self: *Pager) void {
        self.resident.deinit();
    }

    /// Make sure `page_id` is resident at precision >= `required`.
    /// Evicts LRU pages as needed. This is the only public entry point
    /// the forward pass calls.
    pub fn ensureResident(
        self: *Pager,
        page_id: PageId,
        required: Precision,
    ) Error!void {
        const entry = try self.table.get(page_id);
        // A successful return is a hard precision contract. Do not evict an
        // existing coarse representation or ask the backend to load one when
        // the stored page cannot satisfy the request.
        if (!entry.stored_precision.satisfies(required))
            return Error.PrecisionUnavailable;

        self.tick += 1;

        if (self.resident.getPtr(page_id)) |slot| {
            if (slot.precision.satisfies(required)) {
                slot.last_used = self.tick;
                self.hits += 1;
                return; // hot path: nothing to do
            }
            // Resident but too coarse — evict and reload at higher precision.
            try self.evictInternal(page_id);
        }

        const load_prec = required;

        try self.makeRoom(entry.payload_bytes);
        self.backend.loadPage(page_id, load_prec) catch return Error.BackendFailed;

        self.resident.put(page_id, .{
            .page_id = page_id,
            .precision = load_prec,
            .bytes = entry.payload_bytes,
            .last_used = self.tick,
        }) catch {
            // The backend load completed but ownership could not be recorded.
            // Best-effort rollback avoids an untracked resident page.
            self.backend.evictPage(page_id) catch {};
            return Error.OutOfMemory;
        };
        self.bytes_resident += entry.payload_bytes;
        self.loads += 1;
    }

    /// Hint that we will not need `page_id` again soon. Optional; the pager
    /// is correct without it, this just helps the eviction policy.
    pub fn release(self: *Pager, page_id: PageId) Error!void {
        if (self.resident.fetchRemove(page_id)) |kv| {
            self.bytes_resident -= kv.value.bytes;
            self.backend.evictPage(page_id) catch return Error.BackendFailed;
            self.evictions += 1;
        }
    }

    fn makeRoom(self: *Pager, incoming_bytes: u64) Error!void {
        if (incoming_bytes > self.config.budget_bytes) return Error.BudgetExceeded;
        while (self.bytes_resident > self.config.budget_bytes - incoming_bytes) {
            const victim = self.pickEvictionVictim() orelse return Error.BudgetExceeded;
            try self.evictInternal(victim);
        }
    }

    /// LRU victim selection. O(n) over the resident set — fine for MVP;
    /// a heap is a drop-in upgrade later.
    fn pickEvictionVictim(self: *Pager) ?PageId {
        var min_tick: u64 = std.math.maxInt(u64);
        var min_id: ?PageId = null;
        var it = self.resident.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_used < min_tick) {
                min_tick = entry.value_ptr.last_used;
                min_id = entry.key_ptr.*;
            }
        }
        return min_id;
    }

    fn evictInternal(self: *Pager, page_id: PageId) Error!void {
        if (self.resident.fetchRemove(page_id)) |kv| {
            self.bytes_resident -= kv.value.bytes;
            self.backend.evictPage(page_id) catch return Error.BackendFailed;
            self.evictions += 1;
        }
    }

    pub fn bytesTransferred(self: *const Pager) u64 {
        return self.backend.bytesTransferred();
    }
};

// ---------------------------------------------------------------------------
// Tests with a fake backend — no hardware required.
// ---------------------------------------------------------------------------

const testing = std.testing;

const FakeBackend = struct {
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    resident_pages: std.AutoHashMap(PageId, void),

    fn init(allocator: std.mem.Allocator) FakeBackend {
        return .{ .resident_pages = std.AutoHashMap(PageId, void).init(allocator) };
    }
    fn deinit(self: *FakeBackend) void {
        self.resident_pages.deinit();
    }

    fn load(ctx: *anyopaque, page_id: PageId, _: Precision) Error!void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        try self.resident_pages.put(page_id, {});
        self.bytes_in += 1;
    }
    fn evict(ctx: *anyopaque, page_id: PageId) Error!void {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        _ = self.resident_pages.remove(page_id);
        self.bytes_out += 1;
    }
    fn bytesTransferred(ctx: *anyopaque) u64 {
        const self: *FakeBackend = @ptrCast(@alignCast(ctx));
        return self.bytes_in;
    }
    fn asBackend(self: *FakeBackend) Backend {
        return .{
            .ctx = self,
            .loadPageFn = FakeBackend.load,
            .evictPageFn = FakeBackend.evict,
            .bytesTransferredFn = FakeBackend.bytesTransferred,
        };
    }
};

fn makeTable(allocator: std.mem.Allocator, pages: []const PageEntry) !*PageTable {
    const t = try allocator.create(PageTable);
    const entries = try allocator.dupe(PageEntry, pages);
    var id_map = std.AutoHashMap(PageId, usize).init(allocator);
    for (entries, 0..) |e, i| try id_map.put(e.page_id, i);
    t.* = .{ .entries = entries, .id_to_index = id_map };
    return t;
}

test "ensureResident loads on first access" {
    var fb = FakeBackend.init(testing.allocator);
    defer fb.deinit();
    const table = try makeTable(testing.allocator, &.{
        .{ .page_id = 0, .layer_idx = 0, .payload_bytes = 1024, .stored_precision = .int4 },
        .{ .page_id = 1, .layer_idx = 1, .payload_bytes = 1024, .stored_precision = .int4 },
    });
    defer {
        table.deinit(testing.allocator);
        testing.allocator.destroy(table);
    }

    var pager = Pager.init(testing.allocator, table, fb.asBackend(), .{ .budget_bytes = 4096 });
    defer pager.deinit();

    try pager.ensureResident(0, .int4);
    try testing.expectEqual(@as(u64, 1), pager.loads);
    try testing.expectEqual(@as(u64, 0), pager.hits);
}

test "ensureResident hits on second access" {
    var fb = FakeBackend.init(testing.allocator);
    defer fb.deinit();
    const table = try makeTable(testing.allocator, &.{
        .{ .page_id = 0, .layer_idx = 0, .payload_bytes = 1024, .stored_precision = .int4 },
    });
    defer {
        table.deinit(testing.allocator);
        testing.allocator.destroy(table);
    }

    var pager = Pager.init(testing.allocator, table, fb.asBackend(), .{ .budget_bytes = 4096 });
    defer pager.deinit();

    try pager.ensureResident(0, .int4);
    try pager.ensureResident(0, .int4);
    try testing.expectEqual(@as(u64, 1), pager.loads);
    try testing.expectEqual(@as(u64, 1), pager.hits);
}

test "LRU evicts oldest page when budget exceeded" {
    var fb = FakeBackend.init(testing.allocator);
    defer fb.deinit();
    // Budget fits exactly two pages.
    const table = try makeTable(testing.allocator, &.{
        .{ .page_id = 10, .layer_idx = 0, .payload_bytes = 1024, .stored_precision = .int4 },
        .{ .page_id = 11, .layer_idx = 1, .payload_bytes = 1024, .stored_precision = .int4 },
        .{ .page_id = 12, .layer_idx = 2, .payload_bytes = 1024, .stored_precision = .int4 },
    });
    defer {
        table.deinit(testing.allocator);
        testing.allocator.destroy(table);
    }

    var pager = Pager.init(testing.allocator, table, fb.asBackend(), .{ .budget_bytes = 2048 });
    defer pager.deinit();

    try pager.ensureResident(10, .int4);
    try pager.ensureResident(11, .int4);
    // Loading 12 must evict 10 (oldest).
    try pager.ensureResident(12, .int4);
    try testing.expect(!pager.resident.contains(10));
    try testing.expect(pager.resident.contains(11));
    try testing.expect(pager.resident.contains(12));
    try testing.expectEqual(@as(u64, 1), pager.evictions);
}

test "precision upgrade evicts and reloads" {
    var fb = FakeBackend.init(testing.allocator);
    defer fb.deinit();
    const table = try makeTable(testing.allocator, &.{
        .{ .page_id = 0, .layer_idx = 0, .payload_bytes = 1024, .stored_precision = .fp16 },
    });
    defer {
        table.deinit(testing.allocator);
        testing.allocator.destroy(table);
    }

    var pager = Pager.init(testing.allocator, table, fb.asBackend(), .{ .budget_bytes = 1 << 20 });
    defer pager.deinit();

    try pager.ensureResident(0, .int4);
    try testing.expectEqual(Precision.int4, pager.resident.get(0).?.precision);

    // Requesting FP16 must evict the INT4 copy and reload at FP16.
    try pager.ensureResident(0, .fp16);
    try testing.expectEqual(Precision.fp16, pager.resident.get(0).?.precision);
    try testing.expectEqual(@as(u64, 2), pager.loads);
}

test "unavailable precision fails without evicting a valid coarse page" {
    var fb = FakeBackend.init(testing.allocator);
    defer fb.deinit();
    const table = try makeTable(testing.allocator, &.{
        .{ .page_id = 0, .layer_idx = 0, .payload_bytes = 1024, .stored_precision = .int4 },
    });
    defer {
        table.deinit(testing.allocator);
        testing.allocator.destroy(table);
    }

    var pager = Pager.init(testing.allocator, table, fb.asBackend(), .{ .budget_bytes = 4096 });
    defer pager.deinit();

    try testing.expectError(Error.PrecisionUnavailable, pager.ensureResident(0, .fp16));
    try testing.expectEqual(@as(u64, 0), pager.loads);
    try testing.expectEqual(@as(u64, 0), pager.evictions);
    try testing.expectEqual(@as(u64, 0), pager.bytes_resident);

    try pager.ensureResident(0, .int4);
    try testing.expectError(Error.PrecisionUnavailable, pager.ensureResident(0, .fp16));
    try testing.expectEqual(Precision.int4, pager.resident.get(0).?.precision);
    try testing.expectEqual(@as(u64, 1), pager.loads);
    try testing.expectEqual(@as(u64, 0), pager.evictions);
    try testing.expectEqual(@as(u64, 1024), pager.bytes_resident);
}

test "page larger than budget fails without integer overflow" {
    var fb = FakeBackend.init(testing.allocator);
    defer fb.deinit();
    const table = try makeTable(testing.allocator, &.{
        .{ .page_id = 0, .layer_idx = 0, .payload_bytes = std.math.maxInt(u64), .stored_precision = .int4 },
    });
    defer {
        table.deinit(testing.allocator);
        testing.allocator.destroy(table);
    }

    var pager = Pager.init(testing.allocator, table, fb.asBackend(), .{ .budget_bytes = 4096 });
    defer pager.deinit();

    try testing.expectError(Error.BudgetExceeded, pager.ensureResident(0, .int4));
    try testing.expectEqual(@as(u64, 0), pager.loads);
    try testing.expectEqual(@as(u64, 0), pager.bytes_resident);
}
