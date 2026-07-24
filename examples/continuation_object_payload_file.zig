//! Durable payload copy-on-write promotion and process-death conformance.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const fixture_api = @import("sweep_fixture");
const capsule = core.continuation_capsule;
const bundle = core.continuation_bundle;
const object_store = core.continuation_object_store;
const payload_store = core.continuation_object_payload_store;
const payload_file = core.continuation_object_payload_file;
const sweep_file = core.continuation_object_sweep_file;
const sweep_record = core.continuation_object_sweep_record;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 2) return error.MissingWorkerPath;
    const worker_path = arguments[1];
    const tenant = [_]u8{0x6d} ** 32;
    const payloads = [_][]const u8{
        "payload-alpha",
        "payload-beta-beta",
        "payload-gamma-gamma-gamma",
    };
    var entries: [payloads.len]payload_store.EntryInputV1 = undefined;
    for (payloads, 0..) |payload, index| {
        entries[index] = .{
            .reference = try bundle.blobRefV1(tenant, payload),
            .payload = payload,
        };
    }
    payload_store.sortEntriesV1(&entries);
    var initial_storage: [512]u8 = undefined;
    const initial = try payload_store.encodeSnapshotV1(
        tenant,
        &entries,
        &initial_storage,
    );
    var targets = [_]bundle.BlobRefV1{entries[1].reference};
    object_store.sortRootReferencesV1(&targets);
    const sweep_bytes = try fixture_api.payloadRecordV1(
        tenant,
        targets[0],
        entries.len,
        55,
    );
    const sweep_decoded = try sweep_record.decodeV1(&sweep_bytes);
    const prepared_sweep: sweep_file.PreparedCommitRecordV1 = .{
        .bytes = sweep_bytes,
        .record_sha256 = sweep_decoded.record_sha256,
    };
    const sweep_preview = try sweep_file.commitPreviewFromRecordV1(
        prepared_sweep,
        &targets,
    );
    const anchor = fixture_api.originAnchorV1();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const tenant_hex = std.fmt.bytesToHex(tenant, .lower);

    var process_deaths: usize = 0;
    var recovery_applied: usize = 0;
    var recovery_already_applied: usize = 0;
    var first_reclaim_record_sha256 = capsule.zero_digest;
    for ([_]payload_file.IoPhaseV1{
        .plan_write,
        .plan_sync,
        .plan_directory_sync,
        .candidate_write,
        .candidate_sync,
        .promote_rename,
        .directory_sync,
    }, 0..) |phase, index| {
        var directory_name_storage: [64]u8 = undefined;
        const directory_name = try std.fmt.bufPrint(
            &directory_name_storage,
            "payload-death-{d}",
            .{index},
        );
        try temporary.dir.makeDir(directory_name);
        var directory = try temporary.dir.openDir(directory_name, .{});
        defer directory.close();
        const sweep_output = try directory.createFile(
            "sweep.records",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        try sweep_output.writeAll(&sweep_bytes);
        try sweep_output.sync();
        sweep_output.close();
        try std.posix.fsync(directory.fd);

        const storage_epoch = 1000 + index;
        var lock_storage: [1]u8 = undefined;
        var active_storage: [512]u8 = undefined;
        var lease = try payload_file.LeaseV1.create(
            directory,
            storage_epoch,
            tenant,
            initial,
            active_storage.len,
            &lock_storage,
            &active_storage,
        );
        var candidate_storage: [512]u8 = undefined;
        const prepared_reclaim =
            try payload_file.prepareFromPublishedSweepV1(
                lease.stream(),
                tenant,
                sweep_preview,
                prepared_sweep,
                &sweep_bytes,
                anchor,
                .{
                    .storage_epoch = storage_epoch,
                    .challenge_sha256 = [_]u8{
                        @intCast(0xa0 + index),
                    } ** 32,
                },
                &candidate_storage,
            );
        if (index == 0)
            first_reclaim_record_sha256 =
                prepared_reclaim.record.record_sha256;
        const reclaim_candidate = try directory.createFile(
            "reclaim.candidate",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        try reclaim_candidate.writeAll(&prepared_reclaim.record.bytes);
        try reclaim_candidate.sync();
        reclaim_candidate.close();
        try std.posix.fsync(directory.fd);
        const is_plan_phase = switch (phase) {
            .plan_write, .plan_sync, .plan_directory_sync => true,
            else => false,
        };
        if (!is_plan_phase)
            try payload_file.publishReclaimRecordV1(
                &lease,
                prepared_reclaim.record,
            );
        lease.close();

        var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
        const absolute_directory = try directory.realpath(
            ".",
            &absolute_storage,
        );
        var epoch_storage: [32]u8 = undefined;
        const epoch_text = try std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{storage_epoch},
        );
        var max_storage: [32]u8 = undefined;
        const max_text = try std.fmt.bufPrint(
            &max_storage,
            "{d}",
            .{active_storage.len},
        );
        try expectKilled(allocator, &.{
            worker_path,
            absolute_directory,
            epoch_text,
            max_text,
            &tenant_hex,
            "sweep.records",
            "reclaim.candidate",
            @tagName(phase),
        });
        process_deaths += 1;

        var reopened_lock_storage: [1]u8 = undefined;
        var reopened_active_storage: [512]u8 = undefined;
        var reopened = try payload_file.LeaseV1.open(
            directory,
            storage_epoch,
            tenant,
            reopened_active_storage.len,
            &reopened_lock_storage,
            &reopened_active_storage,
        );
        var recovery_candidate_storage: [512]u8 = undefined;
        try payload_file.publishReclaimRecordV1(
            &reopened,
            prepared_reclaim.record,
        );
        const recovered = try payload_file.recoverFromPublishedFilesV1(
            &reopened,
            prepared_sweep,
            &sweep_bytes,
            anchor,
            prepared_reclaim.record,
            &recovery_candidate_storage,
            null,
        );
        switch (recovered.disposition) {
            .applied => recovery_applied += 1,
            .already_applied => recovery_already_applied += 1,
        }
        const repeated = try payload_file.recoverFromPublishedFilesV1(
            &reopened,
            prepared_sweep,
            &sweep_bytes,
            anchor,
            prepared_reclaim.record,
            &recovery_candidate_storage,
            null,
        );
        if (repeated.disposition != .already_applied or
            !std.mem.eql(
                u8,
                &repeated.active_snapshot.snapshot_sha256,
                &prepared_reclaim.preview.after.snapshot_sha256,
            ))
            return error.RecoveryMismatch;
        reopened.close();
    }

    const sweep_record_hex = std.fmt.bytesToHex(
        prepared_sweep.record_sha256,
        .lower,
    );
    const reclaim_record_hex = std.fmt.bytesToHex(
        first_reclaim_record_sha256,
        .lower,
    );
    if (!std.mem.eql(
        u8,
        &sweep_record_hex,
        "871e9f220c7435070578bde3731bc7f30" ++
            "befa532cfa29b981292304a2a7cc977",
    ) or !std.mem.eql(
        u8,
        &reclaim_record_hex,
        "f1105b7058cc90e1ad9ec9ba09abfe78" ++
            "e34b6cbbebb014cf6b372b35f926de34",
    )) return error.GoldenRecordMismatch;
    std.debug.print(
        "{{\"schema\":\"glacier.continuation-object-payload-file/demo-v1\"," ++
            "\"payload_entries_before\":3," ++
            "\"payload_entries_after\":2," ++
            "\"payload_bytes_before\":55," ++
            "\"payload_bytes_after\":{d}," ++
            "\"reclaim_record_bytes\":{d}," ++
            "\"process_deaths\":{d}," ++
            "\"plan_publication_deaths\":3," ++
            "\"payload_promotion_deaths\":4," ++
            "\"old_snapshot_recoveries\":{d}," ++
            "\"new_snapshot_recoveries\":{d}," ++
            "\"plan_write_boundary\":true," ++
            "\"plan_sync_boundary\":true," ++
            "\"plan_directory_sync_boundary\":true," ++
            "\"candidate_write_boundary\":true," ++
            "\"candidate_sync_boundary\":true," ++
            "\"atomic_rename_boundary\":true," ++
            "\"directory_sync_boundary\":true," ++
            "\"stable_lock_inode\":true," ++
            "\"descriptor_relative\":true," ++
            "\"published_sweep_bound\":true," ++
            "\"exact_targets_reconstructed\":true," ++
            "\"recovery_idempotent\":true," ++
            "\"payload_store_durable\":true," ++
            "\"power_loss_emulated\":false," ++
            "\"sweep_record_sha256\":\"{s}\"," ++
            "\"reclaim_record_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{
            55 - targets[0].byte_length,
            payload_file.reclaim_record_bytes,
            process_deaths,
            recovery_applied,
            recovery_already_applied,
            &sweep_record_hex,
            &reclaim_record_hex,
        },
    );
}

fn expectKilled(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = arguments,
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!wasForceTerminated(result.term))
        return error.UnexpectedWorkerTermination;
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
