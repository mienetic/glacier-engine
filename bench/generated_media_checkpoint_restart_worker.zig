//! Crash-boundary worker for generated-media checkpoint selection.

const std = @import("std");
const core = @import("core");
const generated = core.generated_media_checkpoint;

const active_selector_name = ".glacier-generated-media-active-v1";
const candidate_selector_name = ".glacier-generated-media-candidate-v1";
const source_pid_name = "generated-media-source-pid";

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len < 3)
        return error.InvalidArguments;
    var directory = try std.fs.openDirAbsolute(arguments[2], .{});
    defer directory.close();
    if (std.mem.eql(u8, arguments[1], "source")) {
        if (arguments.len != 3)
            return error.InvalidArguments;
        try writeSourceV1(&directory);
    } else if (std.mem.eql(u8, arguments[1], "promote")) {
        if (arguments.len != 4)
            return error.InvalidArguments;
        const phase = try std.fmt.parseInt(u64, arguments[3], 10);
        try promoteV1(&directory, phase);
    } else if (std.mem.eql(u8, arguments[1], "recover")) {
        if (arguments.len != 4)
            return error.InvalidArguments;
        const expected = try std.fmt.parseInt(u64, arguments[3], 10);
        try recoverV1(&directory, expected);
    } else {
        return error.InvalidArguments;
    }
}

fn writeSourceV1(directory: *std.fs.Dir) !void {
    const fixture = try generated.referenceFixtureV1();
    try writeMemberV1(directory, "image", 1, fixture.image1);
    try writeMemberV1(directory, "audio", 1, fixture.audio1);
    try writeMemberV1(directory, "video", 1, fixture.video1);
    try writeMemberV1(directory, "image", 2, fixture.image2);
    try writeMemberV1(directory, "audio", 2, fixture.audio2);
    try writeMemberV1(directory, "video", 2, fixture.video2);
    try writeCheckpointV1(directory, 1, fixture.checkpoint1);
    try writeCheckpointV1(directory, 2, fixture.checkpoint2);
    try writeSelectorV1(
        directory,
        selectorNameV1(1),
        fixture.selector1,
    );
    try writeSelectorV1(
        directory,
        selectorNameV1(2),
        fixture.selector2,
    );
    try writeSelectorV1(
        directory,
        active_selector_name,
        fixture.selector1,
    );
    var pid_storage: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(
        &pid_storage,
        "{d}",
        .{std.c.getpid()},
    );
    try writeSyncedV1(directory, source_pid_name, pid);
    try std.posix.fsync(directory.fd);
    try printSourceEvidenceV1();
}

fn promoteV1(directory: *std.fs.Dir, phase: u64) !void {
    if (phase == 0 or phase > 4)
        return error.InvalidPhase;
    _ = try validateSelectedGenerationV1(directory, 1);
    const fixture = try generated.referenceFixtureV1();
    var selector_storage: [generated.selector_bytes]u8 = undefined;
    const selector_wire = try generated.encodeSelectorV1(
        fixture.selector2,
        &selector_storage,
    );
    var candidate = try directory.createFile(
        candidate_selector_name,
        .{ .read = true, .truncate = true },
    );
    defer candidate.close();
    try candidate.writeAll(selector_wire);
    if (phase == 1) killSelfV1();
    try candidate.sync();
    if (phase == 2) killSelfV1();
    try directory.rename(
        candidate_selector_name,
        active_selector_name,
    );
    if (phase == 3) killSelfV1();
    try std.posix.fsync(directory.fd);
    if (phase == 4) killSelfV1();
    return error.MissingInjectedDeath;
}

fn recoverV1(directory: *std.fs.Dir, expected: u64) !void {
    if (expected != 1 and expected != 2)
        return error.InvalidExpectedGeneration;
    var pid_storage: [32]u8 = undefined;
    const source_pid_wire = try readBoundedV1(
        directory,
        source_pid_name,
        &pid_storage,
    );
    const source_pid = try std.fmt.parseInt(i32, source_pid_wire, 10);
    const recovery_pid = std.c.getpid();
    if (source_pid == recovery_pid)
        return error.ProcessDidNotRestart;
    const selector = try validateSelectedGenerationV1(
        directory,
        expected,
    );
    const fixture = try generated.referenceFixtureV1();
    const expected_selector = if (expected == 1)
        fixture.selector1
    else
        fixture.selector2;
    if (!std.meta.eql(selector, expected_selector))
        return error.ForeignSelectedGeneration;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.generated-media-checkpoint-restart/" ++
            "worker-v1\",\"phase\":\"recover\",\"source_pid\":{d}," ++
            "\"recovery_pid\":{d},\"process_restart\":true," ++
            "\"generation\":{d},\"complete_members\":3," ++
            "\"mixed_generation\":false,\"verified\":true}}\n",
        .{ source_pid, recovery_pid, expected },
    );
    try stdout.flush();
}

fn validateSelectedGenerationV1(
    directory: *std.fs.Dir,
    generation: u64,
) !generated.GeneratedMediaSelectorV1 {
    var selector_storage: [generated.selector_bytes]u8 = undefined;
    const selector_wire = try readExactV1(
        directory,
        active_selector_name,
        &selector_storage,
    );
    const selector = try generated.decodeSelectorV1(selector_wire);
    if (selector.generation != generation)
        return error.UnexpectedGeneration;
    var checkpoint_storage: [generated.checkpoint_bytes]u8 = undefined;
    const checkpoint_wire = try readExactV1(
        directory,
        checkpointNameV1(generation),
        &checkpoint_storage,
    );
    const checkpoint = try generated.decodeCheckpointV1(
        checkpoint_wire,
    );
    var image_storage: [generated.member_bytes]u8 = undefined;
    var audio_storage: [generated.member_bytes]u8 = undefined;
    var video_storage: [generated.member_bytes]u8 = undefined;
    const image_member = try generated.decodeMemberV1(
        try readExactV1(
            directory,
            memberNameV1("image", generation),
            &image_storage,
        ),
    );
    const audio_member = try generated.decodeMemberV1(
        try readExactV1(
            directory,
            memberNameV1("audio", generation),
            &audio_storage,
        ),
    );
    const video_member = try generated.decodeMemberV1(
        try readExactV1(
            directory,
            memberNameV1("video", generation),
            &video_storage,
        ),
    );
    const fixture = try generated.referenceFixtureV1();
    if (generation == 1) {
        try generated.validateCheckpointBindingsV1(
            null,
            image_member,
            audio_member,
            video_member,
            checkpoint,
        );
        try generated.validateSelectorBindingsV1(
            null,
            checkpoint,
            selector,
        );
    } else {
        var previous_checkpoint_storage: [generated.checkpoint_bytes]u8 = undefined;
        const previous_checkpoint = try generated.decodeCheckpointV1(
            try readExactV1(
                directory,
                checkpointNameV1(1),
                &previous_checkpoint_storage,
            ),
        );
        var previous_selector_storage: [generated.selector_bytes]u8 = undefined;
        const previous_selector = try generated.decodeSelectorV1(
            try readExactV1(
                directory,
                selectorNameV1(1),
                &previous_selector_storage,
            ),
        );
        try generated.validateCheckpointBindingsV1(
            previous_checkpoint,
            image_member,
            audio_member,
            video_member,
            checkpoint,
        );
        try generated.validateSelectorBindingsV1(
            previous_selector,
            checkpoint,
            selector,
        );
    }
    const expected_checkpoint = if (generation == 1)
        fixture.checkpoint1
    else
        fixture.checkpoint2;
    if (!std.meta.eql(checkpoint, expected_checkpoint) or
        !std.mem.eql(
            u8,
            &selector.checkpoint_sha256,
            &checkpoint.checkpoint_sha256,
        ) or
        !std.mem.eql(
            u8,
            &selector.image_member_sha256,
            &image_member.member_sha256,
        ) or
        !std.mem.eql(
            u8,
            &selector.audio_member_sha256,
            &audio_member.member_sha256,
        ) or
        !std.mem.eql(
            u8,
            &selector.video_member_sha256,
            &video_member.member_sha256,
        ))
        return error.InvalidSelectedBindings;
    return selector;
}

fn writeMemberV1(
    directory: *std.fs.Dir,
    modality: []const u8,
    generation: u64,
    member: generated.GeneratedMediaMemberV1,
) !void {
    var storage: [generated.member_bytes]u8 = undefined;
    const wire = try generated.encodeMemberV1(member, &storage);
    try writeSyncedV1(
        directory,
        memberNameV1(modality, generation),
        wire,
    );
}

fn writeCheckpointV1(
    directory: *std.fs.Dir,
    generation: u64,
    checkpoint: generated.GeneratedMediaCheckpointV1,
) !void {
    var storage: [generated.checkpoint_bytes]u8 = undefined;
    const wire = try generated.encodeCheckpointV1(checkpoint, &storage);
    try writeSyncedV1(
        directory,
        checkpointNameV1(generation),
        wire,
    );
}

fn writeSelectorV1(
    directory: *std.fs.Dir,
    name: []const u8,
    selector: generated.GeneratedMediaSelectorV1,
) !void {
    var storage: [generated.selector_bytes]u8 = undefined;
    const wire = try generated.encodeSelectorV1(selector, &storage);
    try writeSyncedV1(directory, name, wire);
}

fn writeSyncedV1(
    directory: *std.fs.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    var file = try directory.createFile(
        name,
        .{ .read = true, .truncate = true },
    );
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

fn readExactV1(
    directory: *std.fs.Dir,
    name: []const u8,
    storage: []u8,
) ![]const u8 {
    var file = try directory.openFile(name, .{});
    defer file.close();
    const count = try file.readAll(storage);
    if (count != storage.len)
        return error.InvalidFileLength;
    var extra: [1]u8 = undefined;
    if (try file.read(&extra) != 0)
        return error.InvalidFileLength;
    return storage;
}

fn readBoundedV1(
    directory: *std.fs.Dir,
    name: []const u8,
    storage: []u8,
) ![]const u8 {
    var file = try directory.openFile(name, .{});
    defer file.close();
    const count = try file.readAll(storage);
    if (count == 0 or count == storage.len)
        return error.InvalidFileLength;
    return storage[0..count];
}

fn memberNameV1(
    modality: []const u8,
    generation: u64,
) []const u8 {
    if (generation == 1) {
        if (std.mem.eql(u8, modality, "image"))
            return "generated-media-image-1.member";
        if (std.mem.eql(u8, modality, "audio"))
            return "generated-media-audio-1.member";
        return "generated-media-video-1.member";
    }
    if (std.mem.eql(u8, modality, "image"))
        return "generated-media-image-2.member";
    if (std.mem.eql(u8, modality, "audio"))
        return "generated-media-audio-2.member";
    return "generated-media-video-2.member";
}

fn checkpointNameV1(generation: u64) []const u8 {
    return if (generation == 1)
        "generated-media-checkpoint-1"
    else
        "generated-media-checkpoint-2";
}

fn selectorNameV1(generation: u64) []const u8 {
    return if (generation == 1)
        "generated-media-selector-1"
    else
        "generated-media-selector-2";
}

fn killSelfV1() noreturn {
    std.posix.raise(std.posix.SIG.KILL) catch
        std.process.exit(97);
    unreachable;
}

fn printSourceEvidenceV1() !void {
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.generated-media-checkpoint-restart/" ++
            "worker-v1\",\"phase\":\"source\",\"source_pid\":{d}," ++
            "\"prepared_generations\":2,\"active_generation\":1," ++
            "\"immutable_objects_synced\":true," ++
            "\"directory_synced\":true,\"verified\":true}}\n",
        .{std.c.getpid()},
    );
    try stdout.flush();
}
