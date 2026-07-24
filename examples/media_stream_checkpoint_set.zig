//! Crash-atomic, repeated-generation image/audio/video checkpoint campaign.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const resource_bank = core.resource_bank;
const media = core.media_contract;
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;
const transform = core.media_transform;
const stream_runtime = core.media_stream_runtime;
const continuation = core.media_stream_continuation;
const media_set = core.media_stream_checkpoint_set;
const processor = core.media_processor_state;
const processor_cache = core.media_processor_cache;
const checkpoint_file = core.continuation_checkpoint_file;

const challenge_sha256 = [_]u8{0x72} ** 32;
const request_epoch: u64 = 12_000;
const maximum_set_bytes = 16 * 1024;
const maximum_bundle_bytes = 4 * 1024;
const maximum_processor_cache_bytes = 4 * 1024;
const maximum_cache_payload_bytes = 1024;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 3)
        return error.MissingWorkerPath;
    const crash_worker = arguments[1];
    const resume_worker = arguments[2];

    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var output_storage: [media_set.stream_count][2][fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var output_lengths: [media_set.stream_count][2]usize =
        undefined;
    var mappings: [4]transform.TransformMappingV1 =
        undefined;
    var scratch: [1]u8 = undefined;
    var first_checkpoints: [media_set.stream_count]continuation.CheckpointV1 =
        undefined;
    var second_checkpoints: [media_set.stream_count]continuation.CheckpointV1 =
        undefined;
    var source_releases: u64 = 0;

    for (0..media_set.stream_count) |stream_index| {
        const context = try prepareContextV1(
            stream_index,
            &fixture_storage,
            &decode_plan_storage,
            &decoded_for_plan,
        );
        var slots = [_]resource_bank.Slot{.{}} ** 2;
        var roots =
            [_]resource_bank.LeaseTreeRootSlot{.{}} ** 2;
        var nodes =
            [_]resource_bank.LeaseNodeSlot{.{}} ** 16;
        var bank =
            try resource_bank.Bank.initWithLeaseTreeStorage(
                &slots,
                &roots,
                &nodes,
                .{},
                12_100 + stream_index,
            );
        var state = try media.initializePublicationStateV1(
            request_epoch,
            1,
            context.timeline_base,
            context.fixture.media_object_sha256,
            [_]u8{@intCast(0xa0 + stream_index)} ** 32,
        );
        var stream: stream_runtime.StreamSession = .{};
        try stream.init(
            &bank,
            &state,
            12_200 + stream_index,
            12_300 + stream_index * 100,
            12_310 + stream_index * 100,
            12_320 + stream_index * 100,
            12_330 + stream_index,
            request_epoch,
            4,
        );

        for (0..2) |chunk_index| {
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
            const target_start = state.visible_units;
            const target_end = try std.math.add(
                u64,
                target_start,
                plan.logical_units,
            );
            var transaction = try stream.prepareChunk(
                target_start,
                target_end,
                context.encoded_fixture,
                context.encoded_decode_plan,
                encoded_plan,
                &decoded,
                &output_storage[stream_index][chunk_index],
                &mappings,
                scratch[0..0],
            );
            const committed = try transaction.commit();
            output_lengths[stream_index][chunk_index] =
                @intCast(plan.output_bytes);
            if (chunk_index == 0) {
                const retained = [_][]const u8{
                    output_storage[stream_index][0][0..output_lengths[stream_index][0]],
                };
                first_checkpoints[stream_index] =
                    try continuation.makeCheckpointV1(
                        &stream,
                        committed.execution.kind,
                        checkpointPlanV1(
                            stream_index,
                            1,
                            [_]u8{0} ** 32,
                        ),
                        &retained,
                    );
            } else {
                const retained = [_][]const u8{
                    output_storage[stream_index][0][0..output_lengths[stream_index][0]],
                    output_storage[stream_index][1][0..output_lengths[stream_index][1]],
                };
                second_checkpoints[stream_index] =
                    try continuation.makeCheckpointV1(
                        &stream,
                        committed.execution.kind,
                        checkpointPlanV1(
                            stream_index,
                            2,
                            first_checkpoints[stream_index]
                                .checkpoint_sha256,
                        ),
                        &retained,
                    );
            }
        }
        try stream.closeAndRelease();
        const final = try bank.snapshotV3();
        if (!final.used.isZero() or
            final.live_allocations != 0 or
            final.active_lease_trees != 0)
            return error.SourceOwnershipLeak;
        source_releases += 1;
    }

    var first_output_views: [media_set.stream_count][1][]const u8 =
        undefined;
    var second_output_views: [media_set.stream_count][2][]const u8 =
        undefined;
    var first_inputs: [media_set.stream_count]media_set.StreamInputV1 =
        undefined;
    var second_inputs: [media_set.stream_count]media_set.StreamInputV1 =
        undefined;
    for (0..media_set.stream_count) |stream_index| {
        first_output_views[stream_index][0] =
            output_storage[stream_index][0][0..output_lengths[stream_index][0]];
        second_output_views[stream_index][0] =
            first_output_views[stream_index][0];
        second_output_views[stream_index][1] =
            output_storage[stream_index][1][0..output_lengths[stream_index][1]];
        first_inputs[stream_index] = .{
            .checkpoint = first_checkpoints[stream_index],
            .retained_outputs = &first_output_views[stream_index],
        };
        second_inputs[stream_index] = .{
            .checkpoint = second_checkpoints[stream_index],
            .retained_outputs = &second_output_views[stream_index],
        };
    }
    var first_bundle_storage: [maximum_bundle_bytes]u8 = undefined;
    var second_bundle_storage: [maximum_bundle_bytes]u8 = undefined;
    var first_processor_storage: [processor.processor_bundle_bytes]u8 = undefined;
    var second_processor_storage: [processor.processor_bundle_bytes]u8 = undefined;
    var first_cache_payload_storage: [processor.processor_count][maximum_cache_payload_bytes]u8 =
        undefined;
    var second_cache_payload_storage: [processor.processor_count][maximum_cache_payload_bytes]u8 =
        undefined;
    const first_cache_payloads = try makeCachePayloadsV1(
        &first_cache_payload_storage,
        1,
    );
    const second_cache_payloads = try makeCachePayloadsV1(
        &second_cache_payload_storage,
        2,
    );
    var first_processor_cache_storage: [maximum_processor_cache_bytes]u8 = undefined;
    var second_processor_cache_storage: [maximum_processor_cache_bytes]u8 = undefined;
    var first_set_storage: [maximum_set_bytes]u8 = undefined;
    var second_set_storage: [maximum_set_bytes]u8 = undefined;
    const first_processor = try makeProcessorSnapshotV1(
        first_checkpoints,
        1,
        null,
        first_cache_payloads,
    );
    const first_processor_prepared =
        try processor.encodeBundleV1(
            first_processor.states,
            first_processor.sync,
            &first_processor_storage,
        );
    const first_set = try media_set.encodeMaterializedSetV1(
        first_inputs,
        first_processor.states,
        first_processor.sync,
        cachePlanV1(
            1,
            first_processor_prepared.bundle_sha256,
            [_]u8{0} ** 32,
            20_000,
            21_000,
        ),
        first_cache_payloads,
        [_]u8{0} ** 32,
        &first_bundle_storage,
        &first_processor_storage,
        &first_processor_cache_storage,
        &first_set_storage,
    );
    const first_decoded = try media_set.decodeMaterializedSetV1(
        first_set.archive.bytes,
    );
    const second_processor = try makeProcessorSnapshotV1(
        second_checkpoints,
        2,
        &first_decoded.stateful_set.processor_bundle,
        second_cache_payloads,
    );
    const second_processor_prepared =
        try processor.encodeBundleV1(
            second_processor.states,
            second_processor.sync,
            &second_processor_storage,
        );
    const second_set = try media_set.encodeMaterializedSetV1(
        second_inputs,
        second_processor.states,
        second_processor.sync,
        cachePlanV1(
            2,
            second_processor_prepared.bundle_sha256,
            first_decoded.processor_cache_bundle
                .bundle_sha256,
            21_000,
            22_000,
        ),
        second_cache_payloads,
        first_set.archive.checkpoint_sha256,
        &second_bundle_storage,
        &second_processor_storage,
        &second_processor_cache_storage,
        &second_set_storage,
    );
    const second_decoded = try media_set.decodeMaterializedSetV1(
        second_set.archive.bytes,
    );
    try media_set.validateMaterializedSuccessorV1(
        &first_decoded,
        &second_decoded,
    );
    var foreign_bundle_storage: [maximum_bundle_bytes]u8 = undefined;
    var foreign_processor_storage: [processor.processor_bundle_bytes]u8 = undefined;
    var foreign_processor_cache_storage: [maximum_processor_cache_bytes]u8 = undefined;
    var foreign_set_storage: [maximum_set_bytes]u8 = undefined;
    const foreign_set = try media_set.encodeMaterializedSetV1(
        second_inputs,
        second_processor.states,
        second_processor.sync,
        cachePlanV1(
            2,
            second_processor_prepared.bundle_sha256,
            first_decoded.processor_cache_bundle
                .bundle_sha256,
            21_000,
            22_000,
        ),
        second_cache_payloads,
        [_]u8{0xee} ** 32,
        &foreign_bundle_storage,
        &foreign_processor_storage,
        &foreign_processor_cache_storage,
        &foreign_set_storage,
    );
    const foreign_decoded = try media_set.decodeMaterializedSetV1(
        foreign_set.archive.bytes,
    );
    try std.testing.expectError(
        media_set.Error.InvalidSuccessor,
        media_set.validateMaterializedSuccessorV1(
            &first_decoded,
            &foreign_decoded,
        ),
    );

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var process_deaths: u64 = 0;
    var selected_previous: u64 = 0;
    var selected_successor: u64 = 0;
    var recovered_applied: u64 = 0;
    var recovered_already_applied: u64 = 0;
    var resumes_before_repair: u64 = 0;
    var resumes_after_repair: u64 = 0;

    for ([_]checkpoint_file.IoPhaseV1{
        .archive_write,
        .archive_sync,
        .archive_directory_sync,
        .selector_write,
        .selector_sync,
        .selector_rename,
        .selector_directory_sync,
    }, 0..) |phase, phase_index| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const phase_allocator = arena.allocator();
        var directory_name_storage: [64]u8 = undefined;
        const directory_name = try std.fmt.bufPrint(
            &directory_name_storage,
            "media-checkpoint-death-{d}",
            .{phase_index},
        );
        try temporary.dir.makeDir(directory_name);
        var directory = try temporary.dir.openDir(
            directory_name,
            .{},
        );
        defer directory.close();
        var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
        const absolute_directory =
            try directory.realpath(
                ".",
                &absolute_storage,
            );
        try writeSyncedV1(
            &directory,
            "publication.set",
            second_set.archive.bytes,
        );
        var pid_storage: [32]u8 = undefined;
        const source_pid = try std.fmt.bufPrint(
            &pid_storage,
            "{d}",
            .{currentProcessId()},
        );
        try writeSyncedV1(
            &directory,
            "source.pid",
            source_pid,
        );
        try std.posix.fsync(directory.fd);

        const initial_selector =
            try checkpoint_file.prepareInitialSelectorV1(
                first_set.archive,
            );
        const storage_epoch: u64 =
            15_000 + phase_index;
        var lock_storage: [1]u8 = undefined;
        var active_storage: [maximum_set_bytes]u8 = undefined;
        var lease = try checkpoint_file.LeaseV1.create(
            directory,
            storage_epoch,
            challenge_sha256,
            first_set.archive,
            initial_selector,
            active_storage.len,
            &lock_storage,
            &active_storage,
        );
        const prepared =
            try checkpoint_file.preparePublicationV1(
                &lease,
                second_set.archive,
            );
        lease.close();

        var epoch_storage: [32]u8 = undefined;
        const epoch_text = try std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{storage_epoch},
        );
        try expectKilledV1(phase_allocator, &.{
            crash_worker,
            absolute_directory,
            epoch_text,
            @tagName(phase),
            "publication.set",
            "16384",
        });
        process_deaths += 1;

        const selected = try runChildV1(
            phase_allocator,
            &.{
                resume_worker,
                absolute_directory,
                epoch_text,
            },
        );
        try validateResumeEvidenceV1(selected);
        if (std.mem.indexOf(
            u8,
            selected,
            "\"selected_generation\":1",
        ) != null) {
            selected_previous += 1;
        } else if (std.mem.indexOf(
            u8,
            selected,
            "\"selected_generation\":2",
        ) != null) {
            selected_successor += 1;
        } else {
            return error.InvalidSelectedGeneration;
        }
        resumes_before_repair += 1;

        var reopened_lock: [1]u8 = undefined;
        var reopened_storage: [maximum_set_bytes]u8 = undefined;
        var reopened = try checkpoint_file.LeaseV1.open(
            directory,
            storage_epoch,
            challenge_sha256,
            reopened_storage.len,
            &reopened_lock,
            &reopened_storage,
        );
        const recovered = try checkpoint_file.recoverV1(
            &reopened,
            prepared,
        );
        switch (recovered.disposition) {
            .applied => recovered_applied += 1,
            .already_applied => recovered_already_applied += 1,
        }
        const repeated = try checkpoint_file.recoverV1(
            &reopened,
            prepared,
        );
        if (repeated.disposition != .already_applied)
            return error.NonIdempotentRecovery;
        const repaired = try media_set.decodeMaterializedSetV1(
            reopened.stream(),
        );
        if (repaired.stateful_set.media_set.archive.metadata.generation != 2 or
            !std.mem.eql(
                u8,
                &repaired.stateful_set.media_set.archive
                    .checkpoint_sha256,
                &second_set.archive.checkpoint_sha256,
            ))
            return error.InvalidRecoveredGeneration;
        reopened.close();

        const resumed = try runChildV1(
            phase_allocator,
            &.{
                resume_worker,
                absolute_directory,
                epoch_text,
            },
        );
        try validateResumeEvidenceV1(resumed);
        if (std.mem.indexOf(
            u8,
            resumed,
            "\"selected_generation\":2",
        ) == null)
            return error.InvalidRecoveredGeneration;
        resumes_after_repair += 1;
    }

    const successor_directory_name =
        "media-post-restore-successor";
    try temporary.dir.makeDir(successor_directory_name);
    var successor_directory = try temporary.dir.openDir(
        successor_directory_name,
        .{},
    );
    defer successor_directory.close();
    var successor_absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
    const successor_absolute =
        try successor_directory.realpath(
            ".",
            &successor_absolute_storage,
        );
    var source_pid_storage: [32]u8 = undefined;
    const source_pid = try std.fmt.bufPrint(
        &source_pid_storage,
        "{d}",
        .{currentProcessId()},
    );
    try writeSyncedV1(
        &successor_directory,
        "source.pid",
        source_pid,
    );
    try std.posix.fsync(successor_directory.fd);

    const successor_storage_epoch: u64 = 19_000;
    const successor_initial_selector =
        try checkpoint_file.prepareInitialSelectorV1(
            first_set.archive,
        );
    var successor_lock_storage: [1]u8 = undefined;
    var successor_active_storage: [maximum_set_bytes]u8 = undefined;
    var successor_lease =
        try checkpoint_file.LeaseV1.create(
            successor_directory,
            successor_storage_epoch,
            challenge_sha256,
            first_set.archive,
            successor_initial_selector,
            successor_active_storage.len,
            &successor_lock_storage,
            &successor_active_storage,
        );
    const second_publication =
        try checkpoint_file.preparePublicationV1(
            &successor_lease,
            second_set.archive,
        );
    _ = try checkpoint_file.publishV1(
        &successor_lease,
        second_publication,
    );
    successor_lease.close();

    var successor_epoch_storage: [32]u8 = undefined;
    const successor_epoch_text = try std.fmt.bufPrint(
        &successor_epoch_storage,
        "{d}",
        .{successor_storage_epoch},
    );
    const successor_evidence = try runChildV1(
        allocator,
        &.{
            resume_worker,
            successor_absolute,
            successor_epoch_text,
            "publish-successor",
        },
    );
    inline for ([_][]const u8{
        "\"process_restart\":true",
        "\"previous_generation\":2",
        "\"published_generation\":3",
        "\"modalities\":3",
        "\"rebound_outputs\":6",
        "\"new_chunks\":3",
        "\"retained_outputs\":9",
        "\"stale_source_authority\":false",
        "\"charge_before_materialize\":true",
        "\"cache_charge_before_materialize\":true",
        "\"restored_cache_bytes\":1104",
        "\"processor_state_rebound\":true",
        "\"processor_cache_rebound\":true",
        "\"atomic_publication\":true",
        "\"ownership_released\":true",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(
            u8,
            successor_evidence,
            required,
        ) == null)
            return error.InvalidSuccessorEvidence;
    }

    var generation_three_lock: [1]u8 = undefined;
    var generation_three_storage: [maximum_set_bytes]u8 = undefined;
    var generation_three_lease =
        try checkpoint_file.LeaseV1.open(
            successor_directory,
            successor_storage_epoch,
            challenge_sha256,
            generation_three_storage.len,
            &generation_three_lock,
            &generation_three_storage,
        );
    const generation_three =
        try media_set.decodeMaterializedSetV1(
            generation_three_lease.stream(),
        );
    if (generation_three.stateful_set.media_set.archive.metadata.generation != 3)
        return error.InvalidSuccessorGeneration;
    try media_set.validateRestoredMaterializedSuccessorV1(
        &second_decoded,
        &generation_three,
    );
    const generation_three_archive_sha256 =
        generation_three.stateful_set.media_set.archive
            .checkpoint_sha256;
    const generation_three_bundle_sha256 =
        generation_three.stateful_set.media_set.bundle
            .bundle_sha256;
    const generation_three_processor_sha256 =
        generation_three.stateful_set.processor_bundle
            .bundle_sha256;
    const generation_three_cache_sha256 =
        generation_three.processor_cache_bundle.bundle_sha256;
    generation_three_lease.close();

    const resumed_generation_three = try runChildV1(
        allocator,
        &.{
            resume_worker,
            successor_absolute,
            successor_epoch_text,
        },
    );
    try validateResumeEvidenceV1(
        resumed_generation_three,
    );
    if (std.mem.indexOf(
        u8,
        resumed_generation_three,
        "\"selected_generation\":3",
    ) == null)
        return error.InvalidSuccessorGeneration;

    if (source_releases != 3 or
        process_deaths != 7 or
        selected_previous != 5 or
        selected_successor != 2 or
        recovered_applied != 5 or
        recovered_already_applied != 2 or
        resumes_before_repair != 7 or
        resumes_after_repair != 7)
        return error.InvalidPhaseAccounting;

    const archive_hex = std.fmt.bytesToHex(
        generation_three_archive_sha256,
        .lower,
    );
    const bundle_hex = std.fmt.bytesToHex(
        generation_three_bundle_sha256,
        .lower,
    );
    const processor_hex = std.fmt.bytesToHex(
        generation_three_processor_sha256,
        .lower,
    );
    const cache_hex = std.fmt.bytesToHex(
        generation_three_cache_sha256,
        .lower,
    );
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-stream-checkpoint-set/demo-v1\"," ++
            "\"modalities\":3,\"checkpoint_generations\":3," ++
            "\"archive_objects\":6,\"retained_outputs\":9," ++
            "\"processor_state_bundle\":true," ++
            "\"materialized_cache_bundle\":true," ++
            "\"cache_charge_before_materialize\":true," ++
            "\"generation_three_cache_bytes\":1288," ++
            "\"source_ownership_releases\":3," ++
            "\"process_deaths\":7,\"archive_phase_deaths\":3," ++
            "\"selector_phase_deaths\":4," ++
            "\"selected_previous_generation\":5," ++
            "\"selected_successor_generation\":2," ++
            "\"fresh_resumes_before_repair\":7," ++
            "\"fresh_resumes_after_repair\":7," ++
            "\"resumed_chunks\":45," ++
            "\"duplicate_publications\":0," ++
            "\"atomic_root_switch\":true," ++
            "\"exact_previous_or_successor\":true," ++
            "\"foreign_lineage_rejected\":true," ++
            "\"post_restore_successor\":true," ++
            "\"restored_ownership_rebound\":true," ++
            "\"stale_source_authority_rejected\":true," ++
            "\"recovery_idempotent\":true," ++
            "\"charge_before_materialize\":true," ++
            "\"filesystem_authority\":true," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":false," ++
            "\"power_loss_emulated\":false," ++
            "\"archive_sha256\":\"{s}\"," ++
            "\"bundle_sha256\":\"{s}\"," ++
            "\"processor_bundle_sha256\":\"{s}\"," ++
            "\"processor_cache_bundle_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{ &archive_hex, &bundle_hex, &processor_hex, &cache_hex },
    );
    try stdout.flush();
}

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
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
    previous: ?*const processor.DecodedBundleV1,
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
        const previous_state_sha256 = if (previous) |prior|
            prior.states[index].state_sha256
        else if (generation == 1)
            [_]u8{0} ** 32
        else
            return error.MissingProcessorLineage;
        plan.* = .{
            .kind = checkpoint.kind,
            .request_epoch = checkpoint.request_epoch,
            .generation = generation,
            .stream_key = checkpoint.stream_key,
            .timeline_base = timeline_base,
            .media_object_sha256 = checkpoint.media_object_sha256,
            .processor_plan_sha256 = [_]u8{@intCast(0x31 + index)} ** 32,
            .previous_state_sha256 = previous_state_sha256,
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
    const previous_sync_sha256 = if (previous) |prior|
        prior.sync.sync_sha256
    else if (generation == 1)
        [_]u8{0} ** 32
    else
        return error.MissingProcessorLineage;
    const sync = try processor.makeSyncStateV1(
        states,
        .{
            .generation = generation,
            .request_epoch = checkpoints[0].request_epoch,
            .master_ticks_per_second = 48_000,
            .maximum_skew_ticks = 800,
            .challenge_sha256 = checkpoints[0].challenge_sha256,
            .sync_policy_sha256 = [_]u8{0x6d} ** 32,
            .previous_sync_sha256 = previous_sync_sha256,
        },
    );
    return .{ .states = states, .sync = sync };
}

const Context = struct {
    encoded_fixture: []const u8,
    fixture: fixture_api.ParsedFixtureV1,
    encoded_decode_plan: []const u8,
    decode_receipt: fixture_api.DecodeReceiptV1,
    timeline_base: media.TimeBaseV1,
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
        .timeline_base = switch (stream_index) {
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

fn checkpointPlanV1(
    stream_index: usize,
    generation: u64,
    previous_checkpoint_sha256: continuation.Digest,
) continuation.CheckpointPlanV1 {
    const generation_base: u64 = switch (generation) {
        1 => 13_000,
        2 => 14_000,
        3 => 15_000,
        else => unreachable,
    };
    const stream_base =
        generation_base + stream_index * 100;
    return .{
        .checkpoint_generation = generation,
        .chunk_limit = 4,
        .restore_bank_epoch = stream_base,
        .restore_owner_key_base = stream_base + 10,
        .restore_tree_key_base = stream_base + 20,
        .restore_authority_key_base = stream_base + 30,
        .next_owner_key_base = stream_base + 40,
        .next_tree_key_base = stream_base + 50,
        .next_authority_key_base = stream_base + 60,
        .tenant_key = 12_330 + stream_index,
        .challenge_sha256 = challenge_sha256,
        .previous_checkpoint_sha256 = previous_checkpoint_sha256,
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

fn validateResumeEvidenceV1(
    output: []const u8,
) !void {
    inline for (.{
        "\"process_restart\":true",
        "\"modalities\":3",
        "\"resumed_chunks\":3",
        "\"duplicate_publications\":0",
        "\"charge_before_materialize\":true",
        "\"cache_charge_before_materialize\":true",
        "\"cache_ownership_released\":true",
        "\"final_bank_host_bytes\":0",
        "\"final_live_allocations\":0",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(u8, output, required) == null)
            return error.InvalidResumeEvidence;
    }
}

fn runChildV1(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = arguments,
        .max_output_bytes = 32 * 1024,
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0)
            return error.WorkerFailed,
        else => return error.WorkerFailed,
    }
    return result.stdout;
}

fn expectKilledV1(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = arguments,
        .max_output_bytes = 32 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!wasForceTerminated(result.term))
        return error.WorkerWasNotKilled;
}

fn wasForceTerminated(term: std.process.Child.Term) bool {
    if (comptime builtin.os.tag == .windows) {
        return switch (term) {
            .Exited => |code| code == 137,
            else => false,
        };
    }
    return switch (term) {
        .Signal => |signal| signal == std.posix.SIG.KILL,
        else => false,
    };
}
