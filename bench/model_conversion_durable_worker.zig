//! Process worker for the durable Safetensors -> `.glacier` recovery campaign.
//!
//! A controller invokes one of `seed`, `victim`, `recover`, or `audit` with an
//! absolute anchor-directory path. The source and target names are fixed below.
//! In victim mode the controller, not this worker, sends SIGKILL after accepting
//! one bounded ready frame. The evidence covers host process death around file
//! and directory synchronization; it does not emulate physical power loss.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const converter = engine.converter;
const durable = engine.converter_durable;
const model = engine.model;

const source_name = "model-conversion-source.safetensors";
const target_name = "model-conversion-output.glacier";
const result_schema =
    "glacier.model-conversion-durable-recovery/result-v1";
const ready_schema =
    "glacier.model-conversion-durable-recovery/ready-v1";
const metadata_schema = "glacier.model-conversion/v1";
const fixture_architecture = "durable-recovery-fixture-v1";
const fixture_tensor_bytes: u64 = model.PAGE_SIZE_BYTES;
const fixture_elements_per_tensor: u64 =
    fixture_tensor_bytes / @sizeOf(f32);
const fixture_payload_bytes: u64 = fixture_tensor_bytes * 3;

const fixture_header =
    \\{"model.layers.1.self_attn.q_proj.weight":{"dtype":"F32","shape":[65536],"data_offsets":[0,262144]},"model.layers.2.mlp.down_proj.weight":{"dtype":"F32","shape":[65536],"data_offsets":[262144,524288]},"model.embed_tokens.weight":{"dtype":"F32","shape":[65536],"data_offsets":[524288,786432]},"__metadata__":{"format":"pt","fixture":"glacier-durable-recovery-v1"}}
;

const FixtureGenerationV1 = enum {
    predecessor,
    successor,
};

const AuditV1 = struct {
    source_identity: durable.SourceIdentityV1,
    artifact_identity: durable.ArtifactIdentityV1,
    conversion_profile_sha256: [32]u8,
    conversion_plan_sha256: [32]u8,
};

const ResultFrameV1 = struct {
    mode: []const u8,
    disposition: []const u8,
    audit: AuditV1,
    publication_plan_sha256: [32]u8,
    conversion_workspace_bytes_peak: u64,
    stale_candidate_removed: bool,
};

const MetadataV1 = struct {
    schema: []const u8,
    architecture: []const u8,
    num_pages: u64,
    page_size_bytes: u64,
    source_bytes: u64,
    source_sha256: []const u8,
    conversion_profile_sha256: []const u8,
    conversion_plan_sha256: []const u8,
};

const CrashGateV1 = struct {
    target: durable.PublicationPhaseV1,
    source_identity: durable.SourceIdentityV1,
    publication_plan_sha256: [32]u8,

    fn afterPhase(
        raw: *anyopaque,
        phase: durable.PublicationPhaseV1,
    ) anyerror!void {
        const self: *CrashGateV1 = @ptrCast(@alignCast(raw));
        if (phase != self.target) return;
        try emitReadyAndWaitForSupervisorV1(
            phase,
            self.source_identity,
            self.publication_plan_sha256,
        );
    }

    fn interface(self: *CrashGateV1) durable.ObserverV1 {
        return .{
            .context = self,
            .after_phase_fn = afterPhase,
        };
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);

    if (arguments.len < 3 or
        !std.fs.path.isAbsolute(arguments[2]))
        return error.InvalidArguments;
    if (std.mem.eql(u8, arguments[1], "seed")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runSeedV1(allocator, arguments[2]);
        return;
    }
    if (std.mem.eql(u8, arguments[1], "victim")) {
        if (arguments.len != 4) return error.InvalidArguments;
        const phase = std.meta.stringToEnum(
            durable.PublicationPhaseV1,
            arguments[3],
        ) orelse return error.InvalidArguments;
        try runVictimV1(allocator, arguments[2], phase);
        return;
    }
    if (std.mem.eql(u8, arguments[1], "recover")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runRecoverV1(allocator, arguments[2]);
        return;
    }
    if (std.mem.eql(u8, arguments[1], "audit")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runAuditV1(allocator, arguments[2]);
        return;
    }
    return error.InvalidArguments;
}

fn runSeedV1(
    allocator: std.mem.Allocator,
    absolute_anchor: []const u8,
) !void {
    try writeFixtureV1(
        absolute_anchor,
        .predecessor,
    );
    const source_path = try fixedPathV1(
        allocator,
        absolute_anchor,
        source_name,
    );
    defer allocator.free(source_path);
    const receipt = try publishV1(
        allocator,
        absolute_anchor,
        source_path,
        null,
    );
    const audit = try auditV1(
        allocator,
        absolute_anchor,
        source_path,
    );
    try verifyReceiptV1(receipt, audit);
    try emitResultV1(.{
        .mode = "seed",
        .disposition = @tagName(receipt.disposition),
        .audit = audit,
        .publication_plan_sha256 = receipt.publication_plan_sha256,
        .conversion_workspace_bytes_peak = receipt.conversion.conversion_workspace_bytes_peak,
        .stale_candidate_removed = receipt.stale_candidate_removed,
    });
}

fn runVictimV1(
    allocator: std.mem.Allocator,
    absolute_anchor: []const u8,
    phase: durable.PublicationPhaseV1,
) !void {
    try writeFixtureV1(
        absolute_anchor,
        .successor,
    );
    const source_path = try fixedPathV1(
        allocator,
        absolute_anchor,
        source_name,
    );
    defer allocator.free(source_path);
    const source_identity = try sourceIdentityV1(source_path);
    const options = conversionOptionsV1();
    var gate: CrashGateV1 = .{
        .target = phase,
        .source_identity = source_identity,
        .publication_plan_sha256 = durable.publicationPlanSha256V1(
            target_name,
            source_identity,
            options,
        ),
    };
    _ = try publishV1(
        allocator,
        absolute_anchor,
        source_path,
        gate.interface(),
    );
    return error.CrashPointNotReached;
}

fn runRecoverV1(
    allocator: std.mem.Allocator,
    absolute_anchor: []const u8,
) !void {
    try writeFixtureV1(
        absolute_anchor,
        .successor,
    );
    const source_path = try fixedPathV1(
        allocator,
        absolute_anchor,
        source_name,
    );
    defer allocator.free(source_path);
    const receipt = try publishV1(
        allocator,
        absolute_anchor,
        source_path,
        null,
    );
    const audit = try auditV1(
        allocator,
        absolute_anchor,
        source_path,
    );
    try verifyReceiptV1(receipt, audit);
    try emitResultV1(.{
        .mode = "recover",
        .disposition = @tagName(receipt.disposition),
        .audit = audit,
        .publication_plan_sha256 = receipt.publication_plan_sha256,
        .conversion_workspace_bytes_peak = receipt.conversion.conversion_workspace_bytes_peak,
        .stale_candidate_removed = receipt.stale_candidate_removed,
    });
}

fn runAuditV1(
    allocator: std.mem.Allocator,
    absolute_anchor: []const u8,
) !void {
    const source_path = try fixedPathV1(
        allocator,
        absolute_anchor,
        source_name,
    );
    defer allocator.free(source_path);
    const audit = try auditV1(
        allocator,
        absolute_anchor,
        source_path,
    );
    const publication_plan_sha256 =
        durable.publicationPlanSha256V1(
            target_name,
            audit.source_identity,
            conversionOptionsV1(),
        );
    try emitResultV1(.{
        .mode = "audit",
        .disposition = "observed",
        .audit = audit,
        .publication_plan_sha256 = publication_plan_sha256,
        .conversion_workspace_bytes_peak = 0,
        .stale_candidate_removed = false,
    });
}

fn publishV1(
    allocator: std.mem.Allocator,
    absolute_anchor: []const u8,
    source_path: []const u8,
    observer: ?durable.ObserverV1,
) !durable.PublicationReceiptV1 {
    var anchor = try std.fs.openDirAbsolute(
        absolute_anchor,
        .{
            .iterate = false,
            .no_follow = true,
        },
    );
    defer anchor.close();
    var publisher = try durable.PublisherV1.init(anchor);
    defer publisher.close();
    return publisher.convertSafetensors(
        allocator,
        source_path,
        target_name,
        conversionOptionsV1(),
        observer,
    );
}

fn conversionOptionsV1() converter.ConvertOptions {
    return .{
        .page_size_bytes = model.PAGE_SIZE_BYTES,
        .architecture = fixture_architecture,
        .verify_on_write = true,
        .quantize_int4 = false,
    };
}

fn writeFixtureV1(
    absolute_anchor: []const u8,
    generation: FixtureGenerationV1,
) !void {
    if (fixture_elements_per_tensor != 65_536 or
        fixture_payload_bytes != 786_432)
        return error.InvalidFixtureGeometry;
    var anchor = try std.fs.openDirAbsolute(
        absolute_anchor,
        .{
            .iterate = false,
            .no_follow = true,
        },
    );
    defer anchor.close();
    const file = try anchor.createFile(
        source_name,
        .{
            .read = true,
            .truncate = true,
            .mode = 0o600,
        },
    );
    defer file.close();

    var encoded_header_len: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(
        u64,
        &encoded_header_len,
        fixture_header.len,
        .little,
    );
    try file.writeAll(&encoded_header_len);
    try file.writeAll(fixture_header);

    var buffer: [64 * 1024]u8 = undefined;
    var payload_offset: u64 = 0;
    while (payload_offset < fixture_payload_bytes) {
        const chunk_len: usize = @intCast(@min(
            fixture_payload_bytes - payload_offset,
            @as(u64, buffer.len),
        ));
        for (buffer[0..chunk_len], 0..) |*byte, index| {
            const position = payload_offset +
                @as(u64, @intCast(index));
            byte.* = fixtureByteV1(
                generation,
                position,
            );
        }
        try file.writeAll(buffer[0..chunk_len]);
        payload_offset += chunk_len;
    }
    try file.sync();
}

fn fixtureByteV1(
    generation: FixtureGenerationV1,
    position: u64,
) u8 {
    const low: u8 = @truncate(position);
    const high: u8 = @truncate(position >> 11);
    return switch (generation) {
        .predecessor => low *% 17 +% high *% 29 +% 0x31,
        .successor => low *% 43 +% high *% 7 +% 0xa7,
    };
}

fn auditV1(
    allocator: std.mem.Allocator,
    absolute_anchor: []const u8,
    source_path: []const u8,
) !AuditV1 {
    const source_identity = try sourceIdentityV1(source_path);
    var anchor = try std.fs.openDirAbsolute(
        absolute_anchor,
        .{
            .iterate = false,
            .no_follow = true,
        },
    );
    defer anchor.close();
    const artifact_file = try anchor.openFile(
        target_name,
        .{},
    );
    defer artifact_file.close();
    var reader = try model.FileReader.openBorrowedFile(
        allocator,
        artifact_file,
    );
    defer reader.close();
    try reader.validateAllPageCrcs();
    const container_identity =
        try reader.containerIdentityV1();
    if (reader.pages.len < 3)
        return error.InvalidFixturePageCount;

    const parsed = try std.json.parseFromSlice(
        MetadataV1,
        allocator,
        reader.meta_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const metadata = parsed.value;
    if (!std.mem.eql(u8, metadata.schema, metadata_schema) or
        !std.mem.eql(
            u8,
            metadata.architecture,
            fixture_architecture,
        ) or
        metadata.num_pages != reader.pages.len or
        metadata.page_size_bytes != model.PAGE_SIZE_BYTES or
        metadata.source_bytes != source_identity.source_bytes)
        return error.InvalidArtifactMetadata;
    const metadata_source_sha256 =
        try parseDigestV1(metadata.source_sha256);
    const conversion_profile_sha256 =
        try parseDigestV1(
            metadata.conversion_profile_sha256,
        );
    const conversion_plan_sha256 =
        try parseDigestV1(
            metadata.conversion_plan_sha256,
        );
    if (!digestEqlV1(
        metadata_source_sha256,
        source_identity.source_sha256,
    ))
        return error.SourceIdentityMismatch;

    return .{
        .source_identity = source_identity,
        .artifact_identity = .{
            .container_bytes = container_identity.container_bytes,
            .page_count = @intCast(reader.pages.len),
            .container_sha256 = container_identity.container_sha256,
        },
        .conversion_profile_sha256 = conversion_profile_sha256,
        .conversion_plan_sha256 = conversion_plan_sha256,
    };
}

fn verifyReceiptV1(
    receipt: durable.PublicationReceiptV1,
    audit: AuditV1,
) !void {
    if (receipt.abi_version != durable.publication_abi or
        !std.meta.eql(
            receipt.source_identity,
            audit.source_identity,
        ) or
        !std.meta.eql(
            receipt.artifact_identity,
            audit.artifact_identity,
        ) or
        receipt.conversion.num_pages !=
            audit.artifact_identity.page_count or
        receipt.conversion.output_bytes !=
            audit.artifact_identity.container_bytes or
        receipt.conversion.source_bytes !=
            audit.source_identity.source_bytes or
        !digestEqlV1(
            receipt.conversion.source_sha256,
            audit.source_identity.source_sha256,
        ) or
        !digestEqlV1(
            receipt.conversion.output_sha256,
            audit.artifact_identity.container_sha256,
        ) or
        !digestEqlV1(
            receipt.conversion.conversion_profile_sha256,
            audit.conversion_profile_sha256,
        ) or
        !digestEqlV1(
            receipt.conversion.conversion_plan_sha256,
            audit.conversion_plan_sha256,
        ))
        return error.PublicationReceiptMismatch;
}

fn sourceIdentityV1(
    source_path: []const u8,
) !durable.SourceIdentityV1 {
    const file = try std.fs.cwd().openFile(
        source_path,
        .{},
    );
    defer file.close();
    const stat = try file.stat();
    if (stat.kind != .file)
        return error.InvalidSourceFile;
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [model.STREAM_BUFFER_SIZE]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const chunk_len: usize = @intCast(@min(
            stat.size - offset,
            @as(u64, buffer.len),
        ));
        const chunk = buffer[0..chunk_len];
        if (try file.preadAll(chunk, offset) != chunk.len)
            return error.TruncatedSource;
        sha256.update(chunk);
        offset = std.math.add(
            u64,
            offset,
            chunk.len,
        ) catch return error.SourceTooLarge;
    }
    var digest: [32]u8 = undefined;
    sha256.final(&digest);
    return .{
        .source_bytes = stat.size,
        .source_sha256 = digest,
    };
}

fn fixedPathV1(
    allocator: std.mem.Allocator,
    absolute_anchor: []const u8,
    name: []const u8,
) ![]u8 {
    return std.fs.path.join(
        allocator,
        &.{ absolute_anchor, name },
    );
}

fn parseDigestV1(encoded: []const u8) ![32]u8 {
    if (encoded.len != 64)
        return error.InvalidDigest;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, encoded) catch
        return error.InvalidDigest;
    return digest;
}

fn emitReadyAndWaitForSupervisorV1(
    phase: durable.PublicationPhaseV1,
    source_identity: durable.SourceIdentityV1,
    publication_plan_sha256: [32]u8,
) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"{s}\",\"mode\":\"victim\"," ++
            "\"pid\":{d},\"disposition\":\"ready\"," ++
            "\"phase\":\"victim_ready\",\"crash_point\":\"{s}\"," ++
            "\"source_name\":\"{s}\"," ++
            "\"target_name\":\"{s}\",\"source_bytes\":{d}," ++
            "\"source_sha256\":\"",
        .{
            ready_schema,
            currentProcessIdV1(),
            @tagName(phase),
            source_name,
            target_name,
            source_identity.source_bytes,
        },
    );
    try writeDigestV1(
        writer,
        source_identity.source_sha256,
    );
    try writer.writeAll(
        "\",\"publication_plan_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        publication_plan_sha256,
    );
    try writer.writeAll(
        "\",\"host_process_recovery\":true," ++
            "\"power_loss_emulated\":false}\n",
    );
    try writer.flush();
    try waitForSupervisorKillV1();
    return error.SupervisorDidNotKillWorker;
}

fn emitResultV1(frame: ResultFrameV1) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"{s}\",\"mode\":\"{s}\"," ++
            "\"pid\":{d},\"disposition\":\"{s}\"," ++
            "\"source_name\":\"{s}\",\"target_name\":\"{s}\"," ++
            "\"source_bytes\":{d},\"output_bytes\":{d}," ++
            "\"num_pages\":{d}," ++
            "\"conversion_workspace_bytes_peak\":{d}," ++
            "\"source_sha256\":\"",
        .{
            result_schema,
            frame.mode,
            currentProcessIdV1(),
            frame.disposition,
            source_name,
            target_name,
            frame.audit.source_identity.source_bytes,
            frame.audit.artifact_identity.container_bytes,
            frame.audit.artifact_identity.page_count,
            frame.conversion_workspace_bytes_peak,
        },
    );
    try writeDigestV1(
        writer,
        frame.audit.source_identity.source_sha256,
    );
    try writer.writeAll("\",\"output_sha256\":\"");
    try writeDigestV1(
        writer,
        frame.audit.artifact_identity.container_sha256,
    );
    try writer.writeAll(
        "\",\"conversion_profile_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.audit.conversion_profile_sha256,
    );
    try writer.writeAll(
        "\",\"conversion_plan_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.audit.conversion_plan_sha256,
    );
    try writer.writeAll(
        "\",\"publication_plan_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.publication_plan_sha256,
    );
    try writer.print(
        "\",\"stale_candidate_removed\":{s}," ++
            "\"verified\":true," ++
            "\"host_process_recovery\":true," ++
            "\"power_loss_emulated\":false}}\n",
        .{booleanNameV1(frame.stale_candidate_removed)},
    );
    try writer.flush();
}

fn waitForSupervisorKillV1() !void {
    var stdin = std.fs.File.stdin();
    var one_byte: [1]u8 = undefined;
    while (true) {
        const count = try stdin.read(&one_byte);
        if (count == 0)
            return error.SupervisorBarrierClosed;
    }
}

fn writeDigestV1(
    writer: *std.Io.Writer,
    digest: [32]u8,
) !void {
    const encoded = std.fmt.bytesToHex(digest, .lower);
    try writer.writeAll(&encoded);
}

fn digestEqlV1(
    left: [32]u8,
    right: [32]u8,
) bool {
    return std.mem.eql(u8, &left, &right);
}

fn booleanNameV1(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn currentProcessIdV1() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}
