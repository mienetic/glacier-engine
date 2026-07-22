//! Model configuration sidecar.
//!
//! The loader currently recovers geometry (num_heads, head_dim, etc.) from
//! page metadata via heuristics. That works for the synthetic fixture but
//! is fragile — real HF checkpoints need exact values that the page index
//! cannot always disambiguate. This module reads an optional JSON sidecar
//! `<model.glacier>.json` (or `<model.glacier>` next to a sibling
//! `config.json`) and overrides the heuristics when present.
//!
//! Schema (all fields optional; missing fields fall back to heuristics):
//!   {
//!     "dim": 1024,
//!     "hidden_dim": 2816,
//!     "num_layers": 24,
//!     "vocab_size": 151936,
//!     "num_heads": 16,
//!     "head_dim": 64,
//!     "rms_eps": 1e-6,
//!     "rope_theta": 1000000.0
//!   }

const std = @import("std");

pub const ConfigError = error{
    BadJson,
    OutOfMemory,
    FileError,
};

pub const ModelConfigOverride = struct {
    dim: ?usize = null,
    hidden_dim: ?usize = null,
    num_layers: ?usize = null,
    vocab_size: ?usize = null,
    num_heads: ?usize = null,
    head_dim: ?usize = null,
    rms_eps: ?f32 = null,
    rope_theta: ?f32 = null,
    num_kv_heads: ?usize = null,
    tie_word_embeddings: ?bool = null,
};

/// Try to load `<model_path>.json`. Returns an empty override (all null)
/// if the sidecar is absent — callers merge it over their heuristic
/// values, so missing fields keep the heuristic result.
pub fn loadSidecar(
    allocator: std.mem.Allocator,
    model_path: []const u8,
) ConfigError!ModelConfigOverride {
    const sidecar_path = std.fmt.allocPrint(allocator, "{s}.json", .{model_path}) catch
        return ConfigError.OutOfMemory;
    defer allocator.free(sidecar_path);

    const f = std.fs.cwd().openFile(sidecar_path, .{}) catch
        return .{}; // Missing sidecar is not an error.
    defer f.close();

    const stat = f.stat() catch return ConfigError.FileError;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch
        return ConfigError.OutOfMemory;
    defer allocator.free(buf);
    const n = f.readAll(buf) catch return ConfigError.FileError;
    return parseJson(allocator, buf[0..n]);
}

fn parseJson(allocator: std.mem.Allocator, json_bytes: []const u8) ConfigError!ModelConfigOverride {
    // Use std.json.parseFromValueLeaky with an arena so we don't manage
    // intermediate allocations manually.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        json_bytes,
        .{},
    ) catch return ConfigError.BadJson;
    if (parsed != .object) return ConfigError.BadJson;

    var out: ModelConfigOverride = .{};
    const obj = parsed.object;
    out.dim = getOptionalUsize(obj, "dim") orelse getOptionalUsize(obj, "hidden_size");
    // HF configs use "intermediate_size" for the MLP hidden dim.
    out.hidden_dim = getOptionalUsize(obj, "hidden_dim") orelse getOptionalUsize(obj, "intermediate_size");
    out.num_layers = getOptionalUsize(obj, "num_layers") orelse getOptionalUsize(obj, "num_hidden_layers");
    out.vocab_size = getOptionalUsize(obj, "vocab_size");
    out.num_heads = getOptionalUsize(obj, "num_heads") orelse getOptionalUsize(obj, "num_attention_heads");
    out.head_dim = getOptionalUsize(obj, "head_dim");
    out.rms_eps = getOptionalF32(obj, "rms_eps") orelse getOptionalF32(obj, "rms_norm_eps");
    out.rope_theta = getOptionalF32(obj, "rope_theta");
    out.num_kv_heads = getOptionalUsize(obj, "num_kv_heads") orelse getOptionalUsize(obj, "num_key_value_heads");
    out.tie_word_embeddings = getOptionalBool(obj, "tie_word_embeddings");
    return out;
}

fn getOptionalUsize(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const v = obj.get(key) orelse return null;
    if (v != .integer) return null;
    if (v.integer < 0) return null;
    return @intCast(v.integer);
}

fn getOptionalF32(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const v = obj.get(key) orelse return null;
    if (v == .integer) return @floatFromInt(v.integer);
    if (v == .float) return @floatCast(v.float);
    return null;
}

fn getOptionalBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    if (v == .bool) return v.bool;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TempSidecar = struct {
    tmp: testing.TmpDir,
    model_path: []u8,
    json_path: []u8,

    fn init() !TempSidecar {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
        defer testing.allocator.free(root);
        const model_path = try std.fs.path.join(testing.allocator, &.{ root, "model.glacier" });
        errdefer testing.allocator.free(model_path);
        const json_path = try std.fmt.allocPrint(testing.allocator, "{s}.json", .{model_path});
        return .{ .tmp = tmp, .model_path = model_path, .json_path = json_path };
    }

    fn deinit(self: *TempSidecar) void {
        testing.allocator.free(self.json_path);
        testing.allocator.free(self.model_path);
        self.tmp.cleanup();
    }
};

test "missing sidecar returns empty override" {
    const override = try loadSidecar(testing.allocator, "/nonexistent/path/to/model.glacier");
    try testing.expect(override.dim == null);
    try testing.expect(override.num_heads == null);
}

test "parses a minimal config json" {
    var sidecar = try TempSidecar.init();
    defer sidecar.deinit();
    {
        const f = try std.fs.cwd().createFile(sidecar.json_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\{"dim":1024,"hidden_dim":2816,"num_layers":24,"num_heads":16,"head_dim":64,"rms_eps":1e-6,"rope_theta":1000000.0}
        );
    }
    const override = try loadSidecar(testing.allocator, sidecar.model_path);
    try testing.expectEqual(@as(?usize, 1024), override.dim);
    try testing.expectEqual(@as(?usize, 2816), override.hidden_dim);
    try testing.expectEqual(@as(?usize, 24), override.num_layers);
    try testing.expectEqual(@as(?usize, 16), override.num_heads);
    try testing.expectEqual(@as(?usize, 64), override.head_dim);
    try testing.expectEqual(@as(?f32, 1e-6), override.rms_eps);
    try testing.expectEqual(@as(?f32, 1000000.0), override.rope_theta);
}

test "parses Hugging Face geometry names" {
    var sidecar = try TempSidecar.init();
    defer sidecar.deinit();
    {
        const f = try std.fs.cwd().createFile(sidecar.json_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\{"hidden_size":896,"intermediate_size":4864,"num_hidden_layers":24,"num_attention_heads":14,"num_key_value_heads":2}
        );
    }
    const override = try loadSidecar(testing.allocator, sidecar.model_path);
    try testing.expectEqual(@as(?usize, 896), override.dim);
    try testing.expectEqual(@as(?usize, 4864), override.hidden_dim);
    try testing.expectEqual(@as(?usize, 24), override.num_layers);
    try testing.expectEqual(@as(?usize, 14), override.num_heads);
    try testing.expectEqual(@as(?usize, 2), override.num_kv_heads);
}

test "partial config keeps unset fields null" {
    var sidecar = try TempSidecar.init();
    defer sidecar.deinit();
    {
        const f = try std.fs.cwd().createFile(sidecar.json_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\{"dim":2048}
        );
    }
    const override = try loadSidecar(testing.allocator, sidecar.model_path);
    try testing.expectEqual(@as(?usize, 2048), override.dim);
    try testing.expect(override.num_heads == null);
    try testing.expect(override.vocab_size == null);
}
