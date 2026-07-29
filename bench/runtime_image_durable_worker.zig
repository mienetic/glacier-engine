//! Process worker for the durable GLRT host-filesystem recovery campaign.
//!
//! The supervisor, not this worker, sends SIGKILL after accepting one bounded
//! ready frame. The resulting evidence covers host process death around file
//! and directory sync calls; it does not emulate or claim physical power loss.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const runtime_image = engine.runtime_image;
const durable = engine.runtime_image_durable;

const protocol_name_max_bytes = 128;

const predecessor_raw = [_]u8{
    0x00, 0x00, 0x80, 0x3f,
    0x00, 0x00, 0x00, 0x40,
    0x00, 0x00, 0x40, 0x40,
    0x00, 0x00, 0x80, 0x40,
};
const predecessor_packed = [_]u8{
    0x10, 0x32, 0x54, 0x76,
    0x67, 0x45, 0x23, 0x01,
};
const predecessor_scale = [_]u8{ 0x00, 0x00, 0x00, 0x3f };

const successor_raw = [_]u8{
    0x00, 0x00, 0x10, 0x41,
    0x00, 0x00, 0x20, 0x41,
    0x00, 0x00, 0x30, 0x41,
    0x00, 0x00, 0x40, 0x41,
};
const successor_packed = [_]u8{
    0x89, 0xab, 0xcd, 0xef,
    0xfe, 0xdc, 0xba, 0x98,
};
const successor_scale = [_]u8{ 0x00, 0x00, 0x80, 0x3e };

const CrashPointV1 = enum {
    provider_mid_record,
    stale_candidate_removed,
    candidate_created,
    candidate_encoded,
    candidate_synced,
    candidate_validated,
    target_replaced,
    directory_committed,
};

const FixtureGenerationV1 = enum {
    predecessor,
    successor,
};

const ResultFrameV1 = struct {
    mode: []const u8,
    target_name: []const u8,
    disposition: []const u8,
    identity: runtime_image.ImageIdentityV1,
    publication_plan_sha256: ?[32]u8,
    stats: runtime_image.WriteStats,
    stale_candidate_removed: bool,
};

const CrashGateV1 = struct {
    target: CrashPointV1,
    target_name: []const u8,
    publication_plan_sha256: [32]u8,

    fn afterPhase(
        raw: *anyopaque,
        phase: durable.PublicationPhaseV1,
    ) anyerror!void {
        const self: *CrashGateV1 = @ptrCast(@alignCast(raw));
        const point: CrashPointV1 = switch (phase) {
            .stale_candidate_removed => .stale_candidate_removed,
            .candidate_created => .candidate_created,
            .candidate_encoded => .candidate_encoded,
            .candidate_synced => .candidate_synced,
            .candidate_validated => .candidate_validated,
            .target_replaced => .target_replaced,
            .directory_committed => .directory_committed,
        };
        if (self.target != point) return;
        try emitReadyAndWaitForSupervisorV1(
            self.target_name,
            self.publication_plan_sha256,
            point,
        );
    }
};

const FixtureProviderV1 = struct {
    crash_gate: ?*CrashGateV1,
    next_record_index: usize = 0,
    workspace: [16]u8 = @splat(0),

    fn materialize(
        raw: *anyopaque,
        record_index: usize,
        planned: runtime_image.WriteRecord,
    ) anyerror!runtime_image.MaterializedWriteRecord {
        const self: *FixtureProviderV1 = @ptrCast(@alignCast(raw));
        if (record_index != self.next_record_index or record_index >= 2)
            return error.InvalidProviderOrder;
        if (record_index == 1) {
            if (self.crash_gate) |gate| {
                if (gate.target == .provider_mid_record) {
                    try emitReadyAndWaitForSupervisorV1(
                        gate.target_name,
                        gate.publication_plan_sha256,
                        .provider_mid_record,
                    );
                }
            }
        }

        var materialized = planned;
        switch (record_index) {
            0 => {
                if (planned.raw.len != self.workspace.len)
                    return error.InvalidFixturePlan;
                @memcpy(&self.workspace, planned.raw);
                materialized.raw = &self.workspace;
            },
            1 => {
                if (planned.packed_bytes.len != 8 or
                    planned.scales_f32.len != 4)
                    return error.InvalidFixturePlan;
                @memcpy(
                    self.workspace[0..8],
                    planned.packed_bytes,
                );
                @memcpy(
                    self.workspace[8..12],
                    planned.scales_f32,
                );
                materialized.packed_bytes = self.workspace[0..8];
                materialized.scales_f32 = self.workspace[8..12];
            },
            else => unreachable,
        }
        self.next_record_index += 1;
        return .{
            .record = materialized,
            .generated = true,
            .workspace_bytes = self.workspace.len,
        };
    }

    fn finish(raw: *anyopaque) anyerror!void {
        const self: *FixtureProviderV1 = @ptrCast(@alignCast(raw));
        if (self.next_record_index != 2)
            return error.IncompleteProvider;
    }

    fn interface(self: *FixtureProviderV1) runtime_image.WriteRecordProvider {
        return .{
            .context = self,
            .materialize = materialize,
            .finish = finish,
        };
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);

    if (arguments.len < 2)
        return error.InvalidArguments;
    if (std.mem.eql(u8, arguments[1], "seed")) {
        if (arguments.len != 4) return error.InvalidArguments;
        try validateProtocolNameV1(arguments[3]);
        try runSeedV1(
            allocator,
            arguments[2],
            arguments[3],
        );
        return;
    }
    if (std.mem.eql(u8, arguments[1], "victim")) {
        if (arguments.len != 5) return error.InvalidArguments;
        try validateProtocolNameV1(arguments[3]);
        const point = std.meta.stringToEnum(
            CrashPointV1,
            arguments[4],
        ) orelse return error.InvalidArguments;
        try runVictimV1(
            allocator,
            arguments[2],
            arguments[3],
            point,
        );
        return;
    }
    if (std.mem.eql(u8, arguments[1], "recover")) {
        if (arguments.len != 4) return error.InvalidArguments;
        try validateProtocolNameV1(arguments[3]);
        try runRecoverV1(
            allocator,
            arguments[2],
            arguments[3],
        );
        return;
    }
    if (std.mem.eql(u8, arguments[1], "audit")) {
        if (arguments.len != 4) return error.InvalidArguments;
        try validateProtocolNameV1(arguments[3]);
        try runAuditV1(
            arguments[2],
            arguments[3],
        );
        return;
    }
    return error.InvalidArguments;
}

fn runSeedV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    target_name: []const u8,
) !void {
    const records = fixtureRecordsV1(.predecessor);
    const options = fixtureOptionsV1(.predecessor);
    const receipt = try publishV1(
        allocator,
        absolute_directory,
        target_name,
        options,
        &records,
        null,
        null,
    );
    if (receipt.disposition != .published or
        receipt.stats.generated_records != 0 or
        receipt.stats.generated_workspace_bytes_total != 0 or
        receipt.stats.generated_workspace_bytes_peak != 0)
        return error.InvalidSeedReceipt;
    try emitResultV1(.{
        .mode = "seed",
        .target_name = target_name,
        .disposition = @tagName(receipt.disposition),
        .identity = receipt.image_identity,
        .publication_plan_sha256 = receipt.publication_plan_sha256,
        .stats = receipt.stats,
        .stale_candidate_removed = receipt.stale_candidate_removed,
    });
}

fn runVictimV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    target_name: []const u8,
    point: CrashPointV1,
) !void {
    const records = fixtureRecordsV1(.successor);
    const options = fixtureOptionsV1(.successor);
    var gate: CrashGateV1 = .{
        .target = point,
        .target_name = target_name,
        .publication_plan_sha256 = durable.publicationPlanSha256V1(
            target_name,
            options,
            &records,
        ),
    };
    var provider_state: FixtureProviderV1 = .{
        .crash_gate = &gate,
    };
    const provider = provider_state.interface();
    const observer: ?durable.ObserverV1 =
        if (point == .provider_mid_record)
            null
        else
            .{
                .context = &gate,
                .after_phase_fn = CrashGateV1.afterPhase,
            };
    _ = try publishV1(
        allocator,
        absolute_directory,
        target_name,
        options,
        &records,
        provider,
        observer,
    );
    return error.CrashPointNotReached;
}

fn runRecoverV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    target_name: []const u8,
) !void {
    const records = fixtureRecordsV1(.successor);
    const options = fixtureOptionsV1(.successor);
    var provider_state: FixtureProviderV1 = .{
        .crash_gate = null,
    };
    const provider = provider_state.interface();
    const receipt = try publishV1(
        allocator,
        absolute_directory,
        target_name,
        options,
        &records,
        provider,
        null,
    );
    if (receipt.stats.generated_records != 2 or
        receipt.stats.generated_workspace_bytes_total != 32 or
        receipt.stats.generated_workspace_bytes_peak != 16)
        return error.InvalidRecoveryReceipt;
    try emitResultV1(.{
        .mode = "recover",
        .target_name = target_name,
        .disposition = @tagName(receipt.disposition),
        .identity = receipt.image_identity,
        .publication_plan_sha256 = receipt.publication_plan_sha256,
        .stats = receipt.stats,
        .stale_candidate_removed = receipt.stale_candidate_removed,
    });
}

fn runAuditV1(
    absolute_directory: []const u8,
    target_name: []const u8,
) !void {
    var directory = try std.fs.openDirAbsolute(
        absolute_directory,
        .{},
    );
    defer directory.close();
    const options = fixtureOptionsV1(.successor);
    var image = try runtime_image.MappedImage.openWithOptionsAt(
        directory,
        target_name,
        .{
            .allow_v1 = false,
            .expected_source_fingerprint = options.source_fingerprint,
            .expected_abi_fingerprint = options.abi_fingerprint,
            .expected_v1_abi_fingerprint = null,
        },
    );
    defer image.close();
    if (image.recordCount() != 2)
        return error.InvalidAuditImage;
    try emitResultV1(.{
        .mode = "audit",
        .target_name = target_name,
        .disposition = "observed",
        .identity = image.identityV1(),
        .publication_plan_sha256 = null,
        .stats = .{},
        .stale_candidate_removed = false,
    });
}

fn publishV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    target_name: []const u8,
    options: runtime_image.WriteOptions,
    records: []const runtime_image.WriteRecord,
    provider: ?runtime_image.WriteRecordProvider,
    observer: ?durable.ObserverV1,
) !durable.PublicationReceiptV1 {
    var anchor = try std.fs.openDirAbsolute(
        absolute_directory,
        .{},
    );
    defer anchor.close();
    var publisher = try durable.PublisherV1.init(anchor);
    defer publisher.close();
    return publisher.writeWithProvider(
        allocator,
        target_name,
        options,
        records,
        provider,
        observer,
    );
}

fn fixtureConfigV1() runtime_image.ConfigSnapshot {
    return .{
        .dim = 16,
        .hidden_dim = 32,
        .layers = 2,
        .vocab = 64,
        .heads = 2,
        .head_dim = 8,
        .kv_heads = 1,
        .rms_eps = 1e-6,
        .rope_theta = 10_000,
        .tie_embeddings = true,
    };
}

fn fixtureOptionsV1(
    generation: FixtureGenerationV1,
) runtime_image.WriteOptions {
    const source_name: []const u8 = switch (generation) {
        .predecessor => "glacier-durable-recovery-predecessor-v1",
        .successor => "glacier-durable-recovery-successor-v1",
    };
    return .{
        .config = fixtureConfigV1(),
        .source_fingerprint = runtime_image.fingerprint(source_name),
        .sync = true,
    };
}

fn fixtureRecordsV1(
    generation: FixtureGenerationV1,
) [2]runtime_image.WriteRecord {
    const raw = switch (generation) {
        .predecessor => &predecessor_raw,
        .successor => &successor_raw,
    };
    const packed_bytes = switch (generation) {
        .predecessor => &predecessor_packed,
        .successor => &successor_packed,
    };
    const scale = switch (generation) {
        .predecessor => &predecessor_scale,
        .successor => &successor_scale,
    };
    return .{
        .{
            .key = .{
                .layer_idx = 0,
                .kind = .final_norm,
            },
            .encoding = .raw_f32,
            .packed_layout = .none,
            .group_size = 0,
            .out_f = 1,
            .in_f = 4,
            .num_elements = 4,
            .raw = raw,
        },
        .{
            .key = .{
                .layer_idx = 0,
                .kind = .attn_q,
            },
            .encoding = .int4,
            .packed_layout = .row_major,
            .group_size = 16,
            .out_f = 1,
            .in_f = 16,
            .num_elements = 16,
            .packed_bytes = packed_bytes,
            .scales_f32 = scale,
        },
    };
}

fn emitReadyAndWaitForSupervisorV1(
    target_name: []const u8,
    publication_plan_sha256: [32]u8,
    point: CrashPointV1,
) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":" ++
            "\"glacier.runtime-image-durable-recovery/ready-v1\"," ++
            "\"phase\":\"victim_ready\",\"pid\":{d}," ++
            "\"crash_point\":\"{s}\",\"target_name\":\"{s}\"," ++
            "\"publication_plan_sha256\":\"",
        .{
            currentProcessIdV1(),
            @tagName(point),
            target_name,
        },
    );
    try writeDigestV1(writer, publication_plan_sha256);
    try writer.writeAll(
        "\",\"host_process_recovery\":true," ++
            "\"power_loss_emulated\":false}\n",
    );
    try writer.flush();
    try waitForSupervisorKillV1();
    return error.SupervisorDidNotKillWorker;
}

fn emitResultV1(frame: ResultFrameV1) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":" ++
            "\"glacier.runtime-image-durable-recovery/result-v1\"," ++
            "\"mode\":\"{s}\",\"pid\":{d}," ++
            "\"target_name\":\"{s}\"," ++
            "\"disposition\":\"{s}\"," ++
            "\"source_fingerprint\":\"",
        .{
            frame.mode,
            currentProcessIdV1(),
            frame.target_name,
            frame.disposition,
        },
    );
    try writeDigestV1(
        writer,
        frame.identity.source_fingerprint,
    );
    try writer.writeAll("\",\"abi_fingerprint\":\"");
    try writeDigestV1(
        writer,
        frame.identity.abi_fingerprint,
    );
    try writer.print(
        "\",\"container_bytes\":{d}," ++
            "\"container_sha256\":\"",
        .{frame.identity.container_bytes},
    );
    try writeDigestV1(
        writer,
        frame.identity.container_sha256,
    );
    try writer.writeAll(
        "\",\"publication_plan_sha256\":",
    );
    if (frame.publication_plan_sha256) |digest| {
        try writer.writeByte('"');
        try writeDigestV1(writer, digest);
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"generated_records\":{d}," ++
            "\"generated_workspace_bytes_total\":{d}," ++
            "\"generated_workspace_bytes_peak\":{d}," ++
            "\"stale_candidate_removed\":{s}," ++
            "\"host_process_recovery\":true," ++
            "\"power_loss_emulated\":false," ++
            "\"verified\":true}}\n",
        .{
            frame.stats.generated_records,
            frame.stats.generated_workspace_bytes_total,
            frame.stats.generated_workspace_bytes_peak,
            booleanNameV1(frame.stale_candidate_removed),
        },
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

fn validateProtocolNameV1(name: []const u8) !void {
    if (name.len == 0 or
        name.len > protocol_name_max_bytes or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
        return error.InvalidProtocolName;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '.' and byte != '_' and byte != '-')
            return error.InvalidProtocolName;
    }
}

fn writeDigestV1(
    writer: *std.Io.Writer,
    digest: [32]u8,
) !void {
    const encoded = std.fmt.bytesToHex(digest, .lower);
    try writer.writeAll(&encoded);
}

fn booleanNameV1(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn currentProcessIdV1() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}
