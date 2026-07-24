//! Two-process generated-video publication and display acknowledgement.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const media = core.media_contract;
const model = core.model_contract;
const resource_bank = core.resource_bank;
const video = core.generated_video_display;

const state_name = "generated-video.state";
const manifest_name = "generated-video.first-manifest";
const provenance_name = "generated-video.first-provenance";
const result_name = "generated-video.first-result";
const output_name = "generated-video.first-output";
const media_name = "generated-video.first-media";
const source_pid_name = "generated-video.source-pid";
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

const Chunk = struct {
    manifest: video.GeneratedVideoManifestV1,
    media_object: media.MediaObjectV1,
    output: [8]u8,
};

const PublishedChunk = struct {
    manifest: video.GeneratedVideoManifestV1,
    result: video.GeneratedVideoResultV1,
    output: [8]u8,
    manifest_wire: [video.manifest_bytes]u8,
    provenance_wire: [video.provenance_bytes]u8,
    result_wire: [video.result_bytes]u8,
    media_wire: [media.descriptor_bytes]u8,
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
    const source_tokens = [_]u8{ 3, 7 };
    const published = try publishChunkV1(
        &bank,
        &state,
        103_001,
        &source_tokens,
        2,
        3,
        model.sha256("generated video demo source result zero"),
        &renderer_context,
        false,
    );
    if (state.pending != 1 or
        state.visible_segments != 1 or
        state.visible_frames != 2 or
        state.displayed_segments != 0 or
        state.visible_end_tick != 5 or
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
    var state_wire: [video.state_bytes]u8 = undefined;
    _ = try video.encodeStateV1(state, &state_wire);
    try writeSyncedV1(directory, state_name, &state_wire);
    try writeSyncedV1(
        directory,
        manifest_name,
        &published.manifest_wire,
    );
    try writeSyncedV1(
        directory,
        provenance_name,
        &published.provenance_wire,
    );
    try writeSyncedV1(
        directory,
        result_name,
        &published.result_wire,
    );
    try writeSyncedV1(directory, output_name, &published.output);
    try writeSyncedV1(directory, media_name, &published.media_wire);
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
        "{{\"schema\":\"glacier.generated-video-live-restart/demo-v1\"," ++
            "\"phase\":\"source\",\"source_pid\":{d}," ++
            "\"published_segments\":1,\"published_frames\":2," ++
            "\"displayed_segments\":0,\"pending_segments\":1," ++
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

    var state_storage: [video.state_bytes]u8 = undefined;
    var manifest_storage: [video.manifest_bytes]u8 = undefined;
    var provenance_storage: [video.provenance_bytes]u8 = undefined;
    var result_storage: [video.result_bytes]u8 = undefined;
    var output: [8]u8 = undefined;
    var media_storage: [media.descriptor_bytes]u8 = undefined;
    const state_wire = try readExactV1(
        directory,
        state_name,
        &state_storage,
    );
    const manifest_wire = try readExactV1(
        directory,
        manifest_name,
        &manifest_storage,
    );
    const provenance_wire = try readExactV1(
        directory,
        provenance_name,
        &provenance_storage,
    );
    const result_wire = try readExactV1(
        directory,
        result_name,
        &result_storage,
    );
    _ = try readExactV1(directory, output_name, &output);
    const media_wire = try readExactV1(
        directory,
        media_name,
        &media_storage,
    );
    var state = try video.decodeStateV1(state_wire);
    const first_manifest = try video.decodeManifestV1(manifest_wire);
    const first_provenance =
        try video.decodeProvenanceV1(provenance_wire);
    const first_result = try video.decodeResultV1(result_wire);
    const first_media = try media.decodeMediaObjectV1(media_wire);
    var renderer_context: u8 = 1;
    const renderer = video.referenceRendererV1(&renderer_context);
    const source_state = try makeInitialStateV1();
    try video.validatePublicationBindingsV1(
        first_manifest,
        source_state,
        first_media,
        video.reference_renderer_payload,
        renderer,
    );
    try video.validateProvenanceBindingV1(
        first_manifest,
        first_provenance,
    );
    try video.validateResultBindingV1(
        first_manifest,
        first_provenance,
        first_result,
    );
    if (state.pending != 1 or
        !std.mem.eql(
            u8,
            &state.pending_publication_result_sha256,
            &first_result.result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state.pending_output_sha256,
            &model.sha256(&output),
        ) or
        !std.mem.eql(
            u8,
            &first_manifest.first_frame_sha256,
            &model.sha256(output[0..4]),
        ) or
        !std.mem.eql(
            u8,
            &first_manifest.second_frame_sha256,
            &model.sha256(output[4..8]),
        ))
        return error.RestoreValidationFailed;

    const blocked = video.makeManifestV1(
        state,
        4,
        1,
        2,
        8,
        0,
        video.reference_renderer_abi,
        model.sha256("blocked generated video source result"),
        model.sha256("blocked generated video source output"),
        model.sha256(video.reference_renderer_payload),
        renderer.implementation_sha256,
        model.sha256("blocked generated video media"),
        model.sha256("blocked generated video frame zero"),
        model.sha256("blocked generated video frame one"),
    );
    if (blocked) |_| {
        return error.DisplayGateMissing;
    } else |err| {
        if (err != video.Error.DisplayPending)
            return err;
    }
    const sink_implementation =
        model.sha256("demo display sink implementation");
    const sink_instance =
        model.sha256("demo display stream instance");
    const first_observation = try video.makeDisplayObservationV1(
        state,
        sink_implementation,
        sink_instance,
    );
    const first_ack_plan = try video.makeDisplayAckPlanV1(
        state,
        first_result,
        first_observation,
    );
    const state_before_bad_ack = state;
    var partial = first_observation;
    partial.consumed_frames -= 1;
    partial.observation_sha256 = video.observationRootV1(partial);
    const partial_ack = video.acknowledgeDisplayV1(
        &state,
        first_result,
        partial,
        first_ack_plan,
    );
    if (partial_ack) |_| {
        return error.PartialDisplayAccepted;
    } else |_| {}
    if (!std.meta.eql(state, state_before_bad_ack))
        return error.RejectedDisplayMutatedState;
    _ = try video.acknowledgeDisplayV1(
        &state,
        first_result,
        first_observation,
        first_ack_plan,
    );

    var storage: RuntimeStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        target_bank_epoch,
    );
    const second_source = [_]u8{ 11, 13 };
    const second = try publishChunkV1(
        &bank,
        &state,
        104_001,
        &second_source,
        4,
        1,
        first_result.result_sha256,
        &renderer_context,
        true,
    );
    const second_observation = try video.makeDisplayObservationV1(
        state,
        sink_implementation,
        sink_instance,
    );
    const second_ack_plan = try video.makeDisplayAckPlanV1(
        state,
        second.result,
        second_observation,
    );
    const final_ack = try video.acknowledgeDisplayV1(
        &state,
        second.result,
        second_observation,
        second_ack_plan,
    );
    const duplicate = video.acknowledgeDisplayV1(
        &state,
        second.result,
        second_observation,
        second_ack_plan,
    );
    if (duplicate) |_| {
        return error.DuplicateDisplayAccepted;
    } else |err| {
        if (err != video.Error.NoDisplayPending)
            return err;
    }
    const final = try bank.snapshotV3();
    if (state.pending != 0 or
        state.visible_segments != 2 or
        state.visible_frames != 4 or
        state.visible_end_tick != 10 or
        state.displayed_segments != 2 or
        state.displayed_frames != 4 or
        state.displayed_end_tick != 10 or
        second.cancelled_publications != 1 or
        !final.used.isZero() or
        final.live_allocations != 0 or
        final.active_lease_trees != 0)
        return error.InvalidFinalState;
    const first_result_hex = std.fmt.bytesToHex(
        first_result.result_sha256,
        .lower,
    );
    const second_result_hex = std.fmt.bytesToHex(
        second.result.result_sha256,
        .lower,
    );
    const final_ack_hex = std.fmt.bytesToHex(
        final_ack.result_sha256,
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
        "{{\"schema\":\"glacier.generated-video-live-restart/demo-v1\"," ++
            "\"phase\":\"target\",\"source_pid\":{d}," ++
            "\"target_pid\":{d},\"process_restart\":true," ++
            "\"width\":2,\"height\":2,\"channels\":1," ++
            "\"pixel_format\":\"gray8-frame-major\"," ++
            "\"first_frames\":\"3,7\",\"second_frames\":\"11,13\"," ++
            "\"frame_durations\":\"2,3,4,1\"," ++
            "\"visible_segments\":2,\"visible_frames\":4," ++
            "\"visible_end_tick\":10,\"displayed_segments\":2," ++
            "\"displayed_frames\":4,\"displayed_end_tick\":10," ++
            "\"pending_segments\":0,\"duplicate_segments\":0," ++
            "\"duplicate_acknowledgements\":0," ++
            "\"blocked_before_ack\":true," ++
            "\"partial_ack_rejected\":true," ++
            "\"rejected_ack_preserved_state\":true," ++
            "\"cancelled_publications\":1," ++
            "\"cancellation_preserved_visibility\":true," ++
            "\"atomic_visibility\":true," ++
            "\"state_validated_before_admission\":true," ++
            "\"application_display_acknowledgement\":true," ++
            "\"physical_display_proven\":false," ++
            "\"final_bank_host_bytes\":0," ++
            "\"final_live_allocations\":0," ++
            "\"final_active_lease_trees\":0," ++
            "\"filesystem_authority\":true," ++
            "\"network_authority\":false,\"device_authority\":false," ++
            "\"display_device_authority\":false," ++
            "\"production_model\":false," ++
            "\"first_result_sha256\":\"{s}\"," ++
            "\"second_result_sha256\":\"{s}\"," ++
            "\"final_ack_sha256\":\"{s}\"," ++
            "\"final_state_sha256\":\"{s}\",\"verified\":true}}\n",
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

fn makeInitialStateV1() !video.GeneratedVideoStateV1 {
    return video.initializeStateV1(
        105_001,
        2,
        2,
        1,
        model.sha256("generated video demo artifact"),
        model.sha256("generated video demo tenant"),
        model.sha256("generated video demo metadata policy"),
        model.sha256("generated video demo challenge"),
    );
}

fn makeChunkV1(
    state: video.GeneratedVideoStateV1,
    source_output: *const [2]u8,
    first_duration_ticks: u64,
    second_duration_ticks: u64,
    source_result_sha256: video.Digest,
    renderer: video.RendererV1,
) !Chunk {
    const output = [8]u8{
        source_output[0],
        source_output[0],
        source_output[0],
        source_output[0],
        source_output[1],
        source_output[1],
        source_output[1],
        source_output[1],
    };
    const first_root = model.sha256(output[0..4]);
    const second_root = model.sha256(output[4..8]);
    const provisional = try video.makeManifestV1(
        state,
        first_duration_ticks,
        second_duration_ticks,
        source_output.len,
        output.len,
        renderer.required_capabilities,
        renderer.renderer_abi,
        source_result_sha256,
        model.sha256(source_output),
        model.sha256(video.reference_renderer_payload),
        renderer.implementation_sha256,
        model.sha256("generated video demo placeholder media"),
        first_root,
        second_root,
    );
    const media_object = media.MediaObjectV1{
        .kind = .video,
        .semantic_abi = video.raw_video_semantic_abi,
        .byte_length = output.len,
        .container_id = video.raw_container_id,
        .codec_id = video.gray8_frame_codec_id,
        .axes = .{ 2, 2, 2 },
        .time_base = .{ .numerator = 1, .denominator = 1_000 },
        .tenant_scope_sha256 = state.tenant_scope_sha256,
        .content_sha256 = model.sha256(&output),
        .metadata_policy_sha256 = state.metadata_policy_sha256,
        .provenance_sha256 = video.sourceProvenanceRootV1(provisional),
    };
    var media_wire: [media.descriptor_bytes]u8 = undefined;
    _ = try media.encodeMediaObjectV1(media_object, &media_wire);
    const media_root = try media.mediaObjectSha256V1(&media_wire);
    const manifest = try video.makeManifestV1(
        state,
        first_duration_ticks,
        second_duration_ticks,
        source_output.len,
        output.len,
        renderer.required_capabilities,
        renderer.renderer_abi,
        source_result_sha256,
        model.sha256(source_output),
        model.sha256(video.reference_renderer_payload),
        renderer.implementation_sha256,
        media_root,
        first_root,
        second_root,
    );
    return .{
        .manifest = manifest,
        .media_object = media_object,
        .output = output,
    };
}

fn publishChunkV1(
    bank: *resource_bank.Bank,
    state: *video.GeneratedVideoStateV1,
    owner_key: u64,
    source_output: *const [2]u8,
    first_duration_ticks: u64,
    second_duration_ticks: u64,
    source_result_sha256: video.Digest,
    renderer_context: *anyopaque,
    cancel_once: bool,
) !PublishedChunk {
    const renderer = video.referenceRendererV1(renderer_context);
    const chunk = try makeChunkV1(
        state.*,
        source_output,
        first_duration_ticks,
        second_duration_ticks,
        source_result_sha256,
        renderer,
    );
    var session: video.Session = .{};
    try session.initV1(
        bank,
        owner_key,
        state,
        chunk.manifest,
        chunk.media_object,
        video.reference_renderer_payload,
        renderer,
    );
    var candidate_output: [8]u8 = undefined;
    var candidate_provenance: [video.provenance_bytes]u8 = undefined;
    var candidate_result: [video.result_bytes]u8 = undefined;
    var visible_output = [_]u8{0xa5} ** 8;
    var visible_provenance =
        [_]u8{0xa5} ** video.provenance_bytes;
    var visible_result = [_]u8{0xa5} ** video.result_bytes;
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
        try session.abortV1();
        if (!std.meta.eql(state.*, state_before) or
            !std.mem.allEqual(u8, &candidate_output, 0) or
            !std.mem.allEqual(u8, &visible_output, 0xa5))
            return error.CancelledVideoBecameVisible;
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
    const provenance = try video.decodeProvenanceV1(
        &visible_provenance,
    );
    const decoded_result = try video.decodeResultV1(&visible_result);
    if (!std.mem.eql(u8, &visible_output, &chunk.output) or
        !std.meta.eql(result, decoded_result) or
        !std.mem.eql(
            u8,
            &provenance.provenance_sha256,
            &result.provenance_sha256,
        ))
        return error.InvalidVideoPublication;
    try session.closeAndRelease();
    var manifest_wire: [video.manifest_bytes]u8 = undefined;
    _ = try video.encodeManifestV1(chunk.manifest, &manifest_wire);
    var media_wire: [media.descriptor_bytes]u8 = undefined;
    _ = try media.encodeMediaObjectV1(
        chunk.media_object,
        &media_wire,
    );
    return .{
        .manifest = chunk.manifest,
        .result = result,
        .output = visible_output,
        .manifest_wire = manifest_wire,
        .provenance_wire = visible_provenance,
        .result_wire = visible_result,
        .media_wire = media_wire,
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
