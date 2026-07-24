//! Two-process generated-audio publication and application acknowledgement.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const model = core.model_contract;
const media = core.media_contract;
const resource_bank = core.resource_bank;
const audio = core.generated_audio_playback;

const state_name = "generated-audio.state";
const result_name = "generated-audio.first-result";
const pcm_name = "generated-audio.first-pcm";
const source_pid_name = "generated-audio.source-pid";
const source_bank_epoch: u64 = 101_001;
const target_bank_epoch: u64 = 102_001;

const RuntimeStorage = struct {
    slots: [12]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 12,
    roots: [12]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 12,
    nodes: [24]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 24,
};

const PublishedChunk = struct {
    result: audio.GeneratedAudioResultV1,
    pcm: [4]u8,
    provenance_wire: [audio.provenance_bytes]u8,
    result_wire: [audio.result_bytes]u8,
    cancelled_publications: u64,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 3)
        return error.InvalidArguments;
    var directory = try std.fs.openDirAbsolute(arguments[2], .{});
    defer directory.close();
    if (std.mem.eql(u8, arguments[1], "source")) {
        try publishSourceV1(&directory);
    } else if (std.mem.eql(u8, arguments[1], "target")) {
        try resumeTargetV1(&directory);
    } else {
        return error.InvalidArguments;
    }
}

fn publishSourceV1(directory: *std.fs.Dir) !void {
    var state = try makeInitialStateV1();
    var storage: RuntimeStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        source_bank_epoch,
    );
    var renderer_context: u8 = 1;
    const source_tokens = [_]u8{ 129, 127 };
    const published = try publishChunkV1(
        &bank,
        &state,
        103_001,
        &source_tokens,
        model.sha256("generated audio source result zero"),
        &renderer_context,
        false,
    );
    if (state.pending != 1 or
        state.visible_chunks != 1 or
        state.acknowledged_chunks != 0 or
        !std.mem.eql(
            u8,
            &state.pending_publication_result_sha256,
            &published.result.result_sha256,
        ))
        return error.InvalidSourceState;
    const final = try bank.snapshotV3();
    if (!final.used.isZero() or
        final.live_allocations != 0 or
        final.active_lease_trees != 0)
        return error.SourceOwnershipLeak;
    var state_wire: [audio.state_bytes]u8 = undefined;
    _ = try audio.encodeStateV1(state, &state_wire);
    try writeSyncedV1(directory, state_name, &state_wire);
    try writeSyncedV1(
        directory,
        result_name,
        &published.result_wire,
    );
    try writeSyncedV1(directory, pcm_name, &published.pcm);
    var pid_storage: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(
        &pid_storage,
        "{d}",
        .{currentProcessId()},
    );
    try writeSyncedV1(directory, source_pid_name, pid);
    try std.posix.fsync(directory.fd);
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.generated-audio-live-restart/demo-v1\"," ++
            "\"phase\":\"source\",\"source_pid\":{d}," ++
            "\"published_chunks\":1,\"published_frames\":2," ++
            "\"acknowledged_chunks\":0,\"pending_chunks\":1," ++
            "\"source_ownership_released\":true," ++
            "\"file_sync\":true,\"verified\":true}}\n",
        .{currentProcessId()},
    );
    try stdout.flush();
}

fn resumeTargetV1(directory: *std.fs.Dir) !void {
    var pid_storage: [32]u8 = undefined;
    const pid_wire = try readBoundedV1(
        directory,
        source_pid_name,
        &pid_storage,
    );
    const source_pid = try std.fmt.parseInt(u32, pid_wire, 10);
    const target_pid = currentProcessId();
    if (source_pid == target_pid)
        return error.ProcessDidNotRestart;

    var state_storage: [audio.state_bytes]u8 = undefined;
    const state_wire = try readExactV1(
        directory,
        state_name,
        &state_storage,
    );
    var state = try audio.decodeStateV1(state_wire);
    var result_storage: [audio.result_bytes]u8 = undefined;
    const result_wire = try readExactV1(
        directory,
        result_name,
        &result_storage,
    );
    const first_result = try audio.decodeResultV1(result_wire);
    var first_pcm: [4]u8 = undefined;
    _ = try readExactV1(directory, pcm_name, &first_pcm);
    if (state.pending != 1 or
        !std.mem.eql(
            u8,
            &state.pending_publication_result_sha256,
            &first_result.result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state.pending_output_sha256,
            &model.sha256(&first_pcm),
        ))
        return error.RestoreValidationFailed;

    var renderer_context: u8 = 1;
    const blocked = audio.makePlanV1(
        state,
        2,
        2,
        4,
        0,
        audio.reference_renderer_abi,
        model.sha256("blocked generated audio source result"),
        model.sha256("blocked generated audio source output"),
        model.sha256(audio.reference_renderer_payload),
        audio.referenceRendererV1(
            &renderer_context,
        ).implementation_sha256,
        model.sha256("blocked generated audio media"),
    );
    if (blocked) |_| {
        return error.PlaybackGateMissing;
    } else |err| {
        if (err != audio.Error.PlaybackPending)
            return err;
    }

    const sink_implementation =
        model.sha256("demo playback sink implementation");
    const sink_instance =
        model.sha256("demo playback stream instance");
    const first_observation =
        try audio.makePlaybackObservationV1(
            state,
            sink_implementation,
            sink_instance,
        );
    const first_ack_plan =
        try audio.makePlaybackAckPlanV1(
            state,
            first_result,
            first_observation,
        );
    const state_before_bad_ack = state;
    var partial_observation = first_observation;
    partial_observation.consumed_frames -= 1;
    partial_observation.observation_sha256 =
        audio.observationRootV1(partial_observation);
    const partial = audio.acknowledgePlaybackV1(
        &state,
        first_result,
        partial_observation,
        first_ack_plan,
    );
    if (partial) |_| {
        return error.PartialPlaybackAccepted;
    } else |err| {
        if (err != audio.Error.InvalidObservation)
            return err;
    }
    if (!std.meta.eql(state, state_before_bad_ack))
        return error.RejectedPlaybackMutatedState;
    const first_ack = try audio.acknowledgePlaybackV1(
        &state,
        first_result,
        first_observation,
        first_ack_plan,
    );
    if (state.pending != 0 or
        state.acknowledged_chunks != 1 or
        state.acknowledged_frames != 2 or
        !std.mem.eql(
            u8,
            &state.previous_ack_result_sha256,
            &first_ack.result_sha256,
        ))
        return error.InvalidFirstAcknowledgement;

    var storage: RuntimeStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        target_bank_epoch,
    );
    const second_tokens = [_]u8{ 130, 126 };
    const second = try publishChunkV1(
        &bank,
        &state,
        104_001,
        &second_tokens,
        model.sha256("generated audio source result one"),
        &renderer_context,
        true,
    );
    const second_observation =
        try audio.makePlaybackObservationV1(
            state,
            sink_implementation,
            sink_instance,
        );
    const second_ack_plan =
        try audio.makePlaybackAckPlanV1(
            state,
            second.result,
            second_observation,
        );
    const second_ack = try audio.acknowledgePlaybackV1(
        &state,
        second.result,
        second_observation,
        second_ack_plan,
    );
    if (state.generation != 4 or
        state.visible_chunks != 2 or
        state.visible_frames != 4 or
        state.acknowledged_chunks != 2 or
        state.acknowledged_frames != 4 or
        state.playback_sequence != 2 or
        state.pending != 0 or
        second.cancelled_publications != 1)
        return error.InvalidFinalState;
    const duplicate = audio.acknowledgePlaybackV1(
        &state,
        second.result,
        second_observation,
        second_ack_plan,
    );
    if (duplicate) |_| {
        return error.DuplicateAcknowledgementAccepted;
    } else |err| {
        if (err != audio.Error.NoPlaybackPending)
            return err;
    }
    const final = try bank.snapshotV3();
    if (!final.used.isZero() or
        final.live_allocations != 0 or
        final.active_lease_trees != 0)
        return error.TargetOwnershipLeak;
    const first_result_hex = std.fmt.bytesToHex(
        first_result.result_sha256,
        .lower,
    );
    const second_result_hex = std.fmt.bytesToHex(
        second.result.result_sha256,
        .lower,
    );
    const final_ack_hex = std.fmt.bytesToHex(
        second_ack.result_sha256,
        .lower,
    );
    const final_state_hex = std.fmt.bytesToHex(
        state.state_sha256,
        .lower,
    );
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.generated-audio-live-restart/demo-v1\"," ++
            "\"phase\":\"target\",\"source_pid\":{d}," ++
            "\"target_pid\":{d},\"process_restart\":true," ++
            "\"sample_rate\":16000,\"channels\":1," ++
            "\"sample_format\":\"pcm-s16le\"," ++
            "\"first_pcm\":\"256,-256\"," ++
            "\"second_pcm\":\"512,-512\"," ++
            "\"visible_chunks\":2,\"visible_frames\":4," ++
            "\"acknowledged_chunks\":2,\"acknowledged_frames\":4," ++
            "\"pending_chunks\":0,\"duplicate_chunks\":0," ++
            "\"duplicate_acknowledgements\":0," ++
            "\"blocked_before_ack\":true," ++
            "\"partial_ack_rejected\":true," ++
            "\"rejected_ack_preserved_state\":true," ++
            "\"cancelled_publications\":1," ++
            "\"cancellation_preserved_visibility\":true," ++
            "\"atomic_visibility\":true," ++
            "\"state_validated_before_admission\":true," ++
            "\"application_acknowledgement\":true," ++
            "\"physical_playback_proven\":false," ++
            "\"final_bank_host_bytes\":0," ++
            "\"final_live_allocations\":0," ++
            "\"final_active_lease_trees\":0," ++
            "\"filesystem_authority\":true," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"playback_device_authority\":false," ++
            "\"production_model\":false," ++
            "\"first_result_sha256\":\"{s}\"," ++
            "\"second_result_sha256\":\"{s}\"," ++
            "\"final_ack_sha256\":\"{s}\"," ++
            "\"final_state_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            source_pid,
            target_pid,
            &first_result_hex,
            &second_result_hex,
            &final_ack_hex,
            &final_state_hex,
        },
    );
    try stdout.flush();
}

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

fn makeInitialStateV1() !audio.GeneratedAudioStateV1 {
    return audio.makeInitialStateV1(
        105_001,
        16_000,
        1,
        model.sha256("generated audio demo artifact"),
        model.sha256("generated audio demo tenant"),
        model.sha256("generated audio demo metadata policy"),
        model.sha256("generated audio demo challenge"),
    );
}

fn publishChunkV1(
    bank: *resource_bank.Bank,
    state: *audio.GeneratedAudioStateV1,
    owner_key: u64,
    source_output: *const [2]u8,
    source_result_sha256: audio.Digest,
    renderer_context: *anyopaque,
    cancel_once: bool,
) !PublishedChunk {
    const renderer = audio.referenceRendererV1(renderer_context);
    var expected_pcm: [4]u8 = undefined;
    try audio.renderReferencePcmV1(
        source_output,
        &expected_pcm,
    );
    const source_output_sha256 = model.sha256(source_output);
    const media_object = try audio.makeAudioMediaObjectV1(
        state.*,
        2,
        model.sha256(&expected_pcm),
        source_result_sha256,
        source_output_sha256,
        renderer.implementation_sha256,
    );
    var media_wire: [media.descriptor_bytes]u8 = undefined;
    _ = try media.encodeMediaObjectV1(media_object, &media_wire);
    const media_root = try media.mediaObjectSha256V1(&media_wire);
    const plan = try audio.makePlanV1(
        state.*,
        2,
        source_output.len,
        audio.maximum_pcm_bytes,
        renderer.required_capabilities,
        renderer.renderer_abi,
        source_result_sha256,
        source_output_sha256,
        model.sha256(audio.reference_renderer_payload),
        renderer.implementation_sha256,
        media_root,
    );
    var session: audio.Session = .{};
    try session.initV1(
        bank,
        owner_key,
        state,
        plan,
        media_object,
        audio.reference_renderer_payload,
        renderer,
    );
    var candidate_output: [4]u8 = undefined;
    var candidate_provenance: [audio.provenance_bytes]u8 = undefined;
    var candidate_result: [audio.result_bytes]u8 = undefined;
    var visible_output = [_]u8{0xa5} ** 4;
    var visible_provenance =
        [_]u8{0xa5} ** audio.provenance_bytes;
    var visible_result =
        [_]u8{0xa5} ** audio.result_bytes;
    var cancelled: u64 = 0;
    if (cancel_once) {
        const state_before = state.*;
        _ = try session.prepareV1(
            source_output,
            &candidate_output,
            &candidate_provenance,
            &candidate_result,
            &visible_output,
            &visible_provenance,
            &visible_result,
        );
        if (!std.meta.eql(state.*, state_before) or
            !std.mem.allEqual(u8, &visible_output, 0xa5))
            return error.VisibilityAdvancedBeforeCommit;
        try session.abortV1();
        if (!std.meta.eql(state.*, state_before) or
            !std.mem.allEqual(u8, &candidate_output, 0) or
            !std.mem.allEqual(u8, &visible_output, 0xa5))
            return error.CancelledAudioBecameVisible;
        cancelled = 1;
    }
    const state_before = state.*;
    _ = try session.prepareV1(
        source_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    if (!std.meta.eql(state.*, state_before) or
        !std.mem.allEqual(u8, &visible_output, 0xa5))
        return error.VisibilityAdvancedBeforeCommit;
    const result = try session.commitV1();
    const provenance = try audio.decodeProvenanceV1(
        &visible_provenance,
    );
    const decoded_result = try audio.decodeResultV1(
        &visible_result,
    );
    if (!std.mem.eql(u8, &visible_output, &expected_pcm) or
        !std.meta.eql(result, decoded_result) or
        !std.mem.eql(
            u8,
            &provenance.provenance_sha256,
            &result.provenance_sha256,
        ))
        return error.InvalidAudioPublication;
    try session.closeAndRelease();
    return .{
        .result = result,
        .pcm = visible_output,
        .provenance_wire = visible_provenance,
        .result_wire = visible_result,
        .cancelled_publications = cancelled,
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
    storage: []u8,
) ![]const u8 {
    const bytes = try readBoundedV1(directory, name, storage);
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
