//! Two-process stateful VFR video continuation worker.

const std = @import("std");
const core = @import("core");
const model = core.model_contract;
const resource_bank = core.resource_bank;
const stateful = core.stateful_model_adapter;
const model_continuation =
    core.stateful_model_continuation;
const video_model = core.stateful_video_adapter;
const video_segment = core.video_segment_adapter;
const video_timeline = core.video_segment_timeline;
const audio = core.audio_transcript_adapter;
const result_link = core.audio_video_result_link;
const continuation = core.video_model_continuation;

const checkpoint_name = "video-model.continuation";
const stateful_checkpoint_name =
    "video-model.stateful-checkpoint";
const state_publication_name =
    "video-model.state-publication";
const state_payload_name = "video-model.state-payload";
const previous_window_name =
    "video-model.previous-window";
const previous_segment_name =
    "video-model.previous-segment";
const next_window_name = "video-model.next-window";
const timeline_name = "video-model.timeline";
const previous_overlap_name =
    "video-model.previous-audio-overlap";
const previous_transcript_name =
    "video-model.previous-transcript";
const next_overlap_name =
    "video-model.next-audio-overlap";
const next_transcript_name =
    "video-model.next-transcript";
const previous_link_name = "video-model.previous-link";
const link_state_name = "video-model.link-state";
const source_pid_name = "video-model.source-pid";

const RuntimeStorage = struct {
    slots: [12]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 12,
    roots: [12]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 12,
    nodes: [24]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 24,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(
        allocator,
    );
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 3)
        return error.InvalidArguments;
    var directory = try std.fs.openDirAbsolute(
        arguments[2],
        .{},
    );
    defer directory.close();
    if (std.mem.eql(u8, arguments[1], "checkpoint")) {
        try checkpointV1(&directory);
    } else if (std.mem.eql(u8, arguments[1], "resume")) {
        try resumeV1(&directory);
    } else {
        return error.InvalidPhase;
    }
}

fn checkpointV1(directory: *std.fs.Dir) !void {
    const source =
        try continuation.makeReferenceSourceV1();
    var checkpoint_wire: [continuation.checkpoint_bytes]u8 =
        undefined;
    _ = try continuation.encodeCheckpointV1(
        source.checkpoint,
        &checkpoint_wire,
    );
    var stateful_checkpoint_wire: [model_continuation.checkpoint_bytes]u8 =
        undefined;
    _ = try model_continuation.encodeCheckpointV1(
        source.stateful_checkpoint,
        &stateful_checkpoint_wire,
    );
    var state_publication_wire: [stateful.state_publication_bytes]u8 =
        undefined;
    _ = try stateful.encodeStatePublicationV1(
        source.state_publication,
        &state_publication_wire,
    );
    var previous_window_wire: [video_model.frame_window_bytes]u8 =
        undefined;
    _ = try video_model.encodeFrameWindowV1(
        source.previous_window,
        &previous_window_wire,
    );
    var previous_segment_wire: [video_segment.video_segment_bytes]u8 =
        undefined;
    _ = try video_segment.encodeVideoSegmentV1(
        source.previous_segment,
        &previous_segment_wire,
    );
    var next_window_wire: [video_model.frame_window_bytes]u8 =
        undefined;
    _ = try video_model.encodeFrameWindowV1(
        source.next_window,
        &next_window_wire,
    );
    var timeline_wire: [video_timeline.timeline_bytes]u8 =
        undefined;
    _ = try video_timeline.encodeTimelineV1(
        source.timeline,
        &timeline_wire,
    );
    var previous_overlap_wire: [audio.overlap_plan_bytes]u8 = undefined;
    _ = try audio.encodeOverlapPlanV1(
        source.previous_overlap,
        &previous_overlap_wire,
    );
    var previous_transcript_wire: [audio.transcript_segment_bytes]u8 =
        undefined;
    _ = try audio.encodeTranscriptSegmentV1(
        source.previous_transcript,
        &previous_transcript_wire,
    );
    var next_overlap_wire: [audio.overlap_plan_bytes]u8 = undefined;
    _ = try audio.encodeOverlapPlanV1(
        source.next_overlap,
        &next_overlap_wire,
    );
    var next_transcript_wire: [audio.transcript_segment_bytes]u8 =
        undefined;
    _ = try audio.encodeTranscriptSegmentV1(
        source.next_transcript,
        &next_transcript_wire,
    );
    var previous_link_wire: [result_link.result_link_bytes]u8 =
        undefined;
    _ = try result_link.encodeResultLinkV1(
        source.previous_link,
        &previous_link_wire,
    );
    var link_state_wire: [result_link.link_state_bytes]u8 =
        undefined;
    _ = try result_link.encodeLinkStateV1(
        source.link_state,
        &link_state_wire,
    );
    inline for (.{
        .{ checkpoint_name, &checkpoint_wire },
        .{ stateful_checkpoint_name, &stateful_checkpoint_wire },
        .{ state_publication_name, &state_publication_wire },
        .{ state_payload_name, &source.state_payload },
        .{ previous_window_name, &previous_window_wire },
        .{ previous_segment_name, &previous_segment_wire },
        .{ next_window_name, &next_window_wire },
        .{ timeline_name, &timeline_wire },
        .{ previous_overlap_name, &previous_overlap_wire },
        .{ previous_transcript_name, &previous_transcript_wire },
        .{ next_overlap_name, &next_overlap_wire },
        .{ next_transcript_name, &next_transcript_wire },
        .{ previous_link_name, &previous_link_wire },
        .{ link_state_name, &link_state_wire },
    }) |entry| {
        try writeSyncedV1(
            directory,
            entry[0],
            entry[1],
        );
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
    const checkpoint_hex = std.fmt.bytesToHex(
        source.checkpoint.checkpoint_sha256,
        .lower,
    );
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.video-model-live-restart/demo-v1\"," ++
            "\"phase\":\"checkpoint\",\"source_pid\":{d}," ++
            "\"committed_segments\":1,\"visible_links\":1," ++
            "\"next_frame_ordinal\":2,\"next_start_tick\":25," ++
            "\"vfr_duration_transitions\":2," ++
            "\"declared_discontinuity_ticks\":5," ++
            "\"checkpoint_bytes\":{d},\"state_bytes\":{d}," ++
            "\"source_ownership_released\":true," ++
            "\"file_sync\":true,\"directory_sync\":true," ++
            "\"checkpoint_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            std.c.getpid(),
            continuation.checkpoint_bytes,
            video_model.reference_state_bytes,
            &checkpoint_hex,
        },
    );
    try stdout.flush();
}

fn resumeV1(directory: *std.fs.Dir) !void {
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
    var checkpoint_wire: [continuation.checkpoint_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        checkpoint_name,
        &checkpoint_wire,
    );
    const checkpoint =
        try continuation.decodeCheckpointV1(
            &checkpoint_wire,
        );
    var stateful_checkpoint_wire: [model_continuation.checkpoint_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        stateful_checkpoint_name,
        &stateful_checkpoint_wire,
    );
    var state_publication_wire: [stateful.state_publication_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        state_publication_name,
        &state_publication_wire,
    );
    var state_payload: [video_model.reference_state_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        state_payload_name,
        &state_payload,
    );
    var previous_window_wire: [video_model.frame_window_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        previous_window_name,
        &previous_window_wire,
    );
    var previous_segment_wire: [video_segment.video_segment_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        previous_segment_name,
        &previous_segment_wire,
    );
    var next_window_wire: [video_model.frame_window_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        next_window_name,
        &next_window_wire,
    );
    var timeline_wire: [video_timeline.timeline_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        timeline_name,
        &timeline_wire,
    );
    var previous_overlap_wire: [audio.overlap_plan_bytes]u8 = undefined;
    _ = try readExactV1(
        directory,
        previous_overlap_name,
        &previous_overlap_wire,
    );
    var previous_transcript_wire: [audio.transcript_segment_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        previous_transcript_name,
        &previous_transcript_wire,
    );
    var next_overlap_wire: [audio.overlap_plan_bytes]u8 = undefined;
    _ = try readExactV1(
        directory,
        next_overlap_name,
        &next_overlap_wire,
    );
    var next_transcript_wire: [audio.transcript_segment_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        next_transcript_name,
        &next_transcript_wire,
    );
    var previous_link_wire: [result_link.result_link_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        previous_link_name,
        &previous_link_wire,
    );
    var link_state_wire: [result_link.link_state_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        link_state_name,
        &link_state_wire,
    );
    var storage: RuntimeStorage = .{};
    var bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &storage.slots,
            &storage.roots,
            &storage.nodes,
            .{},
            checkpoint.restore_bank_epoch,
        );
    var resumed: continuation.ResumeSession = .{};
    try resumed.prepareV1(
        &bank,
        &checkpoint_wire,
        &stateful_checkpoint_wire,
        &state_publication_wire,
        &previous_window_wire,
        &previous_segment_wire,
        &next_window_wire,
        &timeline_wire,
        &previous_overlap_wire,
        &previous_transcript_wire,
        &next_overlap_wire,
        &next_transcript_wire,
        &previous_link_wire,
        &link_state_wire,
    );
    const reserved = try bank.snapshotV3();
    if (reserved.reserved_unmaterialized_allocations != 1 or
        reserved.live_allocations != 0)
        return error.ChargeBeforeMaterializeMissing;
    var restored_state: [video_model.reference_state_bytes]u8 =
        undefined;
    try resumed.commitMaterializedV1(
        &state_payload,
        &restored_state,
    );
    const manifest =
        try video_model.makeReferenceManifestV1(
            &video_model.reference_weights,
        );
    const second_plan =
        try video_model.makeReferencePlanV1(
            manifest,
            resumed.inner.model_publication,
            resumed.inner.state_publication,
            resumed.next_window,
            resumed.inner.checkpoint.last_plan_sha256,
        );
    var context: video_model.ReferenceContextV1 = .{
        .frame_window = resumed.next_window,
        .previous_segment_sha256 = resumed.previous_segment.segment_sha256,
    };
    const adapter =
        try video_model.referenceAdapterV1(
            manifest,
            &context,
        );
    var terminal: video_model.Session = .{};
    try terminal.initV1(
        &bank,
        113_001,
        &resumed.inner.model_publication,
        &resumed.inner.state_publication,
        manifest,
        second_plan,
        adapter,
        resumed.next_window,
    );
    var candidate_output: [video_model.reference_output_bytes]u8 =
        undefined;
    var candidate_state: [video_model.reference_state_bytes]u8 =
        undefined;
    var visible_output =
        [_]u8{0} **
        video_model.reference_output_bytes;
    var visible_state =
        [_]u8{0} **
        video_model.reference_state_bytes;
    _ = try terminal.prepareV1(
        resumed.next_window,
        &video_model.reference_weights,
        &video_model.reference_second_features,
        &restored_state,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    const terminal_result = try terminal.commitV1();
    const next_segment =
        try video_segment.decodeVideoSegmentV1(
            &visible_output,
        );
    if (!std.mem.eql(
        u8,
        &terminal_result.output_sha256,
        &model.sha256(&visible_output),
    ) or
        !std.mem.eql(
            u8,
            &next_segment.previous_segment_sha256,
            &resumed.previous_segment.segment_sha256,
        ))
        return error.InvalidVideoResultBinding;
    var timeline_session: video_timeline.Session = .{};
    try timeline_session.initV1(
        &bank,
        113_101,
        &resumed.timeline,
    );
    var timeline_candidate: [video_timeline.merge_receipt_bytes]u8 =
        undefined;
    var timeline_output =
        [_]u8{0} **
        video_timeline.merge_receipt_bytes;
    _ = try timeline_session.prepareV1(
        resumed.previous_segment,
        next_segment,
        &timeline_candidate,
        &timeline_output,
    );
    const merge_receipt =
        try timeline_session.commitV1();
    if (merge_receipt.action != .retain_distinct or
        resumed.timeline.visible_segments != 2 or
        resumed.timeline.tail_start_tick != 25 or
        resumed.timeline.tail_end_tick != 50)
        return error.InvalidVfrTimelineContinuation;
    var link_session: result_link.Session = .{};
    try link_session.initV1(
        &bank,
        113_201,
        &resumed.link_state,
    );
    var link_candidate: [result_link.result_link_bytes]u8 =
        undefined;
    var link_output =
        [_]u8{0} ** result_link.result_link_bytes;
    _ = try link_session.prepareV1(
        resumed.next_overlap,
        resumed.next_transcript,
        resumed.timeline,
        &link_candidate,
        &link_output,
    );
    const next_link = try link_session.commitV1();
    if (resumed.link_state.visible_links != 2 or
        !std.mem.eql(
            u8,
            &next_link.previous_link_sha256,
            &resumed.previous_link.link_sha256,
        ))
        return error.InvalidCrossModalContinuation;
    const next_state =
        try video_model.decodeReferenceStateV1(
            &visible_state,
        );
    if (next_state.next_frame_ordinal != 4 or
        next_state.last_end_tick != 50 or
        resumed.inner.model_publication.visible_results != 2 or
        resumed.inner.state_publication.current_step != 2)
        return error.InvalidVideoContinuation;
    try link_session.closeAndRelease();
    try timeline_session.closeAndRelease();
    try terminal.closeAndRelease();
    try resumed.closeAndRelease();
    const final = try bank.snapshotV3();
    if (!final.used.isZero() or
        final.live_allocations != 0 or
        final.active_lease_trees != 0)
        return error.TargetOwnershipLeak;
    const segment_hex = std.fmt.bytesToHex(
        next_segment.segment_sha256,
        .lower,
    );
    const timeline_hex = std.fmt.bytesToHex(
        resumed.timeline.timeline_sha256,
        .lower,
    );
    const link_hex = std.fmt.bytesToHex(
        next_link.link_sha256,
        .lower,
    );
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.video-model-live-restart/demo-v1\"," ++
            "\"phase\":\"resume\",\"source_pid\":{d}," ++
            "\"target_pid\":{d},\"process_restart\":true," ++
            "\"restored_segment\":1,\"resumed_segment\":2," ++
            "\"frame_ordinals\":\"0,1,2,3\"," ++
            "\"frame_durations\":\"8,12,10,15\"," ++
            "\"declared_discontinuity_ticks\":5," ++
            "\"next_start_tick\":25,\"next_end_tick\":50," ++
            "\"vfr_exact\":true,\"checkpoint_gap_bound\":true," ++
            "\"timeline_action\":\"retain_distinct\"," ++
            "\"visible_results\":2,\"visible_segments\":2," ++
            "\"visible_links\":2,\"duplicate_segments\":0," ++
            "\"charge_before_materialize\":true," ++
            "\"predecessor_state_released\":true," ++
            "\"final_bank_host_bytes\":0," ++
            "\"final_live_allocations\":0," ++
            "\"final_active_lease_trees\":0," ++
            "\"filesystem_authority\":true," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":true," ++
            "\"production_model\":false," ++
            "\"segment_sha256\":\"{s}\"," ++
            "\"timeline_sha256\":\"{s}\"," ++
            "\"link_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            source_pid,
            target_pid,
            &segment_hex,
            &timeline_hex,
            &link_hex,
        },
    );
    try stdout.flush();
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
    if (read != length) return error.ShortRead;
    return storage[0..length];
}
