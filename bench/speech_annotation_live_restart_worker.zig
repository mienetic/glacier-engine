//! Two-process word-timing and speaker-attribution publication worker.

const std = @import("std");
const core = @import("core");
const model = core.model_contract;
const resource_bank = core.resource_bank;
const audio = core.audio_transcript_adapter;
const annotation = core.speech_annotation_publication;

const state_name = "speech-annotation.state";
const result_name = "speech-annotation.first-result";
const transcript_name = "speech-annotation.first-transcript";
const source_pid_name = "speech-annotation.source-pid";

const RuntimeStorage = struct {
    slots: [8]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 8,
    roots: [8]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8,
    nodes: [12]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 12,
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
    const fixture = try annotation.makeReferenceFixtureV1();
    var state = fixture.initial_state;
    var storage: RuntimeStorage = .{};
    var bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &storage.slots,
            &storage.roots,
            &storage.nodes,
            .{},
            131_001,
        );
    const plan = try annotation.makePlanV1(
        state,
        fixture.first_overlap,
        fixture.first_transcript,
    );
    var session: annotation.Session = .{};
    try session.initV1(
        &bank,
        131_101,
        &state,
        plan,
        fixture.first_overlap,
        fixture.first_transcript,
    );
    var candidate: [annotation.result_bytes]u8 = undefined;
    var visible =
        [_]u8{0} ** annotation.result_bytes;
    _ = try session.prepareV1(
        &fixture.first_words,
        &fixture.first_speakers,
        &candidate,
        &visible,
    );
    const result = try session.commitV1();
    try session.closeAndRelease();
    const final = try bank.snapshotV3();
    if (!final.used.isZero() or
        final.live_allocations != 0 or
        final.active_lease_trees != 0)
        return error.SourceOwnershipLeak;
    var state_wire: [annotation.state_bytes]u8 =
        undefined;
    _ = try annotation.encodeStateV1(
        state,
        &state_wire,
    );
    var result_wire: [annotation.result_bytes]u8 =
        undefined;
    _ = try annotation.encodeResultV1(
        result,
        &result_wire,
    );
    var transcript_wire: [audio.transcript_segment_bytes]u8 =
        undefined;
    _ = try audio.encodeTranscriptSegmentV1(
        fixture.first_transcript,
        &transcript_wire,
    );
    try writeSyncedV1(directory, state_name, &state_wire);
    try writeSyncedV1(directory, result_name, &result_wire);
    try writeSyncedV1(
        directory,
        transcript_name,
        &transcript_wire,
    );
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
    const result_hex = std.fmt.bytesToHex(
        result.result_sha256,
        .lower,
    );
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.speech-annotation-live-restart/demo-v1\"," ++
            "\"phase\":\"checkpoint\",\"source_pid\":{d}," ++
            "\"visible_annotations\":1,\"visible_words\":1," ++
            "\"visible_speaker_turns\":1,\"next_sample\":10," ++
            "\"state_bytes\":{d},\"result_bytes\":{d}," ++
            "\"source_ownership_released\":true," ++
            "\"file_sync\":true,\"directory_sync\":true," ++
            "\"result_sha256\":\"{s}\",\"verified\":true}}\n",
        .{
            std.c.getpid(),
            annotation.state_bytes,
            annotation.result_bytes,
            &result_hex,
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
    var state_wire: [annotation.state_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        state_name,
        &state_wire,
    );
    var state = try annotation.decodeStateV1(
        &state_wire,
    );
    var result_wire: [annotation.result_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        result_name,
        &result_wire,
    );
    const first_result =
        try annotation.decodeResultV1(
            &result_wire,
        );
    var transcript_wire: [audio.transcript_segment_bytes]u8 =
        undefined;
    _ = try readExactV1(
        directory,
        transcript_name,
        &transcript_wire,
    );
    const first_transcript =
        try audio.decodeTranscriptSegmentV1(
            &transcript_wire,
        );
    const fixture = try annotation.makeReferenceFixtureV1();
    if (!std.meta.eql(
        first_transcript,
        fixture.first_transcript,
    ) or
        !std.mem.eql(
            u8,
            &state.previous_result_sha256,
            &first_result.result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state.last_transcript_sha256,
            &first_transcript.transcript_sha256,
        ))
        return error.InvalidRestoredAnnotationState;
    var storage: RuntimeStorage = .{};
    var bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &storage.slots,
            &storage.roots,
            &storage.nodes,
            .{},
            132_001,
        );
    const before_admission = try bank.snapshotV3();
    if (!before_admission.used.isZero())
        return error.AdmissionBeforeStateValidation;
    const plan = try annotation.makePlanV1(
        state,
        fixture.second_overlap,
        fixture.second_transcript,
    );
    var session: annotation.Session = .{};
    try session.initV1(
        &bank,
        132_101,
        &state,
        plan,
        fixture.second_overlap,
        fixture.second_transcript,
    );
    var candidate: [annotation.result_bytes]u8 = undefined;
    var visible =
        [_]u8{0xa5} ** annotation.result_bytes;
    _ = try session.prepareV1(
        &fixture.second_words,
        &fixture.second_speakers,
        &candidate,
        &visible,
    );
    if (!std.mem.allEqual(u8, &visible, 0xa5) or
        state.visible_annotations != 1)
        return error.VisibilityAdvancedBeforeCommit;
    try session.abortV1();
    if (!std.mem.allEqual(u8, &candidate, 0) or
        !std.mem.allEqual(u8, &visible, 0xa5) or
        state.visible_annotations != 1)
        return error.CancelledAnnotationBecameVisible;
    _ = try session.prepareV1(
        &fixture.second_words,
        &fixture.second_speakers,
        &candidate,
        &visible,
    );
    const second_result = try session.commitV1();
    const visible_result =
        try annotation.decodeResultV1(&visible);
    if (!std.meta.eql(second_result, visible_result) or
        state.visible_annotations != 2 or
        state.visible_words != 2 or
        state.visible_speaker_turns != 2 or
        state.next_sample != 18)
        return error.InvalidAnnotationContinuation;
    try session.closeAndRelease();
    const final = try bank.snapshotV3();
    if (!final.used.isZero() or
        final.live_allocations != 0 or
        final.active_lease_trees != 0)
        return error.TargetOwnershipLeak;
    const first_speaker_hex = std.fmt.bytesToHex(
        fixture.first_speakers[0],
        .lower,
    );
    const second_speaker_hex = std.fmt.bytesToHex(
        fixture.second_speakers[0],
        .lower,
    );
    const result_hex = std.fmt.bytesToHex(
        second_result.result_sha256,
        .lower,
    );
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.speech-annotation-live-restart/demo-v1\"," ++
            "\"phase\":\"resume\",\"source_pid\":{d}," ++
            "\"target_pid\":{d},\"process_restart\":true," ++
            "\"first_word\":\"ice\",\"first_start_sample\":2," ++
            "\"first_end_sample\":10,\"second_word\":\"berg\"," ++
            "\"second_start_sample\":10,\"second_end_sample\":18," ++
            "\"sample_rate\":1000,\"visible_annotations\":2," ++
            "\"visible_words\":2,\"visible_speaker_turns\":2," ++
            "\"duplicate_words\":0,\"cancelled_publications\":1," ++
            "\"cancellation_preserved_visibility\":true," ++
            "\"state_validated_before_admission\":true," ++
            "\"atomic_visibility\":true,\"final_bank_host_bytes\":0," ++
            "\"final_live_allocations\":0," ++
            "\"final_active_lease_trees\":0," ++
            "\"filesystem_authority\":true," ++
            "\"network_authority\":false,\"device_authority\":false," ++
            "\"microphone_authority\":false,\"playback_authority\":false," ++
            "\"production_model\":false," ++
            "\"first_speaker_sha256\":\"{s}\"," ++
            "\"second_speaker_sha256\":\"{s}\"," ++
            "\"result_sha256\":\"{s}\",\"verified\":true}}\n",
        .{
            source_pid,
            target_pid,
            &first_speaker_hex,
            &second_speaker_hex,
            &result_hex,
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
    if (read != length)
        return error.ShortRead;
    return storage[0..length];
}
