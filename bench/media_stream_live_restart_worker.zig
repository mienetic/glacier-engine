//! Two-process media stream checkpoint worker used by the native demo.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const media = core.media_contract;
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;
const transform = core.media_transform;
const stream_runtime = core.media_stream_runtime;
const continuation = core.media_stream_continuation;

const checkpoint_names = [_][]const u8{
    "image.stream-checkpoint",
    "audio.stream-checkpoint",
    "video.stream-checkpoint",
};
const output_names = [_][]const u8{
    "image.retained-output",
    "audio.retained-output",
    "video.retained-output",
};
const source_pid_name = "media-stream-source.pid";

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 3)
        return error.InvalidArguments;
    var directory = try std.fs.openDirAbsolute(
        arguments[2],
        .{},
    );
    defer directory.close();
    if (std.mem.eql(u8, arguments[1], "checkpoint")) {
        try checkpointAllV1(&directory);
    } else if (std.mem.eql(u8, arguments[1], "resume")) {
        try resumeAllV1(&directory);
    } else {
        return error.InvalidPhase;
    }
}

fn checkpointAllV1(directory: *std.fs.Dir) !void {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 =
        undefined;
    var plan_storage: [transform.transform_plan_bytes]u8 =
        undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var mappings: [4]transform.TransformMappingV1 =
        undefined;
    var scratch: [1]u8 = undefined;
    var checkpoint_storage: [continuation.checkpoint_bytes]u8 =
        undefined;

    for (0..3) |case_index| {
        const context = try prepareContextV1(
            case_index,
            &fixture_storage,
            &decode_plan_storage,
            &decoded_for_plan,
        );
        var slots = [_]resource_bank.Slot{.{}};
        var roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
        var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
        const source_bank_epoch: u64 =
            9100 + case_index;
        var bank =
            try resource_bank.Bank.initWithLeaseTreeStorage(
                &slots,
                &roots,
                &nodes,
                .{},
                source_bank_epoch,
            );
        const request_epoch: u64 = 9200 + case_index;
        var state = try media.initializePublicationStateV1(
            request_epoch,
            1,
            context.timeline_base,
            context.fixture.media_object_sha256,
            [_]u8{@intCast(0xa0 + case_index)} ** 32,
        );
        var stream: stream_runtime.StreamSession = .{};
        try stream.init(
            &bank,
            &state,
            9300 + case_index,
            9310 + case_index * 10,
            9320 + case_index * 10,
            9330 + case_index * 10,
            9340 + case_index,
            request_epoch,
            2,
        );
        const plan = try makeChunkPlanV1(
            context,
            case_index,
            0,
        );
        const encoded_plan =
            try transform.encodeTransformPlanV1(
                plan,
                &plan_storage,
            );
        var transaction = try stream.prepareChunk(
            0,
            plan.logical_units,
            context.encoded_fixture,
            context.encoded_decode_plan,
            encoded_plan,
            &decoded,
            &output,
            &mappings,
            scratch[0..0],
        );
        const committed = try transaction.commit();
        const exact_output =
            output[0..@intCast(plan.output_bytes)];
        const retained = [_][]const u8{exact_output};
        const checkpoint =
            try continuation.makeCheckpointV1(
                &stream,
                committed.execution.kind,
                .{
                    .checkpoint_generation = 1,
                    .chunk_limit = 2,
                    .restore_bank_epoch = 9400 + case_index,
                    .restore_owner_key_base = 9410 + case_index * 10,
                    .restore_tree_key_base = 9420 + case_index * 10,
                    .restore_authority_key_base = 9430 + case_index * 10,
                    .next_owner_key_base = 9440 + case_index * 10,
                    .next_tree_key_base = 9450 + case_index * 10,
                    .next_authority_key_base = 9460 + case_index * 10,
                    .tenant_key = 9470 + case_index,
                    .challenge_sha256 = [_]u8{@intCast(
                        0xc0 + case_index,
                    )} ** 32,
                },
                &retained,
            );
        const encoded_checkpoint =
            try continuation.encodeCheckpointV1(
                checkpoint,
                &checkpoint_storage,
            );
        try writeSyncedV1(
            directory,
            checkpoint_names[case_index],
            encoded_checkpoint,
        );
        try writeSyncedV1(
            directory,
            output_names[case_index],
            exact_output,
        );
        try stream.closeAndRelease();
        if (!(try bank.snapshot()).used.isZero())
            return error.SourceOwnershipLeak;
    }
    var pid_storage: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(
        &pid_storage,
        "{d}",
        .{std.c.getpid()},
    );
    try writeSyncedV1(
        directory,
        source_pid_name,
        pid,
    );
    try std.posix.fsync(directory.fd);

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-stream-live-restart/demo-v1\"," ++
            "\"phase\":\"checkpoint\",\"source_pid\":{d}," ++
            "\"portable_checkpoints\":3," ++
            "\"source_ownership_releases\":3," ++
            "\"file_sync\":true,\"directory_sync\":true," ++
            "\"verified\":true}}\n",
        .{std.c.getpid()},
    );
    try stdout.flush();
}

fn resumeAllV1(directory: *std.fs.Dir) !void {
    var pid_storage: [32]u8 = undefined;
    const pid_wire = try readBoundedV1(
        directory,
        source_pid_name,
        &pid_storage,
    );
    const source_pid = try std.fmt.parseInt(
        i32,
        pid_wire,
        10,
    );
    const target_pid = std.c.getpid();
    if (source_pid == target_pid)
        return error.ProcessDidNotRestart;

    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 =
        undefined;
    var plan_storage: [transform.transform_plan_bytes]u8 =
        undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var next_output: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var retained_output: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var mappings: [4]transform.TransformMappingV1 =
        undefined;
    var scratch: [1]u8 = undefined;
    var checkpoint_storage: [continuation.checkpoint_bytes]u8 =
        undefined;
    var tail_roots: [3]continuation.Digest = undefined;
    var restored_outputs: u64 = 0;
    var resumed_chunks: u64 = 0;

    for (0..3) |case_index| {
        const context = try prepareContextV1(
            case_index,
            &fixture_storage,
            &decode_plan_storage,
            &decoded_for_plan,
        );
        const checkpoint_wire = try readExactV1(
            directory,
            checkpoint_names[case_index],
            &checkpoint_storage,
        );
        const checkpoint =
            try continuation.decodeCheckpointV1(
                checkpoint_wire,
            );
        const exact_retained = try readBoundedV1(
            directory,
            output_names[case_index],
            &retained_output,
        );
        const retained = [_][]const u8{exact_retained};
        var slots = [_]resource_bank.Slot{.{}} ** 2;
        var roots =
            [_]resource_bank.LeaseTreeRootSlot{.{}} ** 2;
        var nodes =
            [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
        var bank =
            try resource_bank.Bank.initWithLeaseTreeStorage(
                &slots,
                &roots,
                &nodes,
                .{},
                checkpoint.restore_bank_epoch,
            );
        var state: media.PublicationStateV1 = undefined;
        var resumed: continuation.ResumeSession = .{};
        try resumed.prepareV1(
            &bank,
            &state,
            checkpoint_wire,
            checkpoint.checkpoint_sha256,
        );
        const reserved = try bank.snapshotV3();
        if (reserved.reserved_unmaterialized_allocations !=
            1 or reserved.live_allocations != 0)
            return error.ChargeBeforeMaterializeMissing;
        try resumed.commitMaterializedV1(&retained);
        restored_outputs += 1;

        const second_plan = try makeChunkPlanV1(
            context,
            case_index,
            1,
        );
        const second_encoded =
            try transform.encodeTransformPlanV1(
                second_plan,
                &plan_storage,
            );
        var transaction =
            try resumed.stream.prepareChunk(
                state.visible_units,
                state.visible_units +
                    second_plan.logical_units,
                context.encoded_fixture,
                context.encoded_decode_plan,
                second_encoded,
                &decoded,
                &next_output,
                &mappings,
                scratch[0..0],
            );
        const committed = try transaction.commit();
        if (committed.stream.stream_chunk_index != 1 or
            !std.mem.eql(
                u8,
                &committed.stream.previous_chunk_sha256,
                &checkpoint.last_chunk_sha256,
            ) or state.visible_chunks != 2)
            return error.InvalidResumedPublication;
        tail_roots[case_index] =
            committed.stream.receipt_sha256;
        resumed_chunks += 1;
        try resumed.closeAndRelease();
        const final = try bank.snapshotV3();
        if (!final.used.isZero() or
            final.live_allocations != 0 or
            final.active_lease_trees != 0)
            return error.TargetOwnershipLeak;
    }

    const image_tail_hex = std.fmt.bytesToHex(
        tail_roots[0],
        .lower,
    );
    const audio_tail_hex = std.fmt.bytesToHex(
        tail_roots[1],
        .lower,
    );
    const video_tail_hex = std.fmt.bytesToHex(
        tail_roots[2],
        .lower,
    );
    var stdout_buffer: [1536]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-stream-live-restart/demo-v1\"," ++
            "\"phase\":\"resume\",\"source_pid\":{d}," ++
            "\"target_pid\":{d},\"process_restart\":true," ++
            "\"modalities\":3,\"checkpoint_bytes\":{d}," ++
            "\"restored_outputs\":{d}," ++
            "\"resumed_chunks\":{d}," ++
            "\"duplicate_publications\":0," ++
            "\"charge_before_materialize\":true," ++
            "\"file_sync\":true,\"directory_sync\":true," ++
            "\"final_bank_host_bytes\":0," ++
            "\"final_live_allocations\":0," ++
            "\"final_active_lease_trees\":0," ++
            "\"filesystem_authority\":true," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":false," ++
            "\"crash_atomic_checkpoint_set\":false," ++
            "\"verified\":true," ++
            "\"image_tail_sha256\":\"{s}\"," ++
            "\"audio_tail_sha256\":\"{s}\"," ++
            "\"video_tail_sha256\":\"{s}\"}}\n",
        .{
            source_pid,
            target_pid,
            continuation.checkpoint_bytes,
            restored_outputs,
            resumed_chunks,
            &image_tail_hex,
            &audio_tail_hex,
            &video_tail_hex,
        },
    );
    try stdout.flush();
}

const Context = struct {
    encoded_fixture: []const u8,
    fixture: fixture_api.ParsedFixtureV1,
    encoded_decode_plan: []const u8,
    decode_receipt: fixture_api.DecodeReceiptV1,
    timeline_base: media.TimeBaseV1,
};

fn prepareContextV1(
    case_index: usize,
    fixture_storage: *[fixture_api.maximum_fixture_bytes]u8,
    decode_plan_storage: *[decode_plan.plan_bytes]u8,
    decoded_for_plan: *[fixture_api.maximum_payload_bytes]u8,
) !Context {
    const spec = switch (case_index) {
        0 => fixture_api.imageSpecV1(),
        1 => fixture_api.audioSpecV1(),
        2 => fixture_api.videoSpecV1(),
        else => unreachable,
    };
    const encoded_fixture =
        try fixture_api.encodeFixtureV1(
            spec,
            fixture_storage,
        );
    const fixture = try fixture_api.parseFixtureV1(
        encoded_fixture,
    );
    const fixture_plan =
        try fixture_api.makeDecodePlanV1(
            fixture,
            [_]u8{0xd1} ** 32,
            [_]u8{0xe1} ** 32,
        );
    const encoded_decode_plan =
        try decode_plan.encodePlanV1(
            fixture_plan,
            decode_plan_storage,
        );
    const decode_receipt =
        try fixture_api.decodeFixtureV1(
            encoded_fixture,
            encoded_decode_plan,
            decoded_for_plan,
        );
    return .{
        .encoded_fixture = encoded_fixture,
        .fixture = fixture,
        .encoded_decode_plan = encoded_decode_plan,
        .decode_receipt = decode_receipt,
        .timeline_base = switch (case_index) {
            0 => .{ .numerator = 1, .denominator = 1 },
            1 => .{
                .numerator = 1,
                .denominator = 16_000,
            },
            2 => fixture.time_base,
            else => unreachable,
        },
    };
}

fn makeChunkPlanV1(
    context: Context,
    case_index: usize,
    chunk_index: usize,
) !transform.TransformPlanV1 {
    return switch (case_index) {
        0 => try transform.makeImagePlanV1(
            context.fixture,
            context.decode_receipt,
            0,
            chunk_index,
            2,
            1,
            2,
            1,
            1,
            1,
            [_]u8{0xf1} ** 32,
            [_]u8{0xf2} ** 32,
        ),
        1 => try transform.makeAudioPlanV1(
            context.fixture,
            context.decode_receipt,
            chunk_index * 3,
            3,
            16_000,
            1,
            0,
            1,
            [_]u8{0xf1} ** 32,
            [_]u8{0xf2} ** 32,
        ),
        2 => blk: {
            const selected =
                [_]u64{@intCast(chunk_index)};
            break :blk try transform.makeVideoPlanV1(
                context.fixture,
                context.decode_receipt,
                &selected,
                [_]u8{0xf1} ** 32,
                [_]u8{0xf2} ** 32,
            );
        },
        else => unreachable,
    };
}

fn writeSyncedV1(
    directory: *std.fs.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    var file = try directory.createFile(name, .{
        .read = true,
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

fn readExactV1(
    directory: *std.fs.Dir,
    name: []const u8,
    storage: *[continuation.checkpoint_bytes]u8,
) ![]const u8 {
    const bytes = try readBoundedV1(
        directory,
        name,
        storage,
    );
    if (bytes.len != storage.len)
        return error.InvalidFileLength;
    return bytes;
}

fn readBoundedV1(
    directory: *std.fs.Dir,
    name: []const u8,
    storage: []u8,
) ![]const u8 {
    var file = try directory.openFile(name, .{});
    defer file.close();
    const stat = try file.stat();
    const length = std.math.cast(
        usize,
        stat.size,
    ) orelse return error.InvalidFileLength;
    if (length == 0 or length > storage.len)
        return error.InvalidFileLength;
    const read = try file.readAll(storage[0..length]);
    if (read != length)
        return error.ShortRead;
    return storage[0..length];
}
