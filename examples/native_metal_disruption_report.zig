//! Emit one production-native controlled-disruption Metal report as a raw
//! Native Workload Report V1 wire.
//!
//! The executable is intentionally process-scoped. If a native submission
//! becomes ambiguous, the producer fails closed and leaves retained ownership
//! intact for process termination instead of publishing a partial report.

const std = @import("std");
const engine = @import("engine");

const producer = engine.metal_native_workload_report;
const report = engine.native_workload_report;

const challenge_environment =
    "GLACIER_NATIVE_METAL_DISRUPTION_REPORT_CHALLENGE_SHA256";
const build_domain = "glacier-w7-metal-native-build-v1\x00";

pub fn main() !void {
    if (!engine.metal_enabled)
        return error.NativeMetalDisruptionReportRequiresMetal;

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

    // Bind the report to both executable components before Metal is
    // initialized. The verifier independently hashes the same files before
    // and after the process, while the producer commits the exact bytes it
    // opened to the sealed scenario identity.
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
    const artifact = try producer.runControlledDisruptionV1(
        &storage,
        &backend,
        config,
    );

    // A report exists only after the producer has proven terminal closure, so
    // backend teardown is safe before publication. Error paths before this
    // point intentionally remain process-scoped and emit no wire.
    backend.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
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
        producer.disruption_producer_abi,
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
