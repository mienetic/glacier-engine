//! Two-process retained-latent checkpoint worker used by the native demo.

const std = @import("std");
const core = @import("core");
const model = core.model_contract;
const resource_bank = core.resource_bank;
const stateful = core.stateful_model_adapter;
const continuation = core.stateful_model_continuation;
const latent = core.latent_step_adapter;

const checkpoint_name = "stateful-model.checkpoint";
const publication_name = "stateful-model.state-publication";
const payload_name = "stateful-model.state-payload";
const source_pid_name = "stateful-model.source-pid";
const source_bank_epoch: u64 = 81_001;
const restore_bank_epoch: u64 = 82_001;

const RuntimeStorage = struct {
    slots: [4]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 4,
    roots: [4]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 4,
    nodes: [8]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 8,
};

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
        try checkpointV1(&directory);
    } else if (std.mem.eql(u8, arguments[1], "resume")) {
        try resumeV1(&directory);
    } else {
        return error.InvalidPhase;
    }
}

fn checkpointV1(directory: *std.fs.Dir) !void {
    var fixture = try latent.makeReferenceFixtureV1();
    var storage: RuntimeStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        source_bank_epoch,
    );
    var context: u8 = 1;
    const adapter = try latent.referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var session: latent.Session = .{};
    try session.initV1(
        &bank,
        81_101,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate_output: [4]u8 = undefined;
    var candidate_state: [4]u8 = undefined;
    var visible_output: [4]u8 = undefined;
    var visible_state: [4]u8 = undefined;
    _ = try session.prepareV1(
        &latent.reference_weights,
        &latent.reference_conditioning,
        &latent.reference_initial_state,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    const result = try session.commitV1();
    const checkpoint = try continuation.makeCheckpointV1(
        source_bank_epoch,
        .{
            .restore_bank_epoch = restore_bank_epoch,
            .restore_owner_key = 82_101,
            .restore_tree_key = 82_201,
            .restore_authority_key = 82_301,
            .tenant_key = 82_401,
            .scope_key = 82_501,
            .allocation_key = 82_601,
            .binding_key = 82_701,
        },
        fixture.model_publication,
        fixture.state_publication,
        result,
    );
    var checkpoint_storage: [continuation.checkpoint_bytes]u8 = undefined;
    const checkpoint_wire =
        try continuation.encodeCheckpointV1(
            checkpoint,
            &checkpoint_storage,
        );
    var publication_storage: [stateful.state_publication_bytes]u8 = undefined;
    const publication_wire =
        try stateful.encodeStatePublicationV1(
            fixture.state_publication,
            &publication_storage,
        );
    try writeSyncedV1(
        directory,
        checkpoint_name,
        checkpoint_wire,
    );
    try writeSyncedV1(
        directory,
        publication_name,
        publication_wire,
    );
    try writeSyncedV1(
        directory,
        payload_name,
        &visible_state,
    );
    var pid_storage: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(
        &pid_storage,
        "{d}",
        .{std.c.getpid()},
    );
    try writeSyncedV1(directory, source_pid_name, pid);
    try std.posix.fsync(directory.fd);
    try session.closeAndRelease();
    if (!(try bank.snapshotV3()).used.isZero())
        return error.SourceOwnershipLeak;

    const checkpoint_hex = std.fmt.bytesToHex(
        checkpoint.checkpoint_sha256,
        .lower,
    );
    var stdout_buffer: [768]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.stateful-model-live-restart/demo-v1\"," ++
            "\"phase\":\"checkpoint\",\"source_pid\":{d}," ++
            "\"committed_steps\":1,\"visible_results\":1," ++
            "\"checkpoint_bytes\":{d},\"state_bytes\":4," ++
            "\"source_ownership_released\":true," ++
            "\"file_sync\":true,\"directory_sync\":true," ++
            "\"checkpoint_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            std.c.getpid(),
            continuation.checkpoint_bytes,
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

    var checkpoint_storage: [continuation.checkpoint_bytes]u8 = undefined;
    const checkpoint_wire = try readExactV1(
        directory,
        checkpoint_name,
        &checkpoint_storage,
    );
    const checkpoint =
        try continuation.decodeCheckpointV1(
            checkpoint_wire,
        );
    var publication_storage: [stateful.state_publication_bytes]u8 = undefined;
    const publication_wire = try readExactV1(
        directory,
        publication_name,
        &publication_storage,
    );
    var payload_storage: [4]u8 = undefined;
    const payload = try readExactV1(
        directory,
        payload_name,
        &payload_storage,
    );

    var storage: RuntimeStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        restore_bank_epoch,
    );
    var resumed: continuation.ResumeSession = .{};
    try resumed.prepareV1(
        &bank,
        checkpoint_wire,
        publication_wire,
    );
    const reserved = try bank.snapshotV3();
    if (reserved.reserved_unmaterialized_allocations != 1 or
        reserved.live_allocations != 0)
        return error.ChargeBeforeMaterializeMissing;
    var restored_state: [4]u8 = undefined;
    try resumed.commitMaterializedV1(
        payload,
        &restored_state,
    );
    const active = try bank.snapshotV3();
    if (active.reserved_unmaterialized_allocations != 0 or
        active.live_allocations != 1)
        return error.InvalidRestoredOwnership;

    const fixture = try latent.makeReferenceFixtureV1();
    const second_plan = try latent.makeReferencePlanV1(
        fixture.manifest,
        resumed.model_publication,
        resumed.state_publication,
        checkpoint.last_plan_sha256,
    );
    var context: u8 = 1;
    const adapter = try latent.referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var terminal: latent.Session = .{};
    try terminal.initV1(
        &bank,
        83_001,
        &resumed.model_publication,
        &resumed.state_publication,
        fixture.manifest,
        second_plan,
        adapter,
    );
    var candidate_output: [4]u8 = undefined;
    var candidate_state: [4]u8 = undefined;
    var final_output: [4]u8 = undefined;
    var final_state: [4]u8 = undefined;
    _ = try terminal.prepareV1(
        &latent.reference_weights,
        &latent.reference_conditioning,
        &restored_state,
        &candidate_output,
        &candidate_state,
        &final_output,
        &final_state,
    );
    const terminal_result = try terminal.commitV1();
    if (!std.mem.eql(
        u8,
        &final_output,
        &[_]u8{ 6, 12, 18, 24 },
    ) or
        resumed.model_publication.visible_results != 2 or
        resumed.model_publication.next_sequence != 2 or
        resumed.state_publication.current_step != 2 or
        resumed.state_publication.current_step !=
            resumed.state_publication.total_steps or
        !std.mem.eql(
            u8,
            &resumed.state_publication.previous_result_sha256,
            &terminal_result.result_sha256,
        ))
        return error.InvalidTerminalPublication;
    try resumed.closeAndRelease();
    try terminal.closeAndRelease();
    const final = try bank.snapshotV3();
    if (!final.used.isZero() or
        final.live_allocations != 0 or
        final.active_lease_trees != 0)
        return error.TargetOwnershipLeak;

    const output_hex = std.fmt.bytesToHex(
        model.sha256(&final_output),
        .lower,
    );
    const result_hex = std.fmt.bytesToHex(
        terminal_result.result_sha256,
        .lower,
    );
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.stateful-model-live-restart/demo-v1\"," ++
            "\"phase\":\"resume\",\"source_pid\":{d}," ++
            "\"target_pid\":{d},\"process_restart\":true," ++
            "\"restored_step\":1,\"terminal_step\":2," ++
            "\"visible_results\":2,\"duplicate_publications\":0," ++
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
            "\"output_sha256\":\"{s}\"," ++
            "\"result_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            source_pid,
            target_pid,
            &output_hex,
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
    if (read != length) return error.ShortRead;
    return storage[0..length];
}
