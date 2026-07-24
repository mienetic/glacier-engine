//! Two-process transcript-model continuation worker used by the native demo.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const model = core.model_contract;
const resource_bank = core.resource_bank;
const stateful = core.stateful_model_adapter;
const model_continuation =
    core.stateful_model_continuation;
const transcript_model =
    core.stateful_transcript_adapter;
const audio = core.audio_transcript_adapter;
const video_timeline = core.video_segment_timeline;
const result_link = core.audio_video_result_link;
const continuation =
    core.audio_transcript_continuation;

const checkpoint_name =
    "audio-transcript.continuation";
const stateful_checkpoint_name =
    "audio-transcript.stateful-checkpoint";
const state_publication_name =
    "audio-transcript.state-publication";
const state_payload_name =
    "audio-transcript.state-payload";
const previous_overlap_name =
    "audio-transcript.previous-overlap";
const previous_transcript_name =
    "audio-transcript.previous-segment";
const previous_link_name =
    "audio-transcript.previous-link";
const next_overlap_name =
    "audio-transcript.next-overlap";
const timeline_name =
    "audio-transcript.video-timeline";
const link_state_name =
    "audio-transcript.link-state";
const source_pid_name =
    "audio-transcript.source-pid";

const RuntimeStorage = struct {
    slots: [8]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 8,
    roots: [8]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8,
    nodes: [16]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 16,
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
    if (std.mem.eql(
        u8,
        arguments[1],
        "checkpoint",
    )) {
        try checkpointV1(&directory);
    } else if (std.mem.eql(
        u8,
        arguments[1],
        "resume",
    )) {
        try resumeV1(&directory);
    } else {
        return error.InvalidPhase;
    }
}

fn checkpointV1(directory: *std.fs.Dir) !void {
    const source =
        try continuation.makeReferenceSourceV1();
    var checkpoint_wire: [continuation.checkpoint_bytes]u8 = undefined;
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
    var previous_link_wire: [result_link.result_link_bytes]u8 =
        undefined;
    _ = try result_link.encodeResultLinkV1(
        source.previous_link,
        &previous_link_wire,
    );
    var next_overlap_wire: [audio.overlap_plan_bytes]u8 = undefined;
    _ = try audio.encodeOverlapPlanV1(
        source.next_overlap,
        &next_overlap_wire,
    );
    var timeline_wire: [video_timeline.timeline_bytes]u8 =
        undefined;
    _ = try video_timeline.encodeTimelineV1(
        source.timeline,
        &timeline_wire,
    );
    var link_state_wire: [result_link.link_state_bytes]u8 =
        undefined;
    _ = try result_link.encodeLinkStateV1(
        source.link_state,
        &link_state_wire,
    );
    try writeSyncedV1(
        directory,
        checkpoint_name,
        &checkpoint_wire,
    );
    try writeSyncedV1(
        directory,
        stateful_checkpoint_name,
        &stateful_checkpoint_wire,
    );
    try writeSyncedV1(
        directory,
        state_publication_name,
        &state_publication_wire,
    );
    try writeSyncedV1(
        directory,
        state_payload_name,
        &source.state_payload,
    );
    try writeSyncedV1(
        directory,
        previous_overlap_name,
        &previous_overlap_wire,
    );
    try writeSyncedV1(
        directory,
        previous_transcript_name,
        &previous_transcript_wire,
    );
    try writeSyncedV1(
        directory,
        previous_link_name,
        &previous_link_wire,
    );
    try writeSyncedV1(
        directory,
        next_overlap_name,
        &next_overlap_wire,
    );
    try writeSyncedV1(
        directory,
        timeline_name,
        &timeline_wire,
    );
    try writeSyncedV1(
        directory,
        link_state_name,
        &link_state_wire,
    );
    var pid_storage: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(
        &pid_storage,
        "{d}",
        .{currentProcessId()},
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
        "{{\"schema\":\"glacier.audio-transcript-live-restart/demo-v1\"," ++
            "\"phase\":\"checkpoint\",\"source_pid\":{d}," ++
            "\"committed_segments\":1,\"visible_links\":1," ++
            "\"next_segment_index\":2,\"next_publish_sample\":10," ++
            "\"checkpoint_bytes\":{d},\"state_bytes\":{d}," ++
            "\"source_ownership_released\":true," ++
            "\"file_sync\":true,\"directory_sync\":true," ++
            "\"checkpoint_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            currentProcessId(),
            continuation.checkpoint_bytes,
            transcript_model.reference_state_bytes,
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
        u32,
        pid_wire,
        10,
    );
    const target_pid = currentProcessId();
    if (source_pid == target_pid)
        return error.ProcessDidNotRestart;

    var checkpoint_wire: [continuation.checkpoint_bytes]u8 = undefined;
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
    var state_payload: [transcript_model.reference_state_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        state_payload_name,
        &state_payload,
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
    var previous_link_wire: [result_link.result_link_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        previous_link_name,
        &previous_link_wire,
    );
    var next_overlap_wire: [audio.overlap_plan_bytes]u8 = undefined;
    _ = try readExactV1(
        directory,
        next_overlap_name,
        &next_overlap_wire,
    );
    var timeline_wire: [video_timeline.timeline_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        timeline_name,
        &timeline_wire,
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
        &previous_overlap_wire,
        &previous_transcript_wire,
        &previous_link_wire,
        &next_overlap_wire,
        &timeline_wire,
        &link_state_wire,
    );
    const reserved = try bank.snapshotV3();
    if (reserved.reserved_unmaterialized_allocations != 1 or
        reserved.live_allocations != 0)
        return error.ChargeBeforeMaterializeMissing;
    var restored_state: [transcript_model.reference_state_bytes]u8 =
        undefined;
    try resumed.commitMaterializedV1(
        &state_payload,
        &restored_state,
    );
    const active = try bank.snapshotV3();
    if (active.reserved_unmaterialized_allocations != 0 or
        active.live_allocations != 1)
        return error.InvalidRestoredOwnership;

    const manifest =
        try transcript_model.makeReferenceManifestV1(
            &transcript_model.reference_weights,
        );
    const second_plan =
        try transcript_model.makeReferencePlanV1(
            manifest,
            resumed.inner.model_publication,
            resumed.inner.state_publication,
            resumed.next_overlap,
            resumed.inner.checkpoint.last_plan_sha256,
        );
    var context: transcript_model.ReferenceContextV1 = .{
        .overlap_plan = resumed.next_overlap,
        .text_bytes = 4,
    };
    const adapter =
        try transcript_model.referenceAdapterV1(
            manifest,
            &context,
        );
    var terminal: transcript_model.Session = .{};
    try terminal.initV1(
        &bank,
        103_001,
        &resumed.inner.model_publication,
        &resumed.inner.state_publication,
        manifest,
        second_plan,
        adapter,
        resumed.next_overlap,
    );
    var candidate_output: [transcript_model.reference_output_bytes]u8 =
        undefined;
    var candidate_state: [transcript_model.reference_state_bytes]u8 =
        undefined;
    var visible_output =
        [_]u8{0} **
        transcript_model.reference_output_bytes;
    var visible_state =
        [_]u8{0} **
        transcript_model.reference_state_bytes;
    _ = try terminal.prepareV1(
        resumed.next_overlap,
        &transcript_model.reference_weights,
        &transcript_model.reference_second_features,
        &restored_state,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    const terminal_result =
        try terminal.commitV1();
    if (!std.mem.eql(
        u8,
        visible_output[0..4],
        "berg",
    ))
        return error.InvalidTranscriptOutput;
    const next_state =
        try transcript_model.decodeReferenceStateV1(
            &visible_state,
        );
    if (next_state.segment_index != 2 or
        next_state.next_sample != 18 or
        resumed.inner.model_publication.visible_results !=
            2 or
        resumed.inner.state_publication.current_step != 2)
        return error.InvalidTranscriptContinuation;
    const next_transcript =
        try audio.makeTranscriptSegmentV1(
            resumed.next_overlap,
            visible_output[0..4],
        );
    if (!std.mem.eql(
        u8,
        &terminal_result.output_sha256,
        &model.sha256(&next_transcript.text),
    ))
        return error.InvalidTranscriptResultBinding;
    try audio.validateTranscriptPredecessorV1(
        resumed.next_overlap,
        resumed.previous_transcript,
    );
    var link_session: result_link.Session = .{};
    try link_session.initV1(
        &bank,
        103_101,
        &resumed.link_state,
    );
    var link_candidate: [result_link.result_link_bytes]u8 =
        undefined;
    var link_output =
        [_]u8{0} ** result_link.result_link_bytes;
    _ = try link_session.prepareV1(
        resumed.next_overlap,
        next_transcript,
        resumed.timeline,
        &link_candidate,
        &link_output,
    );
    const next_link = try link_session.commitV1();
    if (resumed.link_state.visible_links != 2 or
        next_link.link_sequence != 1 or
        next_link.link_index != 2 or
        !std.mem.eql(
            u8,
            &next_link.previous_link_sha256,
            &checkpoint.previous_link_sha256,
        ))
        return error.InvalidCrossModalContinuation;

    try link_session.closeAndRelease();
    try terminal.closeAndRelease();
    try resumed.closeAndRelease();
    const final = try bank.snapshotV3();
    if (!final.used.isZero() or
        final.live_allocations != 0 or
        final.active_lease_trees != 0)
        return error.TargetOwnershipLeak;

    const transcript_hex = std.fmt.bytesToHex(
        next_transcript.transcript_sha256,
        .lower,
    );
    const link_hex = std.fmt.bytesToHex(
        next_link.link_sha256,
        .lower,
    );
    const result_hex = std.fmt.bytesToHex(
        terminal_result.result_sha256,
        .lower,
    );
    var stdout_buffer: [1536]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.audio-transcript-live-restart/demo-v1\"," ++
            "\"phase\":\"resume\",\"source_pid\":{d}," ++
            "\"target_pid\":{d},\"process_restart\":true," ++
            "\"restored_segment\":1,\"resumed_segment\":2," ++
            "\"next_publish_start_sample\":10," ++
            "\"next_publish_end_sample\":18," ++
            "\"exact_sample_boundary\":true," ++
            "\"conditioning_context_reused\":true," ++
            "\"duplicate_text_bytes\":0," ++
            "\"visible_results\":2,\"visible_links\":2," ++
            "\"cross_modal_link_sequence\":1," ++
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
            "\"transcript_sha256\":\"{s}\"," ++
            "\"link_sha256\":\"{s}\"," ++
            "\"result_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            source_pid,
            target_pid,
            &transcript_hex,
            &link_hex,
            &result_hex,
        },
    );
    try stdout.flush();
}

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
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
    const read = try file.readAll(
        storage[0..length],
    );
    if (read != length) return error.ShortRead;
    return storage[0..length];
}
