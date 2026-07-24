//! Atomic whole-checkpoint root switch and process-death conformance.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const engine = @import("engine");
const capsule = core.continuation_capsule;
const checkpoint_file = core.continuation_checkpoint_file;
const ownership = core.continuation_ownership_manifest;
const payload_store = core.continuation_object_payload_store;
const live = engine.continuation_live_restart;
const paged_restore = engine.continuation_paged_kv_restore;

const request_epoch: u64 = 71;
const challenge_sha256 = [_]u8{0x72} ** 32;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 3) return error.MissingWorkerPath;
    const crash_worker = arguments[1];
    const live_worker = arguments[2];
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var process_deaths: usize = 0;
    var recovery_applied: usize = 0;
    var recovery_already_applied: usize = 0;
    var resume_processes: usize = 0;
    var first_checkpoint_sha256 = capsule.zero_digest;
    var first_selector_sha256 = capsule.zero_digest;
    var checkpoint_bytes: usize = 0;

    for ([_]checkpoint_file.IoPhaseV1{
        .archive_write,
        .archive_sync,
        .archive_directory_sync,
        .selector_write,
        .selector_sync,
        .selector_rename,
        .selector_directory_sync,
    }, 0..) |phase, index| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const phase_allocator = arena.allocator();
        var directory_name_storage: [64]u8 = undefined;
        const directory_name = try std.fmt.bufPrint(
            &directory_name_storage,
            "checkpoint-death-{d}",
            .{index},
        );
        try temporary.dir.makeDir(directory_name);
        var directory = try temporary.dir.openDir(directory_name, .{});
        defer directory.close();
        var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
        const absolute_directory = try directory.realpath(
            ".",
            &absolute_storage,
        );
        const source = try runChildV1(
            phase_allocator,
            &.{ live_worker, "checkpoint", absolute_directory },
        );
        if (std.mem.indexOf(
            u8,
            source,
            "\"verified\":true",
        ) == null) return error.InvalidSourceEvidence;

        const capsule_wire = try directory.readFileAlloc(
            phase_allocator,
            "capsule.bin",
            capsule.encoded_bytes,
        );
        const manifest_wire = try directory.readFileAlloc(
            phase_allocator,
            "manifest.bin",
            ownership.encoded_bytes,
        );
        const payload_wire = try directory.readFileAlloc(
            phase_allocator,
            "payload.bin",
            2048,
        );
        const page_zero = try directory.readFileAlloc(
            phase_allocator,
            "page-0.bin",
            512,
        );
        const page_one = try directory.readFileAlloc(
            phase_allocator,
            "page-1.bin",
            512,
        );
        const runtime_wire = try directory.readFileAlloc(
            phase_allocator,
            "runtime.bin",
            live.runtime_state_bytes,
        );
        const source_pid = try directory.readFileAlloc(
            phase_allocator,
            "source.pid",
            32,
        );

        const first_objects = [_]checkpoint_file.ObjectInputV1{.{
            .kind = .extension,
            .ordinal = 0,
            .abi_version = 1,
            .bytes = "prior-checkpoint",
        }};
        var first_storage: [1024]u8 = undefined;
        const first_set = try checkpoint_file.encodeSetV1(.{
            .generation = 1,
            .request_epoch = request_epoch,
            .publication_next_sequence = 17,
            .parent_checkpoint_sha256 = capsule.zero_digest,
            .challenge_sha256 = challenge_sha256,
        }, &first_objects, &first_storage);
        const first_selector =
            try checkpoint_file.prepareInitialSelectorV1(first_set);
        const next_objects = [_]checkpoint_file.ObjectInputV1{
            .{
                .kind = .capsule,
                .ordinal = 0,
                .abi_version = capsule.wire_abi,
                .bytes = capsule_wire,
            },
            .{
                .kind = .ownership_manifest,
                .ordinal = 0,
                .abi_version = ownership.abi_version,
                .bytes = manifest_wire,
            },
            .{
                .kind = .payload_snapshot,
                .ordinal = 0,
                .abi_version = payload_store.schema_version,
                .bytes = payload_wire,
            },
            .{
                .kind = .kv_page,
                .ordinal = 0,
                .abi_version = paged_restore.page_image_abi,
                .bytes = page_zero,
            },
            .{
                .kind = .kv_page,
                .ordinal = 1,
                .abi_version = paged_restore.page_image_abi,
                .bytes = page_one,
            },
            .{
                .kind = .runtime_state,
                .ordinal = 0,
                .abi_version = live.runtime_state_abi,
                .bytes = runtime_wire,
            },
            .{
                .kind = .source_process,
                .ordinal = 0,
                .abi_version = 1,
                .bytes = source_pid,
            },
        };
        var next_storage: [8192]u8 = undefined;
        const next_set = try checkpoint_file.encodeSetV1(.{
            .generation = 2,
            .request_epoch = request_epoch,
            .publication_next_sequence = 18,
            .parent_checkpoint_sha256 = first_set.checkpoint_sha256,
            .challenge_sha256 = challenge_sha256,
        }, &next_objects, &next_storage);
        checkpoint_bytes = next_set.bytes.len;
        const publication_file = try directory.createFile(
            "publication.set",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        try publication_file.writeAll(next_set.bytes);
        try publication_file.sync();
        publication_file.close();
        try std.posix.fsync(directory.fd);

        const storage_epoch = 9200 + index;
        var lock_storage: [1]u8 = undefined;
        var active_storage: [8192]u8 = undefined;
        var lease = try checkpoint_file.LeaseV1.create(
            directory,
            storage_epoch,
            challenge_sha256,
            first_set,
            first_selector,
            active_storage.len,
            &lock_storage,
            &active_storage,
        );
        const prepared = try checkpoint_file.preparePublicationV1(
            &lease,
            next_set,
        );
        if (index == 0) {
            first_checkpoint_sha256 = next_set.checkpoint_sha256;
            first_selector_sha256 = prepared.selector.selector_sha256;
        }
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
        });
        process_deaths += 1;

        var reopened_lock: [1]u8 = undefined;
        var reopened_storage: [8192]u8 = undefined;
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
            .applied => recovery_applied += 1,
            .already_applied => recovery_already_applied += 1,
        }
        const repeated = try checkpoint_file.recoverV1(
            &reopened,
            prepared,
        );
        if (repeated.disposition != .already_applied)
            return error.NonIdempotentRecovery;
        const active_set = try reopened.activeSet();
        if (active_set.object_count != next_objects.len or
            !std.mem.eql(
                u8,
                &active_set.checkpoint_sha256,
                &next_set.checkpoint_sha256,
            ))
            return error.ActiveCheckpointMismatch;
        reopened.close();

        const resumed = try runChildV1(
            phase_allocator,
            &.{
                live_worker,
                "resume-set",
                absolute_directory,
                epoch_text,
            },
        );
        inline for (.{
            "\"process_restart\":true",
            "\"output_tokens\":[501,502,503,504]",
            "\"duplicate_output_tokens\":0",
            "\"final_bank_host_bytes\":0",
            "\"verified\":true",
        }) |required| {
            if (std.mem.indexOf(u8, resumed, required) == null)
                return error.InvalidResumeEvidence;
        }
        resume_processes += 1;
    }

    if (process_deaths != 7 or recovery_applied != 5 or
        recovery_already_applied != 2 or resume_processes != 7)
        return error.InvalidPhaseAccounting;
    const checkpoint_hex = std.fmt.bytesToHex(
        first_checkpoint_sha256,
        .lower,
    );
    const selector_hex = std.fmt.bytesToHex(
        first_selector_sha256,
        .lower,
    );
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-checkpoint-file/demo-v1\"," ++
            "\"checkpoint_bytes\":{d},\"checkpoint_objects\":7," ++
            "\"process_deaths\":7,\"archive_phase_deaths\":3," ++
            "\"selector_phase_deaths\":4," ++
            "\"old_root_recoveries\":5,\"new_root_recoveries\":2," ++
            "\"fresh_resume_processes\":7," ++
            "\"atomic_root_switch\":true," ++
            "\"exact_previous_or_successor\":true," ++
            "\"recovery_idempotent\":true," ++
            "\"duplicate_output_tokens\":0," ++
            "\"power_loss_emulated\":false," ++
            "\"checkpoint_sha256\":\"{s}\"," ++
            "\"selector_sha256\":\"{s}\",\"verified\":true}}\n",
        .{ checkpoint_bytes, &checkpoint_hex, &selector_hex },
    );
    try stdout.flush();
}

fn runChildV1(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = arguments,
        .max_output_bytes = 16 * 1024,
    });
    if (result.stderr.len != 0) {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return error.WorkerStderr;
    }
    allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.WorkerFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.WorkerFailed;
        },
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
