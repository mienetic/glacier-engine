//! Persistent production-native Metal worker for bounded W7 soak segments.
//!
//! Stdin accepts one lowercase 64-hex challenge per line. Each accepted line
//! runs a fresh, paced controlled-disruption campaign on the same Metal
//! backend. Stdout emits one little-endian u64 wire length followed by the
//! exact Native Workload Report V1 wire, then flushes the frame.

const std = @import("std");
const engine = @import("engine");

const producer = engine.metal_native_workload_report;
const report = engine.native_workload_report;

const build_domain = "glacier-w7-metal-native-build-v1\x00";
const maximum_segments: usize = 6;
const epoch_start_spacing_ns: u64 = 100 * std.time.ns_per_ms;

pub fn main() !void {
    if (!engine.metal_enabled)
        return error.NativeMetalSoakWorkerRequiresMetal;

    var argument_storage: [4096]u8 = undefined;
    var argument_allocator = std.heap.FixedBufferAllocator.init(
        &argument_storage,
    );
    var args = try std.process.argsWithAllocator(
        argument_allocator.allocator(),
    );
    defer args.deinit();
    const executable_path = args.next() orelse
        return error.MissingExecutablePath;
    if (args.next() != null) return error.UnexpectedArgument;

    // Bind every segment to the exact worker and metallib bytes opened before
    // Metal initialization. The parent verifier can independently hash both
    // components around the persistent process lifetime.
    const worker_sha256 = try fileSha256(executable_path);
    const metallib_path = std.mem.span(engine.metal_library_path);
    const metallib_sha256 = try fileSha256(metallib_path);
    const build_sha256 = buildSha256(
        worker_sha256,
        metallib_sha256,
    );

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    var backend_safe_to_deinit = true;
    defer if (backend_safe_to_deinit) backend.deinit();

    const stdin = std.fs.File.stdin();
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(
        &stdout_buffer,
    );
    const stdout = &stdout_writer.interface;
    var challenge_text: [64]u8 = undefined;
    var segment_count: usize = 0;

    while (try readChallengeLine(stdin, &challenge_text)) |line| {
        if (segment_count == maximum_segments)
            return error.TooManySoakSegments;
        const challenge_sha256 = try parseChallenge(line);
        const config: producer.RunConfigV1 = .{
            .build_sha256 = build_sha256,
            .challenge_sha256 = challenge_sha256,
            .epoch_start_spacing_ns = epoch_start_spacing_ns,
        };

        var storage: producer.StorageV1 = .{};
        backend_safe_to_deinit = false;
        const artifact = try producer.runControlledDisruptionV1(
            &storage,
            &backend,
            config,
        );
        backend_safe_to_deinit = true;

        var length_wire: [8]u8 = undefined;
        std.mem.writeInt(
            u64,
            &length_wire,
            std.math.cast(u64, artifact.wire.len) orelse
                return error.ReportLengthOverflow,
            .little,
        );
        try stdout.writeAll(&length_wire);
        try stdout.writeAll(artifact.wire);
        try stdout.flush();
        segment_count += 1;
    }

    if (segment_count == 0) return error.EmptySoakSession;
}

fn readChallengeLine(
    stdin: std.fs.File,
    storage: *[64]u8,
) !?[]const u8 {
    var length: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        const read_length = try stdin.read(&byte);
        if (read_length == 0) {
            if (length == 0) return null;
            return error.TruncatedCampaignChallenge;
        }
        if (byte[0] == '\n') return storage[0..length];
        if (length == storage.len)
            return error.InvalidCampaignChallenge;
        storage[length] = byte[0];
        length += 1;
    }
}

fn parseChallenge(value: []const u8) !report.Digest {
    if (value.len != 64) return error.InvalidCampaignChallenge;
    for (value) |byte| {
        if (!((byte >= '0' and byte <= '9') or
            (byte >= 'a' and byte <= 'f')))
            return error.InvalidCampaignChallenge;
    }
    var result: report.Digest = undefined;
    _ = std.fmt.hexToBytes(
        &result,
        value,
    ) catch return error.InvalidCampaignChallenge;
    return result;
}

fn fileSha256(path: []const u8) !report.Digest {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [64 * 1024]u8 = undefined;
    while (true) {
        const length = try file.read(&bytes);
        if (length == 0) break;
        hash.update(bytes[0..length]);
    }
    var result: report.Digest = undefined;
    hash.final(&result);
    return result;
}

fn buildSha256(
    worker_sha256: report.Digest,
    metallib_sha256: report.Digest,
) report.Digest {
    var producer_abi: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &producer_abi,
        producer.disruption_producer_abi,
        .little,
    );

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(build_domain);
    hash.update(&producer_abi);
    hash.update(&worker_sha256);
    hash.update(&metallib_sha256);
    var result: report.Digest = undefined;
    hash.final(&result);
    return result;
}
