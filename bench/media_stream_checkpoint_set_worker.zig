//! Fresh-process restore worker for an atomically selected multimodal set.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const media_set = core.media_stream_checkpoint_set;
const continuation = core.media_stream_continuation;
const resource_bank = core.resource_bank;
const media = core.media_contract;
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;
const transform = core.media_transform;

const challenge_sha256 = [_]u8{0x72} ** 32;
const maximum_set_bytes = 16 * 1024;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 3)
        return error.InvalidArguments;
    const storage_epoch = try std.fmt.parseInt(
        u64,
        arguments[2],
        10,
    );
    var directory = try std.fs.openDirAbsolute(
        arguments[1],
        .{},
    );
    defer directory.close();
    const source_pid_wire = try directory.readFileAlloc(
        allocator,
        "source.pid",
        32,
    );
    defer allocator.free(source_pid_wire);
    const source_pid = try std.fmt.parseInt(
        i32,
        source_pid_wire,
        10,
    );
    const target_pid = std.c.getpid();
    if (source_pid == target_pid)
        return error.ProcessDidNotRestart;
    var lock_storage: [1]u8 = undefined;
    var active_storage: [maximum_set_bytes]u8 =
        undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        challenge_sha256,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    defer lease.close();
    const selected = try media_set.decodeSetV1(
        lease.stream(),
    );

    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var next_output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 =
        undefined;
    var scratch: [1]u8 = undefined;
    var retained: [continuation.maximum_retained_outputs][]const u8 =
        undefined;
    var restored_outputs: u64 = 0;
    var resumed_chunks: u64 = 0;
    var next_chunk_index: u64 = 0;

    for (0..media_set.stream_count) |stream_index| {
        const context = try prepareContextV1(
            stream_index,
            &fixture_storage,
            &decode_plan_storage,
            &decoded_for_plan,
        );
        const checkpoint =
            selected.checkpoints[stream_index];
        for (
            retained[0..checkpoint.retained_output_count],
            0..,
        ) |*output, chunk_index| {
            output.* = try selected.retainedOutput(
                stream_index,
                chunk_index,
            );
        }

        var slots = [_]resource_bank.Slot{.{}} ** 4;
        var roots =
            [_]resource_bank.LeaseTreeRootSlot{.{}} ** 4;
        var nodes =
            [_]resource_bank.LeaseNodeSlot{.{}} ** 32;
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
            selected.archive.objects[stream_index].bytes,
            checkpoint.checkpoint_sha256,
        );
        const reserved = try bank.snapshotV3();
        if (reserved.reserved_unmaterialized_allocations !=
            checkpoint.retained_output_count or
            reserved.live_allocations != 0)
            return error.ChargeBeforeMaterializeMissing;
        try resumed.commitMaterializedV1(
            retained[0..checkpoint.retained_output_count],
        );
        restored_outputs +=
            checkpoint.retained_output_count;

        const chunk_index = std.math.cast(
            usize,
            checkpoint.visible_chunks,
        ) orelse return error.InvalidSelectedGeneration;
        const plan = try makeChunkPlanV1(
            context,
            stream_index,
            chunk_index,
        );
        const encoded_plan =
            try transform.encodeTransformPlanV1(
                plan,
                &plan_storage,
            );
        const target_end = try std.math.add(
            u64,
            state.visible_units,
            plan.logical_units,
        );
        var transaction =
            try resumed.stream.prepareChunk(
                state.visible_units,
                target_end,
                context.encoded_fixture,
                context.encoded_decode_plan,
                encoded_plan,
                &decoded,
                &next_output,
                &mappings,
                scratch[0..0],
            );
        const committed = try transaction.commit();
        if (committed.stream.stream_chunk_index !=
            checkpoint.visible_chunks or
            !std.mem.eql(
                u8,
                &committed.stream.previous_chunk_sha256,
                &checkpoint.last_chunk_sha256,
            ))
            return error.InvalidResumedPublication;
        next_chunk_index =
            committed.stream.stream_chunk_index;
        resumed_chunks += 1;
        try resumed.closeAndRelease();
        const final = try bank.snapshotV3();
        if (!final.used.isZero() or
            final.live_allocations != 0 or
            final.reserved_unmaterialized_allocations != 0 or
            final.active_lease_trees != 0)
            return error.TargetOwnershipLeak;
    }

    var stdout_buffer: [1536]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-stream-checkpoint-set/resume-v1\"," ++
            "\"source_pid\":{d},\"target_pid\":{d}," ++
            "\"process_restart\":true," ++
            "\"selected_generation\":{d}," ++
            "\"modalities\":3,\"restored_outputs\":{d}," ++
            "\"resumed_chunks\":{d},\"next_chunk_index\":{d}," ++
            "\"duplicate_publications\":0," ++
            "\"charge_before_materialize\":true," ++
            "\"final_bank_host_bytes\":0," ++
            "\"final_live_allocations\":0," ++
            "\"final_active_lease_trees\":0," ++
            "\"filesystem_authority\":true," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":false,\"verified\":true}}\n",
        .{
            source_pid,
            target_pid,
            selected.archive.metadata.generation,
            restored_outputs,
            resumed_chunks,
            next_chunk_index,
        },
    );
    try stdout.flush();
}

const Context = struct {
    encoded_fixture: []const u8,
    fixture: fixture_api.ParsedFixtureV1,
    encoded_decode_plan: []const u8,
    decode_receipt: fixture_api.DecodeReceiptV1,
};

fn prepareContextV1(
    stream_index: usize,
    fixture_storage: *[fixture_api.maximum_fixture_bytes]u8,
    decode_plan_storage: *[decode_plan.plan_bytes]u8,
    decoded_for_plan: *[fixture_api.maximum_payload_bytes]u8,
) !Context {
    const spec = switch (stream_index) {
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
    };
}

fn makeChunkPlanV1(
    context: Context,
    stream_index: usize,
    chunk_index: usize,
) !transform.TransformPlanV1 {
    return switch (stream_index) {
        0 => try transform.makeImagePlanV1(
            context.fixture,
            context.decode_receipt,
            0,
            chunk_index % 2,
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
            (chunk_index % 2) * 3,
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
                [_]u64{@intCast(chunk_index % 2)};
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
