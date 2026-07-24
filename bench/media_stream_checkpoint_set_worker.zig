//! Fresh-process restore worker for an atomically selected multimodal set.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const media_set = core.media_stream_checkpoint_set;
const processor = core.media_processor_state;
const processor_cache = core.media_processor_cache;
const continuation = core.media_stream_continuation;
const resource_bank = core.resource_bank;
const media = core.media_contract;
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;
const transform = core.media_transform;

const challenge_sha256 = [_]u8{0x72} ** 32;
const maximum_set_bytes = 16 * 1024;
const maximum_bundle_bytes = 4 * 1024;
const maximum_processor_cache_bytes = 4 * 1024;
const maximum_cache_payload_bytes = 1024;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len == 4) {
        if (!std.mem.eql(
            u8,
            arguments[3],
            "publish-successor",
        ))
            return error.InvalidArguments;
        return publishSuccessorV1(
            allocator,
            arguments[1],
            arguments[2],
        );
    }
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
        u32,
        source_pid_wire,
        10,
    );
    const target_pid = currentProcessId();
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
    const selected_materialized =
        try media_set.decodeMaterializedSetV1(
            lease.stream(),
        );
    const selected =
        selected_materialized.stateful_set.media_set;

    var cache_slots =
        [_]resource_bank.Slot{.{}} ** processor_cache.cache_count;
    var cache_roots =
        [_]resource_bank.LeaseTreeRootSlot{.{}} **
        processor_cache.cache_count;
    var cache_nodes =
        [_]resource_bank.LeaseNodeSlot{.{}} **
        (processor_cache.cache_count * 2);
    var cache_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &cache_slots,
            &cache_roots,
            &cache_nodes,
            .{},
            selected_materialized.processor_cache_bundle
                .restore_bank_epoch,
        );
    var cache_restore: processor_cache.RestoreSession = .{};
    try cache_restore.prepareV1(
        &cache_bank,
        selected_materialized.processor_cache_bundle,
        selected_materialized.processor_cache_bundle
            .bundle_sha256,
    );
    const cache_reserved = try cache_bank.snapshotV3();
    if (cache_reserved.reserved_unmaterialized_allocations !=
        processor_cache.cache_count or
        cache_reserved.live_allocations != 0)
        return error.CacheChargeBeforeMaterializeMissing;
    try cache_restore.commitMaterializedV1(
        selected_materialized.processor_cache_bundle.payloads,
    );
    const cache_active = try cache_bank.snapshotV3();
    if (cache_active.live_allocations !=
        processor_cache.cache_count or
        cache_active.used.activation_bytes !=
            selected_materialized.processor_cache_bundle
                .total_cache_bytes)
        return error.InvalidMaterializedCacheAccounting;

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
    try cache_restore.closeAndRelease();
    const cache_final = try cache_bank.snapshotV3();
    if (!cache_final.used.isZero() or
        cache_final.live_allocations != 0 or
        cache_final.active_lease_trees != 0)
        return error.CacheOwnershipLeak;

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
            "\"cache_charge_before_materialize\":true," ++
            "\"materialized_cache_bytes\":{d}," ++
            "\"cache_ownership_released\":true," ++
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
            selected_materialized.processor_cache_bundle
                .total_cache_bytes,
        },
    );
    try stdout.flush();
}

fn publishSuccessorV1(
    allocator: std.mem.Allocator,
    directory_path: []const u8,
    storage_epoch_text: []const u8,
) !void {
    const storage_epoch = try std.fmt.parseInt(
        u64,
        storage_epoch_text,
        10,
    );
    var directory = try std.fs.openDirAbsolute(
        directory_path,
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
        u32,
        source_pid_wire,
        10,
    );
    const target_pid = currentProcessId();
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
    const selected = try media_set.decodeMaterializedSetV1(
        lease.stream(),
    );
    const selected_media =
        selected.stateful_set.media_set;
    if (selected_media.archive.metadata.generation != 2)
        return error.InvalidSelectedGeneration;

    var cache_slots =
        [_]resource_bank.Slot{.{}} ** processor_cache.cache_count;
    var cache_roots =
        [_]resource_bank.LeaseTreeRootSlot{.{}} **
        processor_cache.cache_count;
    var cache_nodes =
        [_]resource_bank.LeaseNodeSlot{.{}} **
        (processor_cache.cache_count * 2);
    var cache_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &cache_slots,
            &cache_roots,
            &cache_nodes,
            .{},
            selected.processor_cache_bundle
                .restore_bank_epoch,
        );
    var cache_restore: processor_cache.RestoreSession = .{};
    try cache_restore.prepareV1(
        &cache_bank,
        selected.processor_cache_bundle,
        selected.processor_cache_bundle.bundle_sha256,
    );
    const cache_reserved = try cache_bank.snapshotV3();
    if (cache_reserved.reserved_unmaterialized_allocations !=
        processor_cache.cache_count or
        cache_reserved.live_allocations != 0)
        return error.CacheChargeBeforeMaterializeMissing;
    try cache_restore.commitMaterializedV1(
        selected.processor_cache_bundle.payloads,
    );
    const restored_cache_bytes =
        selected.processor_cache_bundle.total_cache_bytes;

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
    var new_outputs: [media_set.stream_count][fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var new_output_lengths: [media_set.stream_count]usize = undefined;
    var mappings: [4]transform.TransformMappingV1 =
        undefined;
    var scratch: [1]u8 = undefined;
    var restored: [continuation.maximum_retained_outputs][]const u8 =
        undefined;
    var output_views: [media_set.stream_count][continuation.maximum_retained_outputs][]const u8 =
        undefined;
    var checkpoints: [media_set.stream_count]continuation.CheckpointV1 =
        undefined;
    var inputs: [media_set.stream_count]media_set.StreamInputV1 =
        undefined;
    var rebound_outputs: u64 = 0;

    for (0..media_set.stream_count) |stream_index| {
        const context = try prepareContextV1(
            stream_index,
            &fixture_storage,
            &decode_plan_storage,
            &decoded_for_plan,
        );
        const prior = selected_media.checkpoints[stream_index];
        for (
            restored[0..prior.retained_output_count],
            0..,
        ) |*output, chunk_index| {
            output.* = try selected_media.retainedOutput(
                stream_index,
                chunk_index,
            );
            output_views[stream_index][chunk_index] =
                output.*;
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
                prior.restore_bank_epoch,
            );
        var state: media.PublicationStateV1 = undefined;
        var resumed: continuation.ResumeSession = .{};
        try resumed.prepareV1(
            &bank,
            &state,
            selected_media.archive.objects[stream_index].bytes,
            prior.checkpoint_sha256,
        );
        const reserved = try bank.snapshotV3();
        if (reserved.reserved_unmaterialized_allocations !=
            prior.retained_output_count or
            reserved.live_allocations != 0)
            return error.ChargeBeforeMaterializeMissing;
        try resumed.commitMaterializedV1(
            restored[0..prior.retained_output_count],
        );
        rebound_outputs += prior.retained_output_count;

        const chunk_index = std.math.cast(
            usize,
            prior.visible_chunks,
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
                &new_outputs[stream_index],
                &mappings,
                scratch[0..0],
            );
        const committed = try transaction.commit();
        if (committed.stream.stream_chunk_index !=
            prior.visible_chunks or
            !std.mem.eql(
                u8,
                &committed.stream.previous_chunk_sha256,
                &prior.last_chunk_sha256,
            ))
            return error.InvalidResumedPublication;
        new_output_lengths[stream_index] =
            @intCast(plan.output_bytes);
        output_views[stream_index][prior.retained_output_count] =
            new_outputs[stream_index][0..new_output_lengths[stream_index]];
        const successor_count =
            prior.retained_output_count + 1;
        checkpoints[stream_index] =
            try resumed.makeSuccessorCheckpointV1(
                prior.kind,
                successorCheckpointPlanV1(
                    stream_index,
                    prior,
                ),
                output_views[stream_index][0..successor_count],
            );
        inputs[stream_index] = .{
            .checkpoint = checkpoints[stream_index],
            .retained_outputs = output_views[stream_index][0..successor_count],
        };
        try resumed.closeAndRelease();
        const final = try bank.snapshotV3();
        if (!final.used.isZero() or
            final.live_allocations != 0 or
            final.reserved_unmaterialized_allocations != 0 or
            final.active_lease_trees != 0)
            return error.TargetOwnershipLeak;
    }
    try cache_restore.closeAndRelease();
    const cache_final = try cache_bank.snapshotV3();
    if (!cache_final.used.isZero() or
        cache_final.live_allocations != 0 or
        cache_final.active_lease_trees != 0)
        return error.CacheOwnershipLeak;

    var bundle_storage: [maximum_bundle_bytes]u8 =
        undefined;
    var processor_storage: [processor.processor_bundle_bytes]u8 = undefined;
    var cache_payload_storage: [processor.processor_count][maximum_cache_payload_bytes]u8 =
        undefined;
    const cache_payloads = try makeCachePayloadsV1(
        &cache_payload_storage,
        3,
    );
    var processor_cache_storage: [maximum_processor_cache_bytes]u8 = undefined;
    var set_storage: [maximum_set_bytes]u8 = undefined;
    const processor_snapshot = try makeProcessorSnapshotV1(
        checkpoints,
        3,
        &selected.stateful_set.processor_bundle,
        cache_payloads,
    );
    const processor_prepared = try processor.encodeBundleV1(
        processor_snapshot.states,
        processor_snapshot.sync,
        &processor_storage,
    );
    const successor = try media_set.encodeMaterializedSetV1(
        inputs,
        processor_snapshot.states,
        processor_snapshot.sync,
        cachePlanV1(
            3,
            processor_prepared.bundle_sha256,
            selected.processor_cache_bundle.bundle_sha256,
            selected.processor_cache_bundle
                .restore_bank_epoch,
            23_000,
        ),
        cache_payloads,
        selected_media.archive.checkpoint_sha256,
        &bundle_storage,
        &processor_storage,
        &processor_cache_storage,
        &set_storage,
    );
    const decoded_successor = try media_set.decodeMaterializedSetV1(
        successor.archive.bytes,
    );
    try media_set.validateRestoredMaterializedSuccessorV1(
        &selected,
        &decoded_successor,
    );
    const prepared =
        try checkpoint_file.preparePublicationV1(
            &lease,
            successor.archive,
        );
    const applied = try checkpoint_file.publishV1(
        &lease,
        prepared,
    );
    if (applied.disposition != .applied)
        return error.SuccessorNotPublished;

    const archive_hex = std.fmt.bytesToHex(
        successor.archive.checkpoint_sha256,
        .lower,
    );
    const processor_hex = std.fmt.bytesToHex(
        successor.processor_bundle_sha256,
        .lower,
    );
    const cache_hex = std.fmt.bytesToHex(
        successor.processor_cache_bundle_sha256,
        .lower,
    );
    var stdout_buffer: [1536]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-stream-checkpoint-set/" ++
            "post-restore-successor-v1\"," ++
            "\"source_pid\":{d},\"target_pid\":{d}," ++
            "\"process_restart\":true," ++
            "\"previous_generation\":2," ++
            "\"published_generation\":3," ++
            "\"modalities\":3,\"rebound_outputs\":{d}," ++
            "\"new_chunks\":3,\"retained_outputs\":9," ++
            "\"stale_source_authority\":false," ++
            "\"charge_before_materialize\":true," ++
            "\"cache_charge_before_materialize\":true," ++
            "\"restored_cache_bytes\":{d}," ++
            "\"processor_state_rebound\":true," ++
            "\"processor_cache_rebound\":true," ++
            "\"atomic_publication\":true," ++
            "\"ownership_released\":true," ++
            "\"archive_sha256\":\"{s}\"," ++
            "\"processor_bundle_sha256\":\"{s}\"," ++
            "\"processor_cache_bundle_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            source_pid,
            target_pid,
            rebound_outputs,
            restored_cache_bytes,
            &archive_hex,
            &processor_hex,
            &cache_hex,
        },
    );
    try stdout.flush();
}

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

fn successorCheckpointPlanV1(
    stream_index: usize,
    prior: continuation.CheckpointV1,
) continuation.CheckpointPlanV1 {
    const stream_base: u64 =
        15_000 + stream_index * 100;
    return .{
        .checkpoint_generation = prior.checkpoint_generation + 1,
        .chunk_limit = @intCast(prior.chunk_limit),
        .restore_bank_epoch = stream_base,
        .restore_owner_key_base = stream_base + 10,
        .restore_tree_key_base = stream_base + 20,
        .restore_authority_key_base = stream_base + 30,
        .next_owner_key_base = stream_base + 40,
        .next_tree_key_base = stream_base + 50,
        .next_authority_key_base = stream_base + 60,
        .tenant_key = prior.tenant_key,
        .challenge_sha256 = prior.challenge_sha256,
        .previous_checkpoint_sha256 = prior.checkpoint_sha256,
    };
}

fn makeCachePayloadsV1(
    storage: *[processor.processor_count][maximum_cache_payload_bytes]u8,
    generation: u64,
) ![processor.processor_count][]const u8 {
    const lengths = [_]u64{
        try std.math.mul(u64, generation, 24),
        try std.math.add(
            u64,
            480,
            try std.math.mul(u64, generation, 160),
        ),
        try std.math.mul(u64, @min(generation, 2), 128),
    };
    var payloads: [processor.processor_count][]const u8 =
        undefined;
    for (lengths, 0..) |length, index| {
        const payload_length = std.math.cast(
            usize,
            length,
        ) orelse return error.InvalidCachePayload;
        if (payload_length > maximum_cache_payload_bytes)
            return error.InvalidCachePayload;
        @memset(
            storage[index][0..payload_length],
            @intCast(0x20 + index * 0x10 + generation),
        );
        payloads[index] = storage[index][0..payload_length];
    }
    return payloads;
}

fn cachePlanV1(
    generation: u64,
    processor_bundle_sha256: [32]u8,
    previous_cache_bundle_sha256: [32]u8,
    source_bank_epoch: u64,
    restore_bank_epoch: u64,
) processor_cache.BundlePlanV1 {
    return .{
        .processor_bundle_sha256 = processor_bundle_sha256,
        .previous_cache_bundle_sha256 = previous_cache_bundle_sha256,
        .source_bank_epoch = source_bank_epoch,
        .restore_bank_epoch = restore_bank_epoch,
        .restore_owner_key_base = restore_bank_epoch + 100,
        .restore_tree_key_base = restore_bank_epoch + 200,
        .restore_authority_key_base = restore_bank_epoch + 300,
        .tenant_key = 21_400,
        .publication_next_sequence = generation + 1,
    };
}

fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        bytes,
        &digest,
        .{},
    );
    return digest;
}

const ProcessorSnapshotV1 = struct {
    states: [processor.processor_count]processor.ProcessorStateV1,
    sync: processor.SyncStateV1,
};

fn makeProcessorSnapshotV1(
    checkpoints: [media_set.stream_count]continuation.CheckpointV1,
    generation: u64,
    previous: *const processor.DecodedBundleV1,
    cache_payloads: [processor.processor_count][]const u8,
) !ProcessorSnapshotV1 {
    var plans: [processor.processor_count]processor.StatePlanV1 =
        undefined;
    for (&plans, 0..) |*plan, index| {
        const checkpoint = checkpoints[index];
        const timeline_base: media.TimeBaseV1 = switch (index) {
            0 => .{ .numerator = 0, .denominator = 1 },
            1 => .{ .numerator = 1, .denominator = 48_000 },
            2 => .{ .numerator = 1, .denominator = 120 },
            else => unreachable,
        };
        plan.* = .{
            .kind = checkpoint.kind,
            .request_epoch = checkpoint.request_epoch,
            .generation = generation,
            .stream_key = checkpoint.stream_key,
            .timeline_base = timeline_base,
            .media_object_sha256 = checkpoint.media_object_sha256,
            .processor_plan_sha256 = [_]u8{@intCast(0x31 + index)} ** 32,
            .previous_state_sha256 = previous.states[index].state_sha256,
            .challenge_sha256 = checkpoint.challenge_sha256,
            .cache_content_sha256 = sha256(
                cache_payloads[index],
            ),
            .output_chain_sha256 = checkpoint.last_chunk_sha256,
            .ownership_receipt_sha256 = checkpoint.retained_manifest_sha256,
            .decoder_state_sha256 = [_]u8{@intCast(0x41 + index)} ** 32,
        };
    }
    const window_start = generation -| 2;
    const states = [_]processor.ProcessorStateV1{
        try processor.makeImageStateV1(
            plans[0],
            generation,
            4,
            4,
            4,
            2,
            2,
            3,
        ),
        try processor.makeAudioStateV1(
            plans[1],
            generation,
            48_000,
            1,
            400,
            160,
            80,
            2,
        ),
        try processor.makeVideoStateV1(
            plans[2],
            2,
            128,
            window_start,
            generation,
            window_start,
        ),
    };
    const sync = try processor.makeSyncStateV1(
        states,
        .{
            .generation = generation,
            .request_epoch = checkpoints[0].request_epoch,
            .master_ticks_per_second = 48_000,
            .maximum_skew_ticks = 800,
            .challenge_sha256 = checkpoints[0].challenge_sha256,
            .sync_policy_sha256 = [_]u8{0x6d} ** 32,
            .previous_sync_sha256 = previous.sync.sync_sha256,
        },
    );
    return .{ .states = states, .sync = sync };
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
