//! `glacier` CLI entry point.
//!
//! For now this is a smoke test: it builds the core modules, runs the
//! pager against the CPU backend with a tiny synthetic page table, and
//! prints stats. Once the converter and Metal backend land, real
//! inference hangs off the same `Pager` API.

const std = @import("std");
const engine = @import("engine");
const cli_telemetry = @import("cli_telemetry");
const core = engine.core;

const Pager = core.Pager;
const PageEntry = core.PageEntry;
const PageTable = core.PageTable;
const Precision = core.Precision;
const CpuBackend = engine.CpuBackend;

pub fn main() !void {
    var process_timer = std.time.Timer.start() catch unreachable;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.Writer.init(stdout, &buf);
    defer bw.interface.flush() catch {};

    if (args.len > 1 and std.mem.eql(u8, args[1], "--version")) {
        try bw.interface.print("glacier 0.1.0\n", .{});
        return;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "convert")) {
        return runConvert(allocator, args, &bw.interface);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "info")) {
        return runInfo(allocator, args, &bw.interface);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "prepare")) {
        return runPrepare(allocator, args, &bw.interface);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "metal-test")) {
        return runMetalTest(allocator, &bw.interface);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "gen-fixture")) {
        return runGenFixture(allocator, args, &bw.interface);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "bench")) {
        return runBench(allocator, args, &bw.interface);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "generate")) {
        return runGenerate(allocator, args, &bw.interface, &process_timer);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "dump-weights")) {
        return runDumpWeights(allocator, args, &bw.interface);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "perplexity")) {
        return runPerplexity(allocator, args, &bw.interface);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "bench-compare")) {
        return runBenchCompare(allocator, args, &bw.interface);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "profile")) {
        return runProfile(allocator, args, &bw.interface);
    }
    // Default: smoke test.

    // Synthetic 3-layer, 2-pages-per-layer model for the smoke test.
    const pages = [_]PageEntry{
        .{ .page_id = 0, .layer_idx = 0, .payload_bytes = 262144, .stored_precision = .fp16 },
        .{ .page_id = 1, .layer_idx = 0, .payload_bytes = 262144, .stored_precision = .fp16 },
        .{ .page_id = 2, .layer_idx = 1, .payload_bytes = 262144, .stored_precision = .int4 },
        .{ .page_id = 3, .layer_idx = 1, .payload_bytes = 262144, .stored_precision = .int4 },
        .{ .page_id = 4, .layer_idx = 2, .payload_bytes = 262144, .stored_precision = .int4 },
        .{ .page_id = 5, .layer_idx = 2, .payload_bytes = 262144, .stored_precision = .int4 },
    };

    const table_ptr = try allocator.create(PageTable);
    defer {
        table_ptr.deinit(allocator);
        allocator.destroy(table_ptr);
    }
    const entries = try allocator.dupe(PageEntry, &pages);
    var id_map = std.AutoHashMap(u64, usize).init(allocator);
    for (entries, 0..) |e, i| try id_map.put(e.page_id, i);
    table_ptr.* = .{ .entries = entries, .id_to_index = id_map };

    var backend = CpuBackend.init(allocator);
    defer backend.deinit();

    // Budget fits 4 pages — should force eviction as we walk all 6.
    var pager = Pager.init(allocator, table_ptr, backend.asBackend(), .{
        .budget_bytes = 4 * 262144,
    });
    defer pager.deinit();

    var prof = try core.precision.precisionProfileFor(allocator, 3);
    defer prof.deinit(allocator);
    const sched = core.scheduler.Scheduler.init(&prof);

    try bw.interface.print("glacier smoke test: 6 pages, 3 layers, 4-page budget\n", .{});

    const layer_pages = [_][]const u64{
        &.{ 0, 1 },
        &.{ 2, 3 },
        &.{ 4, 5 },
    };
    for (layer_pages, 0..) |lp, layer_idx| {
        try sched.ensureLayerResident(&pager, lp, @intCast(layer_idx));
    }

    try bw.interface.print(
        "loads={} hits={} evictions={} bytes_transferred={}\n",
        .{ pager.loads, pager.hits, pager.evictions, pager.bytesTransferred() },
    );
}

/// `glacier convert <in.safetensors> <out.glacier>`
fn runConvert(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
) !void {
    if (args.len < 4) {
        try w.print(
            "usage: glacier convert [--int4] [--group-size N] [--group-size-for KIND=N] <in.safetensors> <out.glacier>\n",
            .{},
        );
        return error.InvalidUsage;
    }

    // Parse flags (positional-style for simplicity).
    var quantize_int4 = false;
    var group_size: u32 = 64;
    var group_overrides: [16]engine.converter.QuantGroupOverride = undefined;
    var override_count: usize = 0;
    var positional: [2][]const u8 = undefined;
    var pos_count: usize = 0;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--int4")) {
            quantize_int4 = true;
        } else if (std.mem.eql(u8, a, "--group-size")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            group_size = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--group-size-for")) {
            i += 1;
            if (i >= args.len or override_count == group_overrides.len) return error.InvalidUsage;
            const spec = args[i];
            const separator = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidUsage;
            const kind = parseTensorKind(spec[0..separator]) orelse return error.InvalidUsage;
            const size = std.fmt.parseInt(u32, spec[separator + 1 ..], 10) catch return error.InvalidUsage;
            group_overrides[override_count] = .{ .kind = kind, .group_size = size };
            override_count += 1;
            quantize_int4 = true;
        } else if (pos_count < 2) {
            positional[pos_count] = a;
            pos_count += 1;
        } else {
            return error.InvalidUsage;
        }
    }
    if (pos_count < 2) {
        try w.print(
            "usage: glacier convert [--int4] [--group-size N] [--group-size-for KIND=N] <in.safetensors> <out.glacier>\n",
            .{},
        );
        return error.InvalidUsage;
    }
    const in_path = positional[0];
    const out_path = positional[1];

    if (quantize_int4) {
        try w.print("quantizing to INT4 (group_size={d}, overrides={d})\n", .{ group_size, override_count });
    }
    try w.print("converting {s} -> {s}\n", .{ in_path, out_path });
    const result = engine.converter.convertSafetensors(
        allocator,
        in_path,
        out_path,
        .{
            .verify_on_write = true,
            .quantize_int4 = quantize_int4,
            .quant_group_size = group_size,
            .quant_group_overrides = group_overrides[0..override_count],
        },
    ) catch |err| {
        try w.print("convert failed: {s}\n", .{@errorName(err)});
        return err;
    };

    try w.print(
        "ok: {d} pages, {d} bytes ({d:.2} MiB)\n",
        .{
            result.num_pages,
            result.output_bytes,
            @as(f64, @floatFromInt(result.output_bytes)) / (1024.0 * 1024.0),
        },
    );
}

fn parseTensorKind(name: []const u8) ?engine.model.TensorKind {
    const Entry = struct { name: []const u8, kind: engine.model.TensorKind };
    const entries = [_]Entry{
        .{ .name = "embedding", .kind = .embedding },
        .{ .name = "attn_q", .kind = .attn_q },
        .{ .name = "attn_k", .kind = .attn_k },
        .{ .name = "attn_v", .kind = .attn_v },
        .{ .name = "attn_o", .kind = .attn_o },
        .{ .name = "mlp_gate", .kind = .mlp_gate },
        .{ .name = "mlp_up", .kind = .mlp_up },
        .{ .name = "mlp_down", .kind = .mlp_down },
        .{ .name = "lm_head", .kind = .lm_head },
    };
    for (entries) |entry| if (std.mem.eql(u8, name, entry.name)) return entry.kind;
    return null;
}

fn sha256OpenFile(file: std.fs.File, file_size: u64) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [1024 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < file_size) {
        const wanted: usize = @intCast(@min(file_size - offset, buffer.len));
        const bytes_read = try file.pread(buffer[0..wanted], offset);
        if (bytes_read == 0) return error.UnexpectedEndOfFile;
        hash.update(buffer[0..bytes_read]);
        offset += bytes_read;
    }

    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashIntLe(
    hash: *std.crypto.hash.sha2.Sha256,
    comptime T: type,
    value: T,
) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hash.update(&bytes);
}

fn preparedProvenanceFingerprint(
    source_sha256: [32]u8,
    config: engine.loader.ModelConfig,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-prepared-provenance-v1\x00");
    hash.update(&source_sha256);
    hashIntLe(&hash, u64, @intCast(config.dim));
    hashIntLe(&hash, u64, @intCast(config.hidden_dim));
    hashIntLe(&hash, u64, @intCast(config.num_layers));
    hashIntLe(&hash, u64, @intCast(config.vocab_size));
    hashIntLe(&hash, u64, @intCast(config.num_heads));
    hashIntLe(&hash, u64, @intCast(config.head_dim));
    hashIntLe(&hash, u64, @intCast(config.num_kv_heads));
    hashIntLe(&hash, u32, @bitCast(config.rms_eps));
    hashIntLe(&hash, u32, @bitCast(config.rope_theta));
    hashIntLe(&hash, u8, @intFromBool(config.tie_word_embeddings));

    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn sourceChanged(before: std.fs.File.Stat, after: std.fs.File.Stat) bool {
    return before.inode != after.inode or
        before.size != after.size or
        before.mtime != after.mtime or
        before.ctime != after.ctime;
}

fn pathsResolveToSameFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    out_path: []const u8,
) !bool {
    const source_real = try std.fs.cwd().realpathAlloc(allocator, source_path);
    defer allocator.free(source_real);
    const out_real = std.fs.cwd().realpathAlloc(allocator, out_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(out_real);
    return std.mem.eql(u8, source_real, out_real);
}

fn hasPreparedExtension(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".glrt");
}

fn hasPreparedMagic(path: []const u8) !bool {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var magic: [engine.runtime_image.MAGIC.len]u8 = undefined;
    const bytes_read = try file.readAll(&magic);
    return bytes_read == magic.len and std.mem.eql(u8, &magic, &engine.runtime_image.MAGIC);
}

fn isPreparedImage(path: []const u8) !bool {
    // Treat an explicit .glrt path as prepared even if it is corrupt: callers
    // must surface the validation error instead of falling back to a source
    // materialization path with different semantics.
    return hasPreparedExtension(path) or try hasPreparedMagic(path);
}

/// `glacier info <file.glacier>`
fn runInfo(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
) !void {
    if (args.len < 3) {
        try w.print("usage: glacier info <file.glacier>\n", .{});
        return error.InvalidUsage;
    }
    var reader = try engine.model.FileReader.open(allocator, args[2]);
    defer reader.close();

    try w.print("glacier file: {s}\n", .{args[2]});
    try w.print("  version:    {d}\n", .{reader.header.version});
    try w.print("  num_pages:  {d}\n", .{reader.pages.len});
    try w.print("  page_size:  2^{d} bytes\n", .{reader.header.page_size_log2});
    try w.print("  metadata:   {s}\n", .{reader.meta_bytes});

    // Sum payload bytes.
    var total: u64 = 0;
    var by_kind = [_]u64{0} ** 10;
    for (reader.pages) |p| {
        total += p.data_len;
        const k = @intFromEnum(p.tensor_kind);
        if (k < by_kind.len) by_kind[k] += p.data_len;
    }
    try w.print("  payload:    {d} bytes ({d:.2} MiB)\n", .{
        total,
        @as(f64, @floatFromInt(total)) / (1024.0 * 1024.0),
    });

    // First few pages for sanity.
    const shown = @min(reader.pages.len, 5);
    try w.print("  first {d} pages:\n", .{shown});
    for (reader.pages[0..shown]) |p| {
        try w.print(
            "    page={d} layer={d} kind={s} prec={s} rows=[{d},{d}) len={d} crc={x}\n",
            .{
                p.page_id,
                p.layer_idx,
                @tagName(p.tensor_kind),
                p.precision.name(),
                p.row_start,
                p.row_end,
                p.data_len,
                p.crc32,
            },
        );
    }
}

/// `glacier prepare <source.glacier> <out.glrt> [--mlp-layout ...]`
///
/// Materialize the production compact-INT4 representation once, then encode
/// its runtime-native streams in an atomic, mmap-ready image. The full source
/// digest is provenance metadata for the derived image; loading the resulting
/// `.glrt` remains self-contained and does not rehash the source hot path.
fn runPrepare(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
) !void {
    if (args.len != 4 and args.len != 6) {
        try w.print("usage: glacier prepare <source.glacier> <out.glrt> [--mlp-layout separate|pair-nibble-required]\n", .{});
        return error.InvalidUsage;
    }

    const source_path = args[2];
    const out_path = args[3];
    var mlp_layout: engine.loader.PreparedMlpWritePolicy = .separate;
    if (args.len == 6) {
        if (!std.mem.eql(u8, args[4], "--mlp-layout"))
            return error.InvalidUsage;
        if (std.mem.eql(u8, args[5], "separate")) {
            mlp_layout = .separate;
        } else if (std.mem.eql(u8, args[5], "pair-nibble-required")) {
            mlp_layout = .pair_nibble_required;
        } else {
            return error.InvalidUsage;
        }
    }
    var total_timer = std.time.Timer.start() catch unreachable;
    if (try pathsResolveToSameFile(allocator, source_path, out_path)) {
        try w.print("prepare: source and output resolve to the same file; refusing to replace the portable model\n", .{});
        return error.SourceOutputAlias;
    }
    if (try isPreparedImage(source_path)) {
        try w.print("prepare: source must be a portable .glacier model, not a prepared image\n", .{});
        return error.InvalidUsage;
    }

    var reader = try engine.model.FileReader.open(allocator, source_path);
    defer reader.close();
    const source_stat_before = try reader.file.stat();

    var hash_timer = std.time.Timer.start() catch unreachable;
    const source_sha256 = try sha256OpenFile(reader.file, source_stat_before.size);
    const hash_ns = hash_timer.read();

    const override = try engine.config.loadSidecar(allocator, source_path);
    var materialize_timer = std.time.Timer.start() catch unreachable;
    var model = try engine.loader.loadWithOptions(allocator, &reader, override, .{
        .compact_int4 = true,
        .int8_mlp_cache = false,
        .fp16_scale_cache = true,
    });
    defer model.deinit();
    const materialize_ns = materialize_timer.read();

    const source_stat_after = try reader.file.stat();
    if (sourceChanged(source_stat_before, source_stat_after)) {
        try w.print("prepare: source changed while hashing/materializing; no image was written\n", .{});
        return error.SourceChangedDuringPrepare;
    }
    const provenance = preparedProvenanceFingerprint(source_sha256, model.config);

    var write_timer = std.time.Timer.start() catch unreachable;
    const write_stats = try engine.loader.writePreparedWithOptionsAndStats(
        allocator,
        &model,
        out_path,
        provenance,
        .{ .mlp_layout = mlp_layout },
    );
    const write_ns = write_timer.read();
    const total_ns = total_timer.read();
    const source_sha256_hex = std.fmt.bytesToHex(source_sha256, .lower);
    const provenance_hex = std.fmt.bytesToHex(provenance, .lower);

    try w.print(
        "prepare: source={s} output={s} mlp_layout={s}\n",
        .{
            source_path,
            out_path,
            if (mlp_layout == .pair_nibble_required)
                "pair-nibble"
            else
                "separate",
        },
    );
    try w.print(
        "  hash_ms={d:.2} materialize_ms={d:.2} materialize_cache_state=post-hash-os-warm write_ms={d:.2} total_ms={d:.2}\n",
        .{
            @as(f64, @floatFromInt(hash_ns)) / 1e6,
            @as(f64, @floatFromInt(materialize_ns)) / 1e6,
            @as(f64, @floatFromInt(write_ns)) / 1e6,
            @as(f64, @floatFromInt(total_ns)) / 1e6,
        },
    );
    try w.print(
        "  source_sha256={s} provenance_sha256={s}\n",
        .{ &source_sha256_hex, &provenance_hex },
    );
    try w.print(
        "  prepare_workspace: generated_records={d} generated_workspace_bytes_total={d} generated_workspace_bytes_peak={d}\n",
        .{
            write_stats.generated_records,
            write_stats.generated_workspace_bytes_total,
            write_stats.generated_workspace_bytes_peak,
        },
    );
}

/// `glacier metal-test` — dispatch the INT4 dequant kernel on the GPU and
/// report max error vs the CPU reference. No-op (with a message) when the
/// build was compiled without the Metal backend.
fn runMetalTest(allocator: std.mem.Allocator, w: *std.Io.Writer) !void {
    const config = @import("config");
    if (!config.metal_enabled) {
        try w.print("metal-test: backend disabled in this build (-Dmetal=false)\n", .{});
        return;
    }

    const group_size: u32 = 64;
    const num_elements: usize = 1024;
    try w.print("metal-test: {d} INT4 weights, group_size={d}\n", .{ num_elements, group_size });

    // Synthetic weights.
    var rng = std.Random.DefaultPrng.init(42);
    const src = try allocator.alloc(f32, num_elements);
    defer allocator.free(src);
    for (src) |*v| v.* = (rng.random().float(f32) * 2 - 1) * 0.4;

    const payload = try engine.qio.encodePage(f32, allocator, src, .int4, group_size);
    defer allocator.free(payload);

    // CPU reference.
    const cpu_out = try engine.qio.decodePage(f32, allocator, payload);
    defer allocator.free(cpu_out);

    // GPU path.
    var backend = engine.MetalBackend.init("zig-out/metal/shaders.metallib") catch |err| {
        try w.print("metal-test: no Metal device ({s})\n", .{@errorName(err)});
        return;
    };
    defer backend.deinit();

    const gpu_bytes = try allocator.alloc(u8, num_elements * 2);
    defer allocator.free(gpu_bytes);
    try backend.dequantInt4(payload, gpu_bytes, @intCast(num_elements));

    var max_diff: f32 = 0;
    var i: usize = 0;
    while (i < num_elements) : (i += 1) {
        const bits = std.mem.readInt(u16, gpu_bytes[i * 2 ..][0..2], .little);
        const gpu_f32 = engine.core.f16bits.f16BitsToF32(bits);
        const diff: f32 = if (gpu_f32 > cpu_out[i]) gpu_f32 - cpu_out[i] else cpu_out[i] - gpu_f32;
        if (diff > max_diff) max_diff = diff;
    }

    try w.print(
        "metal-test: max |metal - cpu| = {d:.6}  ({s})\n",
        .{ max_diff, if (max_diff < 0.005) "PASS" else "FAIL" },
    );
}

/// `glacier gen-fixture <out.safetensors> [--dim N] [--layers N] [--vocab N]`
fn runGenFixture(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
) !void {
    if (args.len < 3) {
        try w.print(
            "usage: glacier gen-fixture <out.safetensors> [--dim N] [--layers N] [--vocab N] [--hidden N]\n",
            .{},
        );
        return error.InvalidUsage;
    }

    var geom: engine.fixture_gen.Geometry = .{};
    var out_path: []const u8 = "";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--dim")) {
            i += 1;
            geom.dim = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--hidden")) {
            i += 1;
            geom.hidden_dim = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--layers")) {
            i += 1;
            geom.num_layers = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--vocab")) {
            i += 1;
            geom.vocab_size = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidUsage;
        } else {
            out_path = a;
        }
    }
    if (out_path.len == 0) return error.InvalidUsage;

    try engine.fixture_gen.writeSafetensors(out_path, geom);
    try w.print(
        "gen-fixture: wrote {s} (dim={d} hidden={d} layers={d} vocab={d})\n",
        .{ out_path, geom.dim, geom.hidden_dim, geom.num_layers, geom.vocab_size },
    );
    _ = allocator;
}

/// `glacier bench <model.glacier> [num_tokens]`
/// Runs N forward passes and reports tok/s + achieved memory bandwidth.
fn runBench(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
) !void {
    if (args.len < 3) {
        try w.print("usage: glacier bench <model.glacier> [num_tokens]\n", .{});
        return error.InvalidUsage;
    }
    const path = args[2];
    const num_tokens: usize = if (args.len >= 4)
        std.fmt.parseInt(usize, args[3], 10) catch 16
    else
        16;

    var reader = try engine.model.FileReader.open(allocator, path);
    defer reader.close();
    const override = try engine.config.loadSidecar(allocator, path);
    var model = try engine.loader.load(allocator, &reader, override);
    defer model.deinit();

    // Sum decoded weight bytes (what would cross the bus in a paged backend).
    var decoded_weight_bytes: u64 = 0;
    decoded_weight_bytes += model.token_embedding.len * @sizeOf(f32);
    decoded_weight_bytes += model.lm_head.len * @sizeOf(f32);
    decoded_weight_bytes += model.final_norm.len * @sizeOf(f32);
    for (model.layers) |lw| {
        decoded_weight_bytes += lw.input_norm.len * @sizeOf(f32);
        decoded_weight_bytes += lw.post_attn_norm.len * @sizeOf(f32);
        decoded_weight_bytes += lw.wq.len * @sizeOf(f32);
        decoded_weight_bytes += lw.wk.len * @sizeOf(f32);
        decoded_weight_bytes += lw.wv.len * @sizeOf(f32);
        decoded_weight_bytes += lw.wo.len * @sizeOf(f32);
        decoded_weight_bytes += lw.w_gate.len * @sizeOf(f32);
        decoded_weight_bytes += lw.w_up.len * @sizeOf(f32);
        decoded_weight_bytes += lw.w_down.len * @sizeOf(f32);
    }

    var on_disk_bytes: u64 = 0;
    for (reader.pages) |p| on_disk_bytes += p.data_len;

    try w.print("bench: {s}\n", .{path});
    try w.print(
        "  config:  layers={d} dim={d} hidden={d} vocab={d}\n",
        .{ model.config.num_layers, model.config.dim, model.config.hidden_dim, model.config.vocab_size },
    );
    try w.print(
        "  weights: {d:.2} MiB decoded, {d:.2} MiB on-disk ({d:.2}x compression)\n",
        .{
            @as(f64, @floatFromInt(decoded_weight_bytes)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(on_disk_bytes)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(decoded_weight_bytes)) / @as(f64, @floatFromInt(@max(on_disk_bytes, 1))),
        },
    );

    // 1-token prompt; measure steady-state forward cost.
    // If --ids-file is given, use that prompt instead and just run once.
    var ids_file_path: ?[]const u8 = null;
    var ai: usize = 3;
    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--ids-file")) {
            ai += 1;
            if (ai < args.len) ids_file_path = args[ai];
        }
    }

    if (ids_file_path) |ifpath| {
        const f = try std.fs.cwd().openFile(ifpath, .{});
        defer f.close();
        const stat = try f.stat();
        const buf = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(buf);
        _ = try f.readAll(buf);
        var prompt_list: std.ArrayList(u32) = .{};
        defer prompt_list.deinit(allocator);
        var it = std.mem.tokenizeAny(u8, buf, " \n\r\t");
        while (it.next()) |s| {
            try prompt_list.append(allocator, std.fmt.parseInt(u32, s, 10) catch continue);
        }
        var logits2 = try engine.core.tensor.zerosF32(
            allocator,
            &.{ prompt_list.items.len, model.config.vocab_size },
        );
        defer logits2.deinit();
        try engine.forward.forwardModel(allocator, model, prompt_list.items, logits2);
        // Print argmax of last row.
        const last = logits2.asF32()[(prompt_list.items.len - 1) * model.config.vocab_size ..];
        const next = engine.forward.argmax(last);
        try w.print("  forward: argmax(last) = {d}\n", .{next});
        return;
    }

    const prompt = [_]u32{0};
    var logits = try engine.core.tensor.zerosF32(
        allocator,
        &.{ 1, model.config.vocab_size },
    );
    defer logits.deinit();

    // Warmup.
    try engine.forward.forwardModel(allocator, model, &prompt, logits);

    const t0 = std.time.Timer.start() catch unreachable;
    var timer = t0;
    var t: usize = 0;
    while (t < num_tokens) : (t += 1) {
        try engine.forward.forwardModel(allocator, model, &prompt, logits);
    }
    const elapsed_ns = timer.read();
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const tok_s: f64 = @as(f64, @floatFromInt(num_tokens)) / elapsed_s;

    // For seq_len=1 each forward reads every weight once (no KV cache reuse).
    const bytes_per_token: u64 = decoded_weight_bytes;
    const achieved_bw_gbps: f64 = @as(f64, @floatFromInt(bytes_per_token)) * tok_s / (1024.0 * 1024.0 * 1024.0);

    try w.print(
        "  result:   {d} tok in {d:.2} ms = {d:.1} tok/s\n",
        .{ num_tokens, elapsed_s * 1000.0, tok_s },
    );
    try w.print(
        "  bw:       {d:.2} GiB/s achieved, {d:.1}% of 100 GiB/s ceiling\n",
        .{ achieved_bw_gbps, 100.0 * achieved_bw_gbps / 100.0 },
    );
}

const CliEligibilityDomain = enum {
    static64_v1,
    rotating64_v1,
};

fn cliEligibilityDigest(label: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(label);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

const CliEligibilityProvider = struct {
    domain: CliEligibilityDomain,
    vocab_size: usize,
    head_binding: [32]u8,
    tokenizer_binding: [32]u8,
    policy_binding: [32]u8,

    const generation_epoch: u64 = 0x2026_0720_0000_0001;
    const domain_rows: usize = 64;
    const rotating_stride: usize = 7_919;

    fn gcd(left: usize, right: usize) usize {
        var a = left;
        var b = right;
        while (b != 0) {
            const remainder = a % b;
            a = b;
            b = remainder;
        }
        return a;
    }

    fn init(
        domain: CliEligibilityDomain,
        model: engine.loader.LoadedModel,
    ) !CliEligibilityProvider {
        if (model.config.vocab_size < domain_rows) return error.InvalidUsage;
        if (domain == .rotating64_v1 and
            gcd(rotating_stride, model.config.vocab_size) != 1)
            return error.InvalidUsage;
        const domain_label = switch (domain) {
            .static64_v1 => "glacier-cli-domain-static64-v1\x00",
            .rotating64_v1 => "glacier-cli-domain-rotating64-v1\x00",
        };
        var policy_hash = std.crypto.hash.sha2.Sha256.init(.{});
        policy_hash.update(domain_label);
        var vocab_bytes: [8]u8 = undefined;
        std.mem.writeInt(
            u64,
            &vocab_bytes,
            @intCast(model.config.vocab_size),
            .little,
        );
        policy_hash.update(&vocab_bytes);
        var policy_binding: [32]u8 = undefined;
        policy_hash.final(&policy_binding);
        return .{
            .domain = domain,
            .vocab_size = model.config.vocab_size,
            .head_binding = engine.generate.eligibilityHeadBinding(model),
            .tokenizer_binding = cliEligibilityDigest(
                "glacier-cli-raw-u32-token-ids-v1\x00",
            ),
            .policy_binding = policy_binding,
        };
    }

    fn fill(
        opaque_context: *anyopaque,
        step: *const engine.generate.EligibilityStepV1,
        staging_words: []u64,
        certificate: *engine.generate.EligibilityCertificateV1,
    ) engine.generate.EligibilityProviderError!void {
        const self: *CliEligibilityProvider = @ptrCast(
            @alignCast(opaque_context),
        );
        if (step.vocab_size != self.vocab_size or
            !std.mem.eql(u8, &step.head_binding, &self.head_binding) or
            !std.mem.eql(
                u8,
                &step.tokenizer_binding,
                &self.tokenizer_binding,
            ) or
            !std.mem.eql(u8, &step.policy_binding, &self.policy_binding))
            return error.InvalidEvidence;
        const step_index = std.math.cast(usize, step.step_index) orelse
            return error.InvalidEvidence;
        switch (self.domain) {
            .static64_v1 => {
                for (0..domain_rows) |token_id| {
                    staging_words[token_id / 64] |=
                        @as(u64, 1) << @as(u6, @intCast(token_id % 64));
                }
            },
            .rotating64_v1 => {
                const step_offset = std.math.mul(
                    usize,
                    step_index,
                    104_729,
                ) catch return error.InvalidEvidence;
                const base = std.math.add(
                    usize,
                    17,
                    step_offset,
                ) catch return error.InvalidEvidence;
                for (0..domain_rows) |candidate_index| {
                    const candidate_offset = std.math.mul(
                        usize,
                        candidate_index,
                        rotating_stride,
                    ) catch return error.InvalidEvidence;
                    const token_id = std.math.add(
                        usize,
                        base,
                        candidate_offset,
                    ) catch return error.InvalidEvidence;
                    const bounded_token_id = token_id % self.vocab_size;
                    staging_words[bounded_token_id / 64] |= @as(u64, 1) <<
                        @as(u6, @intCast(bounded_token_id % 64));
                }
            },
        }
        var eligible_rows: usize = 0;
        for (staging_words) |word| eligible_rows += @popCount(word);
        if (eligible_rows != domain_rows) return error.InvalidEvidence;
        certificate.* = .{
            .abi = engine.generate.eligibility_provider_abi,
            .generation_epoch = step.generation_epoch,
            .request_nonce = step.request_nonce,
            .step_index = step.step_index,
            .logits_position = step.logits_position,
            .not_after_step = step.step_index,
            .head_binding = step.head_binding,
            .tokenizer_binding = step.tokenizer_binding,
            .policy_binding = step.policy_binding,
            .prefix_sha256 = step.prefix_sha256,
            .mask_sha256 = engine.generate.eligibilityMaskSha256(
                staging_words,
            ),
            .eligible_rows = eligible_rows,
            .tie_rule = .lowest_token_id,
            .operation = .greedy_argmax,
        };
    }

    fn provider(
        self: *CliEligibilityProvider,
    ) engine.generate.EligibleVocabularyProvider {
        return .{
            .context = self,
            .generation_epoch = generation_epoch,
            .head_binding = self.head_binding,
            .tokenizer_binding = self.tokenizer_binding,
            .policy_binding = self.policy_binding,
            .fill = fill,
        };
    }
};

// Keep high-cardinality evidence outside the hot ReleaseFast CLI module.
const TelemetryCounter = cli_telemetry.Counter;
const writeTelemetryString = cli_telemetry.writeString;
const writeTelemetryCount = cli_telemetry.writeCount;
const writeTelemetryU64 = cli_telemetry.writeU64;
const writeTelemetryMillis = cli_telemetry.writeMillis;
const writeTelemetryHex = cli_telemetry.writeHex;
const writeTelemetryCounts = cli_telemetry.writeCounts;

const cli_request_resource_bank_epoch: u64 = 1;

fn writeRequestResourceTelemetry(
    w: *std.Io.Writer,
    telemetry: engine.generate.RequestResourceTelemetry,
    bank: *engine.resource_bank.Bank,
) !void {
    const snapshot = try bank.snapshot();
    const live_host_bytes = try snapshot.used.hostBytes();

    try w.writeAll("resource_bank:");
    try writeTelemetryString(w, "scope", "logical-request-v1");
    try writeTelemetryU64(w, "host_limit_bytes", snapshot.limits.host_bytes);
    try writeTelemetryCount(w, "slot_limit", 1);
    try writeTelemetryU64(w, "host_claim_bytes", telemetry.host_claim_bytes);
    try writeTelemetryU64(w, "capsule_bytes", telemetry.capsule_bytes);
    try writeTelemetryU64(w, "kv_bytes", telemetry.kv_bytes);
    try writeTelemetryU64(w, "activation_bytes", telemetry.activation_bytes);
    try writeTelemetryU64(w, "partial_bytes", telemetry.partial_bytes);
    try writeTelemetryU64(w, "logits_bytes", telemetry.logits_bytes);
    try writeTelemetryU64(
        w,
        "output_journal_bytes",
        telemetry.output_journal_bytes,
    );
    try writeTelemetryU64(w, "staging_bytes", telemetry.staging_bytes);
    try writeTelemetryU64(w, "device_bytes", telemetry.device_bytes);
    try writeTelemetryU64(w, "io_bytes", telemetry.io_bytes);
    try writeTelemetryU64(w, "queue_slots", telemetry.queue_slots);
    try writeTelemetryU64(w, "peak_host_bytes", telemetry.peak_host_bytes);
    try writeTelemetryU64(w, "live_host_bytes", live_host_bytes);
    try writeTelemetryU64(w, "reservations", telemetry.reservations);
    try writeTelemetryU64(w, "commits", telemetry.commits);
    try writeTelemetryU64(w, "cancellations", telemetry.cancellations);
    try writeTelemetryU64(w, "releases", telemetry.releases);
    try writeTelemetryU64(w, "capacity_rejects", telemetry.capacity_rejects);
    try writeTelemetryU64(w, "slot_rejects", telemetry.slot_rejects);
    try writeTelemetryCount(w, "derive_rejects", telemetry.derive_rejects);
    try writeTelemetryCount(w, "release_failures", telemetry.release_failures);
    try writeTelemetryCount(
        w,
        "active_reservations",
        snapshot.active_reservations,
    );
    try writeTelemetryCount(
        w,
        "committed_receipts",
        snapshot.committed_receipts,
    );
    try writeTelemetryHex(w, "owner_key", telemetry.owner_key);
    try writeTelemetryHex(w, "receipt_integrity", telemetry.receipt_integrity);
    try writeTelemetryU64(w, "epoch", snapshot.bank_epoch);
    try writeTelemetryHex(w, "abi", engine.generate.request_resource_bank_abi);
    try w.writeByte('\n');
}

/// `glacier generate <model.glacier> <tok1> <tok2> ... [--n N] [--threads N]`
/// Greedy-decodes N tokens from the prompt using the KV cache. Tokens are
/// passed as raw u32 ids (no tokenizer yet).
fn runGenerate(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
    process_timer: *std.time.Timer,
) !void {
    if (args.len < 4) {
        try w.print("usage: glacier generate <model.glacier|model.glrt> <tok1> [tok2 ...] [--n N] [--threads N] [--request-memory-limit BYTES] [--fp32-activations] [--fp32-scales] [--int8-cache] [--legacy-pool] [--serial-prefill] [--require-batch-prefill] [--serial-attention|--parallel-attention-min-context N] [--decode-plan checked|sealed-required] [--mlp-layout separate|pair-nibble-required] [--decode-frame auto|materialized-required|compact-pair-required] [--pair-scratch auto|fixed-256-required|model-shaped-required] [--pair-prefill-frame auto|materialized-required|compact-32-required|compact-64-required] [--greedy-output materialized|logitless-required|domain-posthead-required|domain-prehead-required] [--eligible-domain static64-v1|rotating64-v1] [--require-prepared-image]\n", .{});
        return error.InvalidUsage;
    }

    const path = args[2];
    var num_new: usize = 8;
    var temperature: f32 = 0;
    var top_k: usize = 0;
    var top_p: f32 = 1.0;
    var seed: u64 = 0;
    var num_threads: usize = 0;
    var request_memory_limit: ?u64 = null;
    var int4_activation: engine.generate.Int4Activation = .q8;
    var use_persistent_executor = true;
    var use_batch_prefill = true;
    var require_batch_prefill = false;
    var parallel_attention_min_context: ?usize = engine.generate.default_parallel_attention_min_context;
    var attention_schedule_explicit = false;
    var decode_plan_mode: engine.generate.DecodePlanMode = .checked;
    var mlp_representation: engine.generate.MlpRepresentationMode = .separate;
    var decode_frame_mode: engine.generate.DecodeFrameMode = .automatic;
    var pair_scratch_mode: engine.generate.PairScratchMode = .automatic;
    var pair_prefill_frame_mode: engine.generate.PairPrefillFrameMode = .automatic;
    var greedy_output_mode: engine.generate.GreedyOutputMode = .materialized;
    var eligible_domain: ?CliEligibilityDomain = null;
    var require_prepared_image = false;
    var stream = false;
    var text_prompt: ?[]const u8 = null;
    var ids_file: ?[]const u8 = null;
    var out_ids_file: ?[]const u8 = null;
    var eos_token: u32 = std.math.maxInt(u32);
    var compact_int4 = true;
    var int8_mlp_cache = false;
    var fp16_scale_cache = true;
    var prompt: std.ArrayList(u32) = .{};
    defer prompt.deinit(allocator);

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--n")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            num_new = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--temp")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            temperature = std.fmt.parseFloat(f32, args[i]) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--top-k")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            top_k = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--top-p")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            top_p = std.fmt.parseFloat(f32, args[i]) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            seed = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--threads")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            num_threads = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--request-memory-limit")) {
            if (request_memory_limit != null) return error.InvalidUsage;
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            const limit = std.fmt.parseInt(u64, args[i], 10) catch
                return error.InvalidUsage;
            if (limit == 0) return error.InvalidUsage;
            request_memory_limit = limit;
        } else if (std.mem.eql(u8, a, "--fp32-activations")) {
            int4_activation = .f32;
        } else if (std.mem.eql(u8, a, "--fp32-scales")) {
            fp16_scale_cache = false;
        } else if (std.mem.eql(u8, a, "--int8-cache")) {
            int8_mlp_cache = true;
        } else if (std.mem.eql(u8, a, "--legacy-pool")) {
            use_persistent_executor = false;
        } else if (std.mem.eql(u8, a, "--serial-prefill")) {
            use_batch_prefill = false;
        } else if (std.mem.eql(u8, a, "--require-batch-prefill")) {
            require_batch_prefill = true;
        } else if (std.mem.eql(u8, a, "--serial-attention")) {
            if (attention_schedule_explicit) return error.InvalidUsage;
            attention_schedule_explicit = true;
            parallel_attention_min_context = null;
        } else if (std.mem.eql(u8, a, "--parallel-attention-min-context")) {
            if (attention_schedule_explicit) return error.InvalidUsage;
            attention_schedule_explicit = true;
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            const threshold = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidUsage;
            if (threshold == 0) return error.InvalidUsage;
            parallel_attention_min_context = threshold;
        } else if (std.mem.eql(u8, a, "--decode-plan")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            if (std.mem.eql(u8, args[i], "checked")) {
                decode_plan_mode = .checked;
            } else if (std.mem.eql(u8, args[i], "sealed-required")) {
                decode_plan_mode = .sealed_required;
            } else {
                return error.InvalidUsage;
            }
        } else if (std.mem.eql(u8, a, "--mlp-layout")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            if (std.mem.eql(u8, args[i], "separate")) {
                mlp_representation = .separate;
            } else if (std.mem.eql(u8, args[i], "pair-nibble-required")) {
                mlp_representation = .pair_nibble_required;
            } else {
                return error.InvalidUsage;
            }
        } else if (std.mem.eql(u8, a, "--decode-frame")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            if (std.mem.eql(u8, args[i], "auto")) {
                decode_frame_mode = .automatic;
            } else if (std.mem.eql(u8, args[i], "materialized-required")) {
                decode_frame_mode = .materialized_required;
            } else if (std.mem.eql(u8, args[i], "compact-pair-required")) {
                decode_frame_mode = .compact_pair_required;
            } else {
                return error.InvalidUsage;
            }
        } else if (std.mem.eql(u8, a, "--pair-scratch")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            if (std.mem.eql(u8, args[i], "auto")) {
                pair_scratch_mode = .automatic;
            } else if (std.mem.eql(u8, args[i], "fixed-256-required")) {
                pair_scratch_mode = .fixed_256_required;
            } else if (std.mem.eql(u8, args[i], "model-shaped-required")) {
                pair_scratch_mode = .model_shaped_required;
            } else {
                return error.InvalidUsage;
            }
        } else if (std.mem.eql(u8, a, "--pair-prefill-frame")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            if (std.mem.eql(u8, args[i], "auto")) {
                pair_prefill_frame_mode = .automatic;
            } else if (std.mem.eql(u8, args[i], "materialized-required")) {
                pair_prefill_frame_mode = .materialized_required;
            } else if (std.mem.eql(u8, args[i], "compact-32-required")) {
                pair_prefill_frame_mode = .compact_32_required;
            } else if (std.mem.eql(u8, args[i], "compact-64-required")) {
                pair_prefill_frame_mode = .compact_64_required;
            } else {
                return error.InvalidUsage;
            }
        } else if (std.mem.eql(u8, a, "--greedy-output")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            if (std.mem.eql(u8, args[i], "materialized")) {
                greedy_output_mode = .materialized;
            } else if (std.mem.eql(u8, args[i], "logitless-required")) {
                greedy_output_mode = .logitless_required;
            } else if (std.mem.eql(u8, args[i], "domain-posthead-required")) {
                greedy_output_mode = .domain_posthead_required;
            } else if (std.mem.eql(u8, args[i], "domain-prehead-required")) {
                greedy_output_mode = .domain_prehead_required;
            } else {
                return error.InvalidUsage;
            }
        } else if (std.mem.eql(u8, a, "--eligible-domain")) {
            i += 1;
            if (i >= args.len or eligible_domain != null)
                return error.InvalidUsage;
            if (std.mem.eql(u8, args[i], "static64-v1")) {
                eligible_domain = .static64_v1;
            } else if (std.mem.eql(u8, args[i], "rotating64-v1")) {
                eligible_domain = .rotating64_v1;
            } else {
                return error.InvalidUsage;
            }
        } else if (std.mem.eql(u8, a, "--require-prepared-image")) {
            require_prepared_image = true;
        } else if (std.mem.eql(u8, a, "--stream")) {
            stream = true;
        } else if (std.mem.eql(u8, a, "--text")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            text_prompt = args[i];
        } else if (std.mem.eql(u8, a, "--ids-file")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            ids_file = args[i];
        } else if (std.mem.eql(u8, a, "--out-ids-file")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            out_ids_file = args[i];
        } else if (std.mem.eql(u8, a, "--eos")) {
            i += 1;
            if (i >= args.len) return error.InvalidUsage;
            eos_token = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidUsage;
        } else if (std.mem.eql(u8, a, "--eager-weights")) {
            compact_int4 = false;
        } else {
            const t = std.fmt.parseInt(u32, a, 10) catch return error.InvalidUsage;
            try prompt.append(allocator, t);
        }
    }

    const use_fp16_scale_cache = compact_int4 and fp16_scale_cache and
        use_persistent_executor and int4_activation == .q8 and !int8_mlp_cache;
    const require_pair_nibble = mlp_representation == .pair_nibble_required;
    if (decode_frame_mode == .compact_pair_required and !require_pair_nibble) {
        try w.print(
            "generate: compact-pair-required needs --mlp-layout pair-nibble-required\n",
            .{},
        );
        return error.PairNibbleOptionsMismatch;
    }
    if (pair_scratch_mode != .automatic and !require_pair_nibble) {
        try w.print(
            "generate: required Pair scratch needs --mlp-layout pair-nibble-required\n",
            .{},
        );
        return error.PairNibbleOptionsMismatch;
    }
    if (pair_prefill_frame_mode != .automatic and !require_pair_nibble) {
        try w.print(
            "generate: required Pair prefill frame needs --mlp-layout pair-nibble-required\n",
            .{},
        );
        return error.PairNibbleOptionsMismatch;
    }
    if (require_pair_nibble and
        (!use_fp16_scale_cache or decode_plan_mode != .checked))
    {
        try w.print(
            "generate: pair-nibble-required needs compact INT4, Q8 activations, FP16 scales, the persistent executor, and --decode-plan checked\n",
            .{},
        );
        return error.PairNibbleOptionsMismatch;
    }

    // Prepared images are a distinct, fail-closed input class. Extension
    // detection makes corrupt/missing explicit .glrt paths surface their own
    // validation error; magic detection also supports renamed images. The
    // timer covers detection, open, validation, and loader construction.
    var load_timer = std.time.Timer.start() catch unreachable;
    const prepared_input = try isPreparedImage(path);
    if (!prepared_input and (require_prepared_image or require_pair_nibble)) {
        try w.print(
            "generate: prepared GLRT input required by the selected policy; rejected {s}\n",
            .{path},
        );
        return error.PreparedImageRequired;
    }
    if (prepared_input and !use_fp16_scale_cache) {
        try w.print(
            "generate: prepared images require compact INT4, Q8 activations, FP16 scales, and the persistent executor\n",
            .{},
        );
        return error.PreparedImageOptionsMismatch;
    }

    var source_reader: ?engine.model.FileReader = null;
    defer if (source_reader) |*reader| reader.close();
    var model = if (prepared_input)
        try engine.loader.loadPreparedWithOptions(allocator, path, .{
            .mlp_layout = if (require_pair_nibble)
                .pair_nibble_required
            else
                .separate_required,
        })
    else blk: {
        source_reader = try engine.model.FileReader.open(allocator, path);
        const override = try engine.config.loadSidecar(allocator, path);
        break :blk try engine.loader.loadWithOptions(allocator, &source_reader.?, override, .{
            .compact_int4 = compact_int4,
            .int8_mlp_cache = int8_mlp_cache,
            .fp16_scale_cache = use_fp16_scale_cache,
        });
    };
    defer model.deinit();
    const load_ns = load_timer.read();
    const load_artifact = if (prepared_input) "glrt" else "glacier";
    const load_mode = if (prepared_input) "prepared" else "materialized";
    try w.print(
        "load: mode={s} artifact={s} ms={d:.2}\n",
        .{
            load_mode,
            load_artifact,
            @as(f64, @floatFromInt(load_ns)) / 1e6,
        },
    );
    if (parallel_attention_min_context) |threshold| {
        try w.print(
            "schedule: attention=parallel min_context={d} layers={d}\n",
            .{ threshold, model.config.num_layers },
        );
    } else {
        try w.print("schedule: attention=serial layers={d}\n", .{model.config.num_layers});
    }

    // If a text prompt was supplied, encode it via the byte tokenizer.
    // Otherwise the raw token ids parsed above are used directly.
    const tz = engine.tokenizer.ByteTokenizer.init(@intCast(model.config.vocab_size));
    if (text_prompt) |txt| {
        const encoded = try tz.encode(allocator, txt, true, false);
        defer allocator.free(encoded);
        for (encoded) |t| try prompt.append(allocator, t);
    }
    // If an ids file was supplied, read space/newline-separated ids from it.
    if (ids_file) |ifpath| {
        const f = try std.fs.cwd().openFile(ifpath, .{});
        defer f.close();
        const stat = try f.stat();
        const buf = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(buf);
        _ = try f.readAll(buf);
        var it = std.mem.tokenizeAny(u8, buf, " \n\r\t");
        while (it.next()) |tok_str| {
            const t = std.fmt.parseInt(u32, tok_str, 10) catch return error.InvalidUsage;
            try prompt.append(allocator, t);
        }
    }
    if (prompt.items.len == 0) {
        try w.print("generate: empty prompt; supply tokens or --text or --ids-file\n", .{});
        return error.InvalidUsage;
    }
    if (!use_batch_prefill and require_batch_prefill) {
        try w.print("generate: --serial-prefill conflicts with --require-batch-prefill\n", .{});
        return error.InvalidUsage;
    }
    const uses_eligible_domain = greedy_output_mode ==
        .domain_posthead_required or
        greedy_output_mode == .domain_prehead_required;
    if (uses_eligible_domain != (eligible_domain != null)) {
        try w.print(
            "generate: domain output modes require exactly one --eligible-domain, and other modes forbid it\n",
            .{},
        );
        return error.InvalidUsage;
    }
    var eligibility_provider_context: CliEligibilityProvider = undefined;
    var eligibility_provider: ?engine.generate.EligibleVocabularyProvider = null;
    if (eligible_domain) |domain| {
        eligibility_provider_context = try CliEligibilityProvider.init(
            domain,
            model,
        );
        eligibility_provider = eligibility_provider_context.provider();
    }

    try w.print(
        "generate: prompt={d} tokens n={d} temp={d:.2} top-k={d} top-p={d:.2} seed={d} weights={s}{s} activation={s} mlp_layout={s}\n",
        .{
            prompt.items.len,
            num_new,
            temperature,
            top_k,
            top_p,
            seed,
            if (model.token_embedding_int4 != null) "packed-int4" else "eager",
            if (int8_mlp_cache)
                "+int8-mlp-cache"
            else if (use_fp16_scale_cache)
                "+fp16-scales"
            else
                "",
            @tagName(int4_activation),
            if (require_pair_nibble) "pair-nibble" else "separate",
        },
    );

    // Streaming callback writes token ids to stderr via std.debug.print.
    // This is a simplification — proper stdout streaming requires threading
    // the writer through the callback, which is a future refactor.
    const streamingCb = struct {
        fn cb(tok: u32) void {
            std.debug.print("{d} ", .{tok});
        }
    }.cb;

    const t0 = std.time.Timer.start() catch unreachable;
    var timer = t0;
    var prefill_path: engine.generate.PrefillPath = .serial;
    var request_ready_ns: u64 = 0;
    var phase_telemetry: engine.generate.GenerationPhaseTelemetry = .{};
    var decode_plan_telemetry: engine.generate.DecodePlanTelemetry = .{};
    var pair_nibble_telemetry: engine.generate.PairNibbleExecutionTelemetry = .{};
    var pair_scratch_telemetry: engine.generate.PairScratchExecutionTelemetry = .{};
    var pair_prefill_frame_telemetry: engine.generate.PairPrefillFrameTelemetry = .{};
    var greedy_output_telemetry: engine.generate.GreedyOutputTelemetry = .{};
    var eligibility_telemetry: engine.generate.EligibilityTelemetry = .{};
    var request_resource_slots = [_]engine.resource_bank.Slot{.{}};
    var request_resource_bank = try engine.resource_bank.Bank.init(
        &request_resource_slots,
        .{
            .host_bytes = request_memory_limit orelse std.math.maxInt(u64),
        },
        cli_request_resource_bank_epoch,
    );
    var request_resource_telemetry: engine.generate.RequestResourceTelemetry = .{};
    const gen = engine.generate.generate(allocator, model, prompt.items, .{
        .max_new_tokens = num_new,
        .sampler = .{
            .temperature = temperature,
            .top_k = top_k,
            .top_p = top_p,
        },
        .seed = seed,
        .num_threads = num_threads,
        .int4_activation = int4_activation,
        .use_persistent_executor = use_persistent_executor,
        .mlp_representation = mlp_representation,
        .decode_frame_mode = decode_frame_mode,
        .pair_scratch_mode = pair_scratch_mode,
        .pair_scratch_telemetry = &pair_scratch_telemetry,
        .pair_prefill_frame_mode = pair_prefill_frame_mode,
        .pair_prefill_frame_telemetry = &pair_prefill_frame_telemetry,
        .request_resource_bank = &request_resource_bank,
        .request_resource_telemetry = &request_resource_telemetry,
        .pair_nibble_telemetry = &pair_nibble_telemetry,
        .parallel_attention_min_context = parallel_attention_min_context,
        .decode_plan_mode = decode_plan_mode,
        .decode_plan_telemetry = &decode_plan_telemetry,
        .greedy_output_mode = greedy_output_mode,
        .greedy_output_telemetry = &greedy_output_telemetry,
        .eligible_vocabulary_provider = eligibility_provider,
        .eligibility_telemetry = &eligibility_telemetry,
        .use_batch_prefill = use_batch_prefill,
        .require_batch_prefill = require_batch_prefill,
        .prefill_path_out = &prefill_path,
        .request_ready_telemetry = .{
            .process_timer = process_timer,
            .elapsed_ns_out = &request_ready_ns,
        },
        .phase_telemetry = &phase_telemetry,
        .eos_token = eos_token,
        .on_token = if (stream) &streamingCb else null,
    }) catch |err| {
        try writeRequestResourceTelemetry(
            w,
            request_resource_telemetry,
            &request_resource_bank,
        );
        return err;
    };
    defer allocator.free(gen);
    const elapsed_ns = timer.read();
    if (stream) std.debug.print("\n", .{});
    try w.print(
        "ready: phase=request_ready ms={d:.2}\n",
        .{@as(f64, @floatFromInt(request_ready_ns)) / 1e6},
    );
    try w.print(
        "phases: prefill_ms={d:.3} decode_ms={d:.3} sampling_ms={d:.3} decode_runs={d} attention_graphs={d} attention_dispatches={d} handoff_graphs={d} handoff_dispatches={d} fused_gqa_graphs={d} fused_gqa_dispatches={d} paired_mlp_graphs={d} paired_mlp_dispatches={d}\n",
        .{
            @as(f64, @floatFromInt(phase_telemetry.prefill_ns)) / 1e6,
            @as(f64, @floatFromInt(phase_telemetry.decode_graph_ns)) / 1e6,
            @as(f64, @floatFromInt(phase_telemetry.sampling_ns)) / 1e6,
            phase_telemetry.decode_graph_runs,
            phase_telemetry.parallel_attention_graphs,
            phase_telemetry.parallel_attention_dispatches,
            phase_telemetry.handoff_graphs,
            phase_telemetry.handoff_dispatches,
            phase_telemetry.fused_gqa_graphs,
            phase_telemetry.fused_gqa_dispatches,
            phase_telemetry.paired_mlp_graphs,
            phase_telemetry.paired_mlp_dispatches,
        },
    );
    try w.print(
        "prefill_phase: graph_ms={d:.3} first_head_ms={d:.3} abi={x}\n",
        .{
            @as(f64, @floatFromInt(phase_telemetry.prefill_graph_ns)) / 1e6,
            @as(f64, @floatFromInt(phase_telemetry.first_head_ns)) / 1e6,
            engine.generate.prefill_phase_abi,
        },
    );
    try writeRequestResourceTelemetry(
        w,
        request_resource_telemetry,
        &request_resource_bank,
    );
    try w.writeAll("pair_nibble:");
    try writeTelemetryString(
        w,
        "policy",
        if (require_pair_nibble) "pair-nibble-required" else "separate",
    );
    try writeTelemetryString(w, "artifact", if (model.prepared_mlp_layout) |layout|
        if (layout == .pair_nibble) "pair-nibble" else "separate"
    else
        "source");
    try writeTelemetryString(
        w,
        "selected",
        if (pair_nibble_telemetry.admissions == 1)
            "pair-nibble"
        else
            "separate",
    );
    try writeTelemetryCount(w, "admissions", pair_nibble_telemetry.admissions);
    try writeTelemetryCount(
        w,
        "artifact_layers",
        pair_nibble_telemetry.artifact_layers,
    );
    try writeTelemetryCount(
        w,
        "selected_layers",
        pair_nibble_telemetry.selected_layers,
    );
    try writeTelemetryCount(
        w,
        "pair_weight_bytes",
        pair_nibble_telemetry.pair_weight_bytes,
    );
    try writeTelemetryCount(
        w,
        "pair_scale_bytes",
        pair_nibble_telemetry.pair_scale_bytes,
    );
    try writeTelemetryCount(
        w,
        "separate_gate_bytes",
        pair_nibble_telemetry.separate_gate_bytes,
    );
    try writeTelemetryCount(
        w,
        "separate_up_bytes",
        pair_nibble_telemetry.separate_up_bytes,
    );
    try writeTelemetryCount(
        w,
        "prefill_m1",
        pair_nibble_telemetry.prefill_m1_dispatches,
    );
    try writeTelemetryCount(
        w,
        "prefill_m4_groups",
        pair_nibble_telemetry.prefill_m4_groups,
    );
    try writeTelemetryCount(
        w,
        "prefill_tail_dispatches",
        pair_nibble_telemetry.prefill_tail_dispatches,
    );
    try writeTelemetryCount(
        w,
        "prefill_tail_rows",
        pair_nibble_telemetry.prefill_tail_rows,
    );
    try writeTelemetryCount(
        w,
        "decode_m1",
        pair_nibble_telemetry.decode_m1_dispatches,
    );
    try writeTelemetryCount(
        w,
        "outputless_m1",
        pair_nibble_telemetry.outputless_m1_dispatches,
    );
    try writeTelemetryCount(
        w,
        "activation_rows_quantized",
        pair_nibble_telemetry.activation_rows_quantized,
    );
    try writeTelemetryCount(
        w,
        "selected_layer_rows",
        pair_nibble_telemetry.selected_layer_rows,
    );
    try writeTelemetryCount(
        w,
        "checked_dispatches",
        pair_nibble_telemetry.checked_dispatches,
    );
    try writeTelemetryCount(
        w,
        "sealed_dispatches",
        pair_nibble_telemetry.sealed_dispatches,
    );
    try writeTelemetryCount(w, "fallbacks", pair_nibble_telemetry.fallbacks);
    try writeTelemetryCount(w, "rejects", pair_nibble_telemetry.rejects);
    try writeTelemetryHex(
        w,
        "storage_abi",
        engine.generate.pair_nibble_storage_abi,
    );
    try writeTelemetryHex(
        w,
        "executor_abi",
        engine.generate.pair_nibble_executor_abi,
    );
    try w.writeAll("\n");
    try w.writeAll("decode_frame:");
    try writeTelemetryString(
        w,
        "policy",
        switch (decode_frame_mode) {
            .automatic => "auto",
            .materialized_required => "materialized-required",
            .compact_pair_required => "compact-pair-required",
        },
    );
    try writeTelemetryString(
        w,
        "layout",
        if (pair_nibble_telemetry.decode_frame_compact_pair_uses == 1)
            "pair-q8"
        else if (pair_nibble_telemetry.decode_frame_materialized_uses == 1)
            "materialized-f32"
        else
            "none",
    );
    try writeTelemetryCount(
        w,
        "materialized_uses",
        pair_nibble_telemetry.decode_frame_materialized_uses,
    );
    try writeTelemetryCount(
        w,
        "compact_pair_uses",
        pair_nibble_telemetry.decode_frame_compact_pair_uses,
    );
    try writeTelemetryCount(
        w,
        "tensor_payload_bytes",
        pair_nibble_telemetry.decode_frame_tensor_bytes,
    );
    try writeTelemetryCount(
        w,
        "materialized_counterfactual_bytes",
        pair_nibble_telemetry.decode_frame_materialized_bytes,
    );
    try writeTelemetryCount(
        w,
        "reclaimed_tensor_payload_bytes",
        pair_nibble_telemetry.decode_frame_reclaimed_bytes,
    );
    try writeTelemetryCount(
        w,
        "pair_q8_bytes",
        pair_nibble_telemetry.pair_q8_scratch_bytes,
    );
    try writeTelemetryCount(
        w,
        "pair_scale_bytes",
        pair_nibble_telemetry.pair_activation_scale_bytes,
    );
    try writeTelemetryCount(
        w,
        "down_g8_layers",
        pair_nibble_telemetry.down_g8_layers,
    );
    try writeTelemetryCount(
        w,
        "down_g16_layers",
        pair_nibble_telemetry.down_g16_layers,
    );
    try writeTelemetryHex(
        w,
        "abi",
        engine.generate.pair_decode_frame_abi,
    );
    try w.writeAll("\n");
    try w.writeAll("pair_prefill_frame:");
    try writeTelemetryString(
        w,
        "selected_policy",
        switch (pair_prefill_frame_telemetry.selected_policy) {
            .disabled => "disabled",
            .materialized => "materialized",
            .compact_32 => "compact-32",
            .compact_64 => "compact-64",
        },
    );
    const pair_prefill_counters = [_]TelemetryCounter{
        .{ .name = "producer_g8_layers", .value = pair_prefill_frame_telemetry.producer_g8_layers },
        .{ .name = "producer_g16_layers", .value = pair_prefill_frame_telemetry.producer_g16_layers },
        .{ .name = "down_g8_layers", .value = pair_prefill_frame_telemetry.down_g8_layers },
        .{ .name = "down_g16_layers", .value = pair_prefill_frame_telemetry.down_g16_layers },
        .{ .name = "chunk_capacity", .value = pair_prefill_frame_telemetry.chunk_capacity },
        .{ .name = "chunk_count", .value = pair_prefill_frame_telemetry.chunk_count },
        .{ .name = "full_chunks", .value = pair_prefill_frame_telemetry.full_chunks },
        .{ .name = "tail_chunks", .value = pair_prefill_frame_telemetry.tail_chunks },
        .{ .name = "peak_active_rows", .value = pair_prefill_frame_telemetry.peak_active_rows },
        .{ .name = "capsule_rows", .value = pair_prefill_frame_telemetry.capsule_rows },
        .{ .name = "tile_rows", .value = pair_prefill_frame_telemetry.tile_rows },
        .{ .name = "task_slots", .value = pair_prefill_frame_telemetry.task_slots },
        .{ .name = "materialized_layer_uses", .value = pair_prefill_frame_telemetry.materialized_layer_uses },
        .{ .name = "compact_layer_uses", .value = pair_prefill_frame_telemetry.compact_layer_uses },
        .{ .name = "capsules", .value = pair_prefill_frame_telemetry.capsules },
        .{ .name = "pair_input_rows", .value = pair_prefill_frame_telemetry.pair_input_rows },
        .{ .name = "pair_output_rows", .value = pair_prefill_frame_telemetry.pair_output_rows },
        .{ .name = "prepared_down_rows", .value = pair_prefill_frame_telemetry.prepared_down_rows },
        .{ .name = "prepared_down_dispatches", .value = pair_prefill_frame_telemetry.prepared_down_dispatches },
        .{ .name = "common_payload_bytes", .value = pair_prefill_frame_telemetry.common_payload_bytes },
        .{ .name = "gate_bytes", .value = pair_prefill_frame_telemetry.gate_bytes },
        .{ .name = "up_bytes", .value = pair_prefill_frame_telemetry.up_bytes },
        .{ .name = "silu_bytes", .value = pair_prefill_frame_telemetry.silu_bytes },
        .{ .name = "q_scratch_bytes", .value = pair_prefill_frame_telemetry.q_scratch_bytes },
        .{ .name = "scale_scratch_bytes", .value = pair_prefill_frame_telemetry.scale_scratch_bytes },
        .{ .name = "pair_q8_bytes", .value = pair_prefill_frame_telemetry.pair_q8_bytes },
        .{ .name = "pair_scale_bytes", .value = pair_prefill_frame_telemetry.pair_scale_bytes },
        .{ .name = "gate_tile_bytes", .value = pair_prefill_frame_telemetry.gate_tile_bytes },
        .{ .name = "up_tile_bytes", .value = pair_prefill_frame_telemetry.up_tile_bytes },
        .{ .name = "tensor_payload_bytes", .value = pair_prefill_frame_telemetry.tensor_payload_bytes },
        .{ .name = "materialized_counterfactual_bytes", .value = pair_prefill_frame_telemetry.materialized_counterfactual_bytes },
        .{ .name = "reclaimed_tensor_payload_bytes", .value = pair_prefill_frame_telemetry.reclaimed_tensor_payload_bytes },
        .{ .name = "arena_sets", .value = pair_prefill_frame_telemetry.arena_sets },
        .{ .name = "logical_slices", .value = pair_prefill_frame_telemetry.logical_slices },
        .{ .name = "fallbacks", .value = pair_prefill_frame_telemetry.fallbacks },
        .{ .name = "rejects", .value = pair_prefill_frame_telemetry.rejects },
    };
    try writeTelemetryCounts(w, &pair_prefill_counters);
    try writeTelemetryHex(w, "abi", engine.generate.pair_prefill_frame_abi);
    try w.writeAll("\n");
    try w.writeAll("pair_scratch:");
    try writeTelemetryString(
        w,
        "policy",
        switch (pair_scratch_mode) {
            .automatic => "auto",
            .fixed_256_required => "fixed-256-required",
            .model_shaped_required => "model-shaped-required",
        },
    );
    try writeTelemetryString(
        w,
        "selected",
        switch (pair_scratch_telemetry.selected_policy) {
            .disabled => "disabled",
            .fixed_256 => "fixed-256",
            .model_shaped => "model-shaped",
        },
    );
    try writeTelemetryString(
        w,
        "layout",
        if (pair_scratch_telemetry.selected_policy == .disabled)
            "none"
        else
            "executor-private-f32",
    );
    try writeTelemetryCount(w, "participants", pair_scratch_telemetry.participants);
    try writeTelemetryCount(
        w,
        "producer_g8_layers",
        pair_scratch_telemetry.producer_g8_layers,
    );
    try writeTelemetryCount(
        w,
        "producer_g16_layers",
        pair_scratch_telemetry.producer_g16_layers,
    );
    try writeTelemetryCount(
        w,
        "selected_g8_rows",
        pair_scratch_telemetry.selected_g8_rows,
    );
    try writeTelemetryCount(
        w,
        "selected_g16_rows",
        pair_scratch_telemetry.selected_g16_rows,
    );
    try writeTelemetryCount(w, "capacity_rows", pair_scratch_telemetry.capacity_rows);
    try writeTelemetryCount(
        w,
        "arrays_per_participant",
        if (pair_scratch_telemetry.selected_policy == .disabled) 0 else 2,
    );
    try writeTelemetryCount(
        w,
        "branch_stride_rows",
        pair_scratch_telemetry.branch_stride_rows,
    );
    try writeTelemetryCount(
        w,
        "participant_stride_rows",
        pair_scratch_telemetry.participant_stride_rows,
    );
    try writeTelemetryCount(w, "f32_elements", pair_scratch_telemetry.f32_elements);
    try writeTelemetryCount(w, "bytes", pair_scratch_telemetry.bytes);
    try writeTelemetryCount(
        w,
        "fixed_counterfactual_bytes",
        pair_scratch_telemetry.fixed_counterfactual_bytes,
    );
    try writeTelemetryCount(
        w,
        "reclaimed_bytes",
        pair_scratch_telemetry.reclaimed_bytes,
    );
    try writeTelemetryCount(w, "allocations", pair_scratch_telemetry.allocations);
    try writeTelemetryCount(
        w,
        "fixed_dispatches",
        std.math.cast(usize, pair_scratch_telemetry.fixed_dispatches) orelse
            std.math.maxInt(usize),
    );
    try writeTelemetryCount(
        w,
        "model_shaped_dispatches",
        std.math.cast(usize, pair_scratch_telemetry.model_shaped_dispatches) orelse
            std.math.maxInt(usize),
    );
    try writeTelemetryCount(w, "fallbacks", pair_scratch_telemetry.fallbacks);
    try writeTelemetryCount(w, "rejects", pair_scratch_telemetry.rejects);
    try writeTelemetryHex(w, "abi", engine.generate.pair_scratch_abi);
    try w.writeAll("\n");
    try w.print(
        "decode_plan: mode={s} sets={d} set_bytes={d} layer_builds={d} layer_binds={d} checked_dispatches={d} sealed_dispatches={d} fallbacks={d} rejects={d} build_ms={d:.3} abi={x}\n",
        .{
            if (decode_plan_mode == .sealed_required) "sealed-required" else "checked",
            decode_plan_telemetry.plan_sets,
            decode_plan_telemetry.plan_set_bytes,
            decode_plan_telemetry.layer_builds,
            decode_plan_telemetry.layer_binds,
            decode_plan_telemetry.checked_dispatches,
            decode_plan_telemetry.sealed_dispatches,
            decode_plan_telemetry.fallbacks,
            decode_plan_telemetry.rejects,
            @as(f64, @floatFromInt(decode_plan_telemetry.build_ns)) / 1e6,
            engine.generate.decode_plan_abi,
        },
    );
    try w.print(
        "greedy_output: mode={s} materialized_projections={d} logitless_projections={d} producer_rows={d} tile_output_bytes={d} argmax_scan_rows={d} scratch_bytes={d} materialized_logits_bytes={d} steady_state_reclaimed_bytes={d} fallbacks={d} rejects={d} abi={x}\n",
        .{
            switch (greedy_output_mode) {
                .materialized => "materialized",
                .logitless_required => "logitless-required",
                .domain_posthead_required => "domain-posthead-required",
                .domain_prehead_required => "domain-prehead-required",
            },
            greedy_output_telemetry.materialized_projections,
            greedy_output_telemetry.logitless_projections,
            greedy_output_telemetry.producer_rows,
            greedy_output_telemetry.tile_output_bytes,
            greedy_output_telemetry.argmax_scan_rows,
            greedy_output_telemetry.scratch_bytes,
            greedy_output_telemetry.materialized_logits_bytes,
            greedy_output_telemetry.steady_state_reclaimed_bytes,
            greedy_output_telemetry.fallbacks,
            greedy_output_telemetry.rejects,
            engine.generate.greedy_output_abi,
        },
    );
    if (eligible_domain) |domain| {
        const policy_hex = std.fmt.bytesToHex(
            eligibility_provider_context.policy_binding,
            .lower,
        );
        const last_mask_hex = std.fmt.bytesToHex(
            eligibility_telemetry.last_mask_sha256,
            .lower,
        );
        const trace_hex = std.fmt.bytesToHex(
            eligibility_telemetry.trace_sha256,
            .lower,
        );
        try w.writeAll("eligible_vocab:");
        try writeTelemetryString(w, "mode", switch (greedy_output_mode) {
            .domain_posthead_required => "posthead-required",
            .domain_prehead_required => "prehead-required",
            else => unreachable,
        });
        try writeTelemetryString(w, "domain", switch (domain) {
            .static64_v1 => "static64-v1",
            .rotating64_v1 => "rotating64-v1",
        });
        try writeTelemetryCount(w, "provider_calls", eligibility_telemetry.provider_calls);
        try writeTelemetryCount(
            w,
            "certificates",
            eligibility_telemetry.certificates_accepted,
        );
        try writeTelemetryCount(
            w,
            "posthead_projections",
            eligibility_telemetry.posthead_projections,
        );
        try writeTelemetryCount(
            w,
            "prehead_projections",
            eligibility_telemetry.prehead_projections,
        );
        try writeTelemetryCount(w, "eligible_rows", eligibility_telemetry.eligible_rows);
        try writeTelemetryCount(
            w,
            "materialized_dot_rows",
            eligibility_telemetry.materialized_dot_rows,
        );
        try writeTelemetryCount(w, "producer_rows", eligibility_telemetry.producer_rows);
        try writeTelemetryCount(w, "skipped_rows", eligibility_telemetry.skipped_rows);
        try writeTelemetryCount(
            w,
            "overcomputed_rows",
            eligibility_telemetry.overcomputed_rows,
        );
        try writeTelemetryCount(w, "producer_runs", eligibility_telemetry.producer_runs);
        try writeTelemetryCount(
            w,
            "full_logits_rows_written",
            eligibility_telemetry.full_logits_rows_written,
        );
        try writeTelemetryCount(
            w,
            "full_logits_peak_bytes",
            eligibility_telemetry.full_logits_peak_bytes,
        );
        try writeTelemetryCount(
            w,
            "staging_mask_bytes",
            eligibility_telemetry.staging_mask_bytes,
        );
        try writeTelemetryCount(
            w,
            "sealed_mask_bytes",
            eligibility_telemetry.sealed_mask_bytes,
        );
        try writeTelemetryCount(
            w,
            "executor_candidate_bytes",
            eligibility_telemetry.executor_candidate_bytes,
        );
        try writeTelemetryCount(
            w,
            "executor_tile_scratch_bytes",
            eligibility_telemetry.executor_tile_scratch_bytes,
        );
        try writeTelemetryMillis(w, "provider_ms", eligibility_telemetry.provider_ns);
        try writeTelemetryMillis(
            w,
            "verification_ms",
            eligibility_telemetry.verification_ns,
        );
        try writeTelemetryCount(
            w,
            "published_tokens",
            eligibility_telemetry.published_tokens,
        );
        try writeTelemetryCount(w, "fallbacks", eligibility_telemetry.fallbacks);
        try writeTelemetryCount(w, "rejects", eligibility_telemetry.rejects);
        try writeTelemetryString(w, "policy_sha256", &policy_hex);
        try writeTelemetryString(w, "last_mask_sha256", &last_mask_hex);
        try writeTelemetryString(w, "trace_sha256", &trace_hex);
        try writeTelemetryHex(
            w,
            "provider_abi",
            engine.generate.eligibility_provider_abi,
        );
        try writeTelemetryHex(
            w,
            "executor_abi",
            engine.int4_executor.greedy_eligibility_abi,
        );
        try w.writeByte('\n');
    }

    // If requested, write generated ids to file for the external tokenizer
    // pipeline (Python detokenize.py) to decode.
    if (out_ids_file) |ofpath| {
        const f = try std.fs.cwd().createFile(ofpath, .{ .truncate = true });
        defer f.close();
        var buf2: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf2);
        for (gen, 0..) |t, idx| {
            if (idx > 0) fbs.writer().writeAll(" ") catch return error.IoError;
            fbs.writer().print("{d}", .{t}) catch return error.IoError;
        }
        f.writeAll(fbs.getWritten()) catch return error.IoError;
    }

    try w.print("  output:  {any}\n", .{gen});
    // Decode the generated tokens back to text so the user sees characters
    // rather than raw ids. The byte tokenizer round-trips ASCII losslessly.
    const decoded = try tz.decode(allocator, gen);
    defer allocator.free(decoded);
    try w.print("  text (byte-decoded): \"{s}\"\n", .{decoded});
    try w.print(
        "  time:    {d:.2} ms ({d:.1} tok/s, prefilled {d}, prefill={s})\n",
        .{
            @as(f64, @floatFromInt(elapsed_ns)) / 1e6,
            @as(f64, @floatFromInt(gen.len)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9),
            prompt.items.len,
            @tagName(prefill_path),
        },
    );
}

/// `glacier dump-weights <model.safetensors> <name_substr> [count]`
/// Prints the first `count` decoded f32 values of the first tensor whose
/// name contains the substring. Reads the SAFETENSORS file directly so we
/// see raw on-disk values — used to diff against PyTorch.
fn runDumpWeights(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
) !void {
    if (args.len < 4) {
        try w.print("usage: glacier dump-weights <model.safetensors> <name_substr> [count]\n", .{});
        return error.InvalidUsage;
    }
    const st_path = args[2];
    const needle = args[3];
    const count: usize = if (args.len >= 5)
        std.fmt.parseInt(usize, args[4], 10) catch 8
    else
        8;

    const file = try std.fs.cwd().openFile(st_path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buf);
    _ = try file.readAll(buf);

    var sf = engine.safetensors.parseHeader(allocator, buf) catch {
        try w.print("dump-weights: cannot parse safetensors at {s}\n", .{st_path});
        return error.InvalidUsage;
    };
    defer sf.deinit();

    for (sf.tensors) |t| {
        if (std.mem.indexOf(u8, t.name, needle) == null) continue;
        try w.print("tensor: {s} dtype={s} shape={any}\n", .{ t.name, @tagName(t.dtype), t.shape });

        const base = sf.data_region_start + t.data_offset;
        const bytes = buf[@intCast(base)..@intCast(base + t.byte_length)];

        var i: usize = 0;
        const step: usize = switch (t.dtype) {
            .f32 => 4,
            .f16, .bf16 => 2,
            else => 4,
        };
        const max_elems = @min(count, t.byte_length / step);
        while (i < max_elems) : (i += 1) {
            const v: f32 = switch (t.dtype) {
                .f32 => @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little)),
                .f16 => engine.core.f16bits.f16BitsToF32(std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little)),
                .bf16 => @as(f32, @bitCast(@as(u32, std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little)) << 16)),
                else => 0,
            };
            try w.print("  [{d}] = {d:.6}\n", .{ i, v });
        }
        return;
    }
    try w.print("no tensor matching '{s}'\n", .{needle});
}

/// `glacier perplexity <model.glacier> <ids_file> [batch_len] [--llama-compatible] [--cached-q8] [--fp16-scales]`
/// Computes cross-entropy perplexity over a token sequence.
fn runPerplexity(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
) !void {
    if (args.len < 4) {
        try w.print("usage: glacier perplexity <model.glacier> <ids_file> [batch_len] [--llama-compatible] [--cached-q8] [--fp16-scales]\n", .{});
        return error.InvalidUsage;
    }
    const path = args[2];
    const ids_path = args[3];
    var batch_len: usize = 8;
    var llama_compatible = false;
    var cached_q8 = false;
    var fp16_scales = false;
    for (args[4..]) |arg| {
        if (std.mem.eql(u8, arg, "--llama-compatible")) {
            llama_compatible = true;
        } else if (std.mem.eql(u8, arg, "--cached-q8")) {
            cached_q8 = true;
        } else if (std.mem.eql(u8, arg, "--fp16-scales")) {
            fp16_scales = true;
            cached_q8 = true;
        } else {
            batch_len = std.fmt.parseInt(usize, arg, 10) catch return error.InvalidUsage;
        }
    }

    var reader = try engine.model.FileReader.open(allocator, path);
    defer reader.close();
    const override = try engine.config.loadSidecar(allocator, path);
    var model = try engine.loader.loadWithOptions(allocator, &reader, override, .{
        .compact_int4 = cached_q8 or fp16_scales,
        .fp16_scale_cache = fp16_scales,
    });
    defer model.deinit();

    // Read ids file.
    const f = try std.fs.cwd().openFile(ids_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buf);
    _ = try f.readAll(buf);
    var ids_list: std.ArrayList(u32) = .{};
    defer ids_list.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, buf, " \n\r\t");
    while (it.next()) |s| {
        try ids_list.append(allocator, std.fmt.parseInt(u32, s, 10) catch continue);
    }

    try w.print("perplexity: {d} tokens, batch_len={d}, mode={s}\n", .{
        ids_list.items.len,
        batch_len,
        if (cached_q8 and fp16_scales and llama_compatible)
            "cached-q8/fp16-scales/llama-compatible"
        else if (cached_q8 and llama_compatible)
            "cached-q8/llama-compatible"
        else if (cached_q8)
            "cached-q8/all-transitions"
        else if (llama_compatible)
            "llama-compatible"
        else
            "all-transitions",
    });
    const result = if (cached_q8 and llama_compatible)
        try engine.perplexity.computeCachedLlamaCompatible(allocator, model, ids_list.items, batch_len)
    else if (cached_q8)
        try engine.perplexity.computeCached(allocator, model, ids_list.items, batch_len)
    else if (llama_compatible)
        try engine.perplexity.computeLlamaCompatible(allocator, model, ids_list.items, batch_len)
    else
        try engine.perplexity.compute(allocator, model, ids_list.items, batch_len);
    try w.print("  mean_nll:    {d:.4}\n", .{result.mean_nll});
    try w.print("  perplexity:  {d:.2}\n", .{result.perplexity});
    try w.print("  predictions: {d}\n", .{result.num_predictions});
}

/// `glacier profile <model.glacier> [num_tokens]`
/// Profiles a forward pass, printing per-phase timing breakdown.
fn runProfile(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
) !void {
    if (args.len < 3) {
        try w.print("usage: glacier profile <model.glacier> [num_tokens]\n", .{});
        return error.InvalidUsage;
    }
    const path = args[2];
    const num_tokens: usize = if (args.len >= 4)
        std.fmt.parseInt(usize, args[3], 10) catch 8
    else
        8;

    var reader = try engine.model.FileReader.open(allocator, path);
    defer reader.close();
    const override = try engine.config.loadSidecar(allocator, path);
    var model = try engine.loader.load(allocator, &reader, override);
    defer model.deinit();

    const cfg = model.config;
    try w.print("profile: {s}\n", .{path});
    try w.print("  config: layers={d} dim={d} hidden={d} heads={d}/{d} kv_dim={d}\n", .{
        cfg.num_layers,                  cfg.dim, cfg.hidden_dim, cfg.num_heads, cfg.num_kv_heads,
        cfg.num_kv_heads * cfg.head_dim,
    });

    // Run generate with timing.
    const prompt = [_]u32{0};
    var logits = try engine.core.tensor.zerosF32(allocator, &.{ 1, cfg.vocab_size });
    defer logits.deinit();

    // Warmup.
    try engine.forward.forwardModel(allocator, model, &prompt, logits);

    // Timed run: forwardModel N times (1-token prompt, prefill=1 each).
    const t0 = std.time.Timer.start() catch unreachable;
    var timer = t0;
    var t: usize = 0;
    while (t < num_tokens) : (t += 1) {
        try engine.forward.forwardModel(allocator, model, &prompt, logits);
    }
    const fwd_ns = timer.read();
    const fwd_s = @as(f64, @floatFromInt(fwd_ns)) / 1e9;
    const tok_s = @as(f64, @floatFromInt(num_tokens)) / fwd_s;

    // Estimate weight bytes touched per token.
    var weight_bytes: u64 = 0;
    weight_bytes += cfg.dim * cfg.dim * 4; // wq
    weight_bytes += cfg.num_kv_heads * cfg.head_dim * cfg.dim * 4 * 2; // wk+wv
    weight_bytes += cfg.dim * cfg.dim * 4; // wo
    weight_bytes += cfg.hidden_dim * cfg.dim * 4 * 3; // gate+up+down
    weight_bytes += cfg.dim * 4 * 4; // norms (input+post+final+...)
    weight_bytes *= cfg.num_layers;
    weight_bytes += cfg.vocab_size * cfg.dim * 4; // embedding + lm_head

    const achieved_bw = @as(f64, @floatFromInt(weight_bytes)) * tok_s / (1024.0 * 1024.0 * 1024.0);
    const macs_per_token = weight_bytes / 4 * 2; // 2 MACs per weight (multiply+add)

    try w.print(
        "  result:   {d} fwd in {d:.1} ms = {d:.1} tok/s\n",
        .{ num_tokens, fwd_s * 1000.0, tok_s },
    );
    try w.print(
        "  weights:  {d:.1} MiB/tok ({d:.1} GiB/s, {d:.1}% of 100 ceiling)\n",
        .{
            @as(f64, @floatFromInt(weight_bytes)) / (1024.0 * 1024.0),
            achieved_bw,
            achieved_bw,
        },
    );
    try w.print(
        "  compute:  {d:.1} GFLOPS ({d:.2} TFLOPS)\n",
        .{
            @as(f64, @floatFromInt(macs_per_token)) * tok_s / 1e9,
            @as(f64, @floatFromInt(macs_per_token)) * tok_s / 1e12,
        },
    );
    try w.print(
        "  per-layer: {d:.2} ms ({d} layers × {d:.0} µs)\n",
        .{
            fwd_s * 1000.0 / @as(f64, @floatFromInt(num_tokens)) / @as(f64, @floatFromInt(cfg.num_layers)),
            cfg.num_layers,
            fwd_s * 1e6 / @as(f64, @floatFromInt(num_tokens)) / @as(f64, @floatFromInt(cfg.num_layers)),
        },
    );
}

/// `glacier bench-compare <raw.glacier> <int4.glacier> <tokenizer.json> [text]`
/// Perplexity + throughput comparison table between raw and INT4.
fn runBenchCompare(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    w: *std.Io.Writer,
) !void {
    if (args.len < 5) {
        try w.print("usage: glacier bench-compare <raw.glacier> <int4.glacier> <tokenizer.json> [text]\n", .{});
        return error.InvalidUsage;
    }
    const raw_path = args[2];
    const int4_path = args[3];
    const tz_path = args[4];
    const eval_text = if (args.len >= 6) args[5] else "The quick brown fox jumps over the lazy dog";

    // Tokenize eval text via Python. Pass it as an argv value so shell
    // quoting and an implicit `echo` newline cannot change the corpus.
    const ids_path = "/tmp/glacier_eval.ids";
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "python3",
                "tools/tok.py",
                tz_path,
                "encode",
                "--text",
                eval_text,
            },
        }) catch {
            try w.print("error: need python3 + tokenizers\n", .{});
            return error.InvalidUsage;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code != 0) {
                try w.print("error: tokenizer failed: {s}\n", .{result.stderr});
                return error.InvalidUsage;
            },
            else => {
                try w.print("error: tokenizer terminated unexpectedly\n", .{});
                return error.InvalidUsage;
            },
        }
        const ids_file = try std.fs.cwd().createFile(ids_path, .{ .truncate = true });
        defer ids_file.close();
        try ids_file.writeAll(result.stdout);
    }

    // File sizes.
    const raw_stat = try std.fs.cwd().statFile(raw_path);
    const int4_stat = try std.fs.cwd().statFile(int4_path);
    const compression = @as(f64, @floatFromInt(raw_stat.size)) / @as(f64, @floatFromInt(int4_stat.size));

    try w.print("\n============================================================\n", .{});
    try w.print("Glacier Engine — Model Comparison Report\n", .{});
    try w.print("============================================================\n\n", .{});

    try w.print("Metric                Raw BF16          INT4\n", .{});
    try w.print("------------------------------------------------------------\n", .{});
    try w.print("File size         {d:>10.1} MiB  {d:>10.1} MiB\n", .{
        @as(f64, @floatFromInt(raw_stat.size)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(int4_stat.size)) / (1024.0 * 1024.0),
    });
    try w.print("Compression            —          {d:>10.1}x\n", .{compression});

    // Read ids.
    const ids = blk: {
        const f = try std.fs.cwd().openFile(ids_path, .{});
        defer f.close();
        const stat = try f.stat();
        const buf = try allocator.alloc(u8, @intCast(stat.size));
        _ = try f.readAll(buf);
        var list: std.ArrayList(u32) = .{};
        var it = std.mem.tokenizeAny(u8, buf, " \n\r\t");
        while (it.next()) |s| try list.append(allocator, std.fmt.parseInt(u32, s, 10) catch continue);
        allocator.free(buf);
        break :blk try list.toOwnedSlice(allocator);
    };
    defer allocator.free(ids);

    // Perplexity.
    try w.print("\n--- Perplexity (eval: \"{s}\") ---\n", .{eval_text});
    for ([_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "Raw BF16", .path = raw_path },
        .{ .name = "INT4", .path = int4_path },
    }) |entry| {
        var reader = try engine.model.FileReader.open(allocator, entry.path);
        defer reader.close();
        const override = try engine.config.loadSidecar(allocator, entry.path);
        var model = try engine.loader.load(allocator, &reader, override);
        defer model.deinit();
        const result = try engine.perplexity.compute(allocator, model, ids, 4);
        try w.print("  {s:<10}: perplexity={d:>8.2}  nll={d:.4}\n", .{ entry.name, result.perplexity, result.mean_nll });
    }

    // Throughput.
    try w.print("\n--- Throughput (non-cached, 1-token) ---\n", .{});
    for ([_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "Raw BF16", .path = raw_path },
        .{ .name = "INT4", .path = int4_path },
    }) |entry| {
        var reader = try engine.model.FileReader.open(allocator, entry.path);
        defer reader.close();
        const override = try engine.config.loadSidecar(allocator, entry.path);
        var model = try engine.loader.load(allocator, &reader, override);
        defer model.deinit();
        const prompt = [_]u32{0};
        var logits = try engine.core.tensor.zerosF32(allocator, &.{ 1, model.config.vocab_size });
        defer logits.deinit();
        try engine.forward.forwardModel(allocator, model, &prompt, logits);
        var timer = std.time.Timer.start() catch unreachable;
        const n: usize = 8;
        var t: usize = 0;
        while (t < n) : (t += 1) try engine.forward.forwardModel(allocator, model, &prompt, logits);
        const tps = @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(timer.read())) / 1e9);
        try w.print("  {s:<10}: {d:>8.1} tok/s\n", .{ entry.name, tps });
    }

    try w.print("\n============================================================\n", .{});
}
