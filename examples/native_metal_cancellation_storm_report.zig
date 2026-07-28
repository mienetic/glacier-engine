//! Emit one production-native Metal cancellation-storm report as a raw
//! Native Workload Report V1 wire.
//!
//! Cancellation waves use two concurrent host callers on disjoint
//! production-adapter lanes before native submission. Only the bounded clean
//! control pairs submit Metal commands. A partial report is never published.

const std = @import("std");
const engine = @import("engine");

const producer = engine.metal_native_workload_report;
const report = engine.native_workload_report;

const challenge_environment =
    "GLACIER_NATIVE_METAL_CANCELLATION_STORM_REPORT_CHALLENGE_SHA256";
const build_domain =
    "glacier-w7b-metal-cancellation-storm-native-build-v1\x00";

pub fn main() !void {
    if (!engine.metal_enabled)
        return error.NativeMetalCancellationStormReportRequiresMetal;

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

    const challenge_text = std.process.getEnvVarOwned(
        argument_allocator.allocator(),
        challenge_environment,
    ) catch |value| switch (value) {
        error.EnvironmentVariableNotFound => return error.MissingCampaignChallenge,
        error.InvalidWtf8 => return error.InvalidCampaignChallenge,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer argument_allocator.allocator().free(challenge_text);
    if (challenge_text.len != 64)
        return error.InvalidCampaignChallenge;
    for (challenge_text) |byte| {
        if (!((byte >= '0' and byte <= '9') or
            (byte >= 'a' and byte <= 'f')))
            return error.InvalidCampaignChallenge;
    }
    var challenge_sha256: report.Digest = undefined;
    _ = std.fmt.hexToBytes(
        &challenge_sha256,
        challenge_text,
    ) catch return error.InvalidCampaignChallenge;

    const runner_sha256 = try fileSha256(executable_path);
    const metallib_path = std.mem.span(engine.metal_library_path);
    const metallib_sha256 = try fileSha256(metallib_path);
    const config: producer.RunConfigV1 = .{
        .build_sha256 = buildSha256(
            runner_sha256,
            metallib_sha256,
        ),
        .challenge_sha256 = challenge_sha256,
    };

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    var storage: producer.StorageV1 = .{};
    const artifact = try producer.runCancellationStormV1(
        &storage,
        &backend,
        config,
    );

    backend.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(
        &stdout_buffer,
    );
    try stdout_writer.interface.writeAll(artifact.wire);
    try stdout_writer.interface.flush();
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
    runner_sha256: report.Digest,
    metallib_sha256: report.Digest,
) report.Digest {
    var producer_abi: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &producer_abi,
        producer.cancellation_storm_producer_abi,
        .little,
    );

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(build_domain);
    hash.update(&producer_abi);
    hash.update(&runner_sha256);
    hash.update(&metallib_sha256);
    var result: report.Digest = undefined;
    hash.final(&result);
    return result;
}
