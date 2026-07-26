//! Real POSIX process-death recovery campaign for ActionOutbox journals.
//!
//! Workers terminate after completed host filesystem operations. The campaign
//! proves exact fresh-process prefix recovery and semantic convergence through
//! the tested filesystem API; it does not emulate power loss or exercise an
//! external dispatcher, credentials, provider truth, or remote effects.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const outbox = core.tool_action_outbox_record;
const conformance = core.tool_action_outbox_conformance;
const outbox_file = core.tool_action_outbox_file;

const initialization_phases = [_]outbox_file.IoPhaseV1{
    .header_write,
    .header_sync,
    .directory_sync,
};
const append_phases = [_]outbox_file.IoPhaseV1{
    .body_write,
    .body_sync,
    .footer_write,
    .footer_sync,
};
const repair_phases = [_]outbox_file.IoPhaseV1{
    .repair_truncate,
    .repair_sync,
};
const tail_cuts = [_]usize{
    outbox.record_body_bytes - 1,
    outbox.record_body_bytes,
    outbox.record_bytes - 1,
};
const repair_prefix_records: usize = 6;

const Fixture = struct {
    header: outbox.HeaderV1,
    storage: conformance.ReferenceStorageV1,
    report: conformance.ReportV1,

    fn init() !Fixture {
        var storage: conformance.ReferenceStorageV1 = .{};
        const report =
            try conformance.runReferenceCampaignV1(&storage);
        return .{
            .header = try conformance.referenceHeaderV1(),
            .storage = storage,
            .report = report,
        };
    }
};

const Buffers = struct {
    journal: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined,
    records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined,
    states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined,
};

fn digestEqual(left: outbox.Digest, right: outbox.Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn createPrefix(
    directory: std.fs.Dir,
    name: []const u8,
    fixture: *const Fixture,
    buffers: *Buffers,
    max_bytes: usize,
    record_count: usize,
) !void {
    if (record_count > conformance.reference_record_count)
        return error.InvalidRecordCount;
    var store = try outbox_file.StoreV1.create(
        directory,
        name,
        fixture.header,
        .{},
        buffers.journal[0..max_bytes],
        buffers.records[0..@intCast(
            fixture.header.maximum_records,
        )],
        buffers.states[0..@intCast(
            fixture.header.maximum_actions,
        )],
    );
    defer store.close();
    for (fixture.storage.records[0..record_count]) |record| {
        const receipt = try store.appendRecord(record);
        if (!receipt.body_sync_exercised or
            !receipt.footer_sync_exercised)
            return error.MissingAppendSync;
    }
}

fn openStore(
    directory: std.fs.Dir,
    name: []const u8,
    fixture: *const Fixture,
    buffers: *Buffers,
    max_bytes: usize,
) !outbox_file.StoreV1 {
    return outbox_file.StoreV1.open(
        directory,
        name,
        fixture.header,
        .{},
        buffers.journal[0..max_bytes],
        buffers.records[0..@intCast(
            fixture.header.maximum_records,
        )],
        buffers.states[0..@intCast(
            fixture.header.maximum_actions,
        )],
    );
}

fn verifyPrefix(
    store: *const outbox_file.StoreV1,
    fixture: *const Fixture,
    record_count: usize,
) !void {
    if (record_count > conformance.reference_record_count)
        return error.InvalidRecordCount;
    const expected_bytes =
        outbox.header_bytes + record_count * outbox.record_bytes;
    if (store.committed_bytes != expected_bytes or
        store.record_count != record_count or
        !std.mem.eql(
            u8,
            try store.journal(),
            fixture.storage.journal[0..expected_bytes],
        ))
        return error.UnexpectedCommittedPrefix;

    var expected_records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var expected_states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;
    const expected = try outbox.recoverV1(
        fixture.storage.journal[0..expected_bytes],
        fixture.header.header_sha256,
        expected_records[0..@intCast(
            fixture.header.maximum_records,
        )],
        expected_states[0..@intCast(
            fixture.header.maximum_actions,
        )],
    );
    if (expected.status != .clean or
        store.action_count != expected.states.len or
        !digestEqual(
            store.final_chain_sha256,
            expected.final_chain_sha256,
        ) or
        !digestEqual(store.state_sha256, expected.state_sha256) or
        !std.meta.eql(store.ledger, expected.ledger))
        return error.UnexpectedSemanticPrefix;
}

fn verifyFinal(
    store: *const outbox_file.StoreV1,
    fixture: *const Fixture,
) !void {
    try verifyPrefix(
        store,
        fixture,
        conformance.reference_record_count,
    );
    if (!digestEqual(
        store.final_chain_sha256,
        fixture.report.final_chain_sha256,
    ) or !digestEqual(
        store.state_sha256,
        fixture.report.final_state_sha256,
    ) or !digestEqual(
        outbox.ledgerSha256V1(store.ledger),
        fixture.report.ledger_sha256,
    ))
        return error.UnexpectedFinalSemanticState;

    var records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;
    const recovered = try outbox.recoverV1(
        try store.journal(),
        fixture.header.header_sha256,
        records[0..@intCast(fixture.header.maximum_records)],
        states[0..@intCast(fixture.header.maximum_actions)],
    );
    const anchor = try outbox.makeClosedAnchorV1(recovered);
    if (!digestEqual(
        anchor.anchor_sha256,
        fixture.report.closed_anchor_sha256,
    ))
        return error.UnexpectedClosedAnchor;
}

fn appendRemaining(
    store: *outbox_file.StoreV1,
    fixture: *const Fixture,
    first_record: usize,
) !void {
    if (first_record > conformance.reference_record_count)
        return error.InvalidRecordCount;
    for (fixture.storage.records[first_record..]) |record| {
        _ = try store.appendRecord(record);
    }
}

fn seedIncompleteTail(
    directory: std.fs.Dir,
    name: []const u8,
    fixture: *const Fixture,
    cut: usize,
) !void {
    if (cut == 0 or cut >= outbox.record_bytes)
        return error.InvalidTailCut;
    const prefix_end = outbox.header_bytes +
        repair_prefix_records * outbox.record_bytes;
    const tail = fixture.storage.journal[prefix_end .. prefix_end + cut];
    const file = try directory.openFile(name, .{
        .mode = .read_write,
    });
    defer file.close();
    try file.pwriteAll(tail, prefix_end);
    try file.sync();
}

fn expectedTailStatus(cut: usize) outbox.RecoveryStatusV1 {
    if (cut < outbox.record_body_bytes)
        return .short_body_tail;
    if (cut == outbox.record_body_bytes)
        return .body_without_footer;
    return .partial_footer_tail;
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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 2) return error.MissingWorkerPath;
    const worker_path = arguments[1];
    const fixture = try Fixture.init();
    const max_bytes =
        try outbox_file.maximumFileBytesV1(fixture.header);
    const buffers = try allocator.create(Buffers);
    defer allocator.destroy(buffers);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_directory = try temporary.dir.realpath(
        ".",
        &absolute_storage,
    );

    var initialization_deaths: usize = 0;
    var append_deaths: usize = 0;
    var repair_deaths: usize = 0;
    var incomplete_append_repairs: usize = 0;
    var converged_campaigns: usize = 0;

    for (initialization_phases, 0..) |phase, phase_index| {
        var name_storage: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_storage,
            "init-death-{d}.outbox",
            .{phase_index},
        );
        try expectKilled(allocator, &.{
            worker_path,
            "create",
            absolute_directory,
            name,
            @tagName(phase),
        });
        initialization_deaths += 1;

        var reopened = try openStore(
            temporary.dir,
            name,
            &fixture,
            buffers,
            max_bytes,
        );
        defer reopened.close();
        if (reopened.state != .ready or
            reopened.recovery_status != .clean)
            return error.UnexpectedInitializationRecovery;
        try verifyPrefix(&reopened, &fixture, 0);
        try appendRemaining(&reopened, &fixture, 0);
        try verifyFinal(&reopened, &fixture);
        converged_campaigns += 1;
    }

    for (fixture.storage.records, 0..) |_, record_index| {
        for (append_phases, 0..) |phase, phase_index| {
            var name_storage: [80]u8 = undefined;
            const name = try std.fmt.bufPrint(
                &name_storage,
                "append-death-{d}-{d}.outbox",
                .{ record_index, phase_index },
            );
            try createPrefix(
                temporary.dir,
                name,
                &fixture,
                buffers,
                max_bytes,
                record_index,
            );
            var record_index_storage: [32]u8 = undefined;
            const record_index_text = try std.fmt.bufPrint(
                &record_index_storage,
                "{d}",
                .{record_index},
            );
            try expectKilled(allocator, &.{
                worker_path,
                "append",
                absolute_directory,
                name,
                record_index_text,
                @tagName(phase),
            });
            append_deaths += 1;

            var recovered = try openStore(
                temporary.dir,
                name,
                &fixture,
                buffers,
                max_bytes,
            );
            defer recovered.close();
            switch (phase) {
                .body_write, .body_sync => {
                    if (recovered.state != .repair_required or
                        recovered.recovery_status !=
                            .body_without_footer or
                        recovered.discarded_tail_bytes !=
                            outbox.record_body_bytes)
                        return error.UnexpectedIncompleteAppend;
                    try verifyPrefix(
                        &recovered,
                        &fixture,
                        record_index,
                    );
                    const receipt =
                        try recovered.repairIncompleteTail();
                    if (receipt.committed_bytes !=
                        outbox.header_bytes +
                            record_index * outbox.record_bytes or
                        !receipt.truncate_sync_exercised)
                        return error.UnexpectedRepairReceipt;
                    incomplete_append_repairs += 1;
                    recovered.close();

                    var clean = try openStore(
                        temporary.dir,
                        name,
                        &fixture,
                        buffers,
                        max_bytes,
                    );
                    defer clean.close();
                    if (clean.state != .ready or
                        clean.recovery_status != .clean)
                        return error.UnexpectedRepairReopen;
                    try verifyPrefix(
                        &clean,
                        &fixture,
                        record_index,
                    );
                    try appendRemaining(
                        &clean,
                        &fixture,
                        record_index,
                    );
                    try verifyFinal(&clean, &fixture);
                },
                .footer_write, .footer_sync => {
                    if (recovered.state != .ready or
                        recovered.recovery_status != .clean)
                        return error.UnexpectedCommittedAppend;
                    try verifyPrefix(
                        &recovered,
                        &fixture,
                        record_index + 1,
                    );
                    try appendRemaining(
                        &recovered,
                        &fixture,
                        record_index + 1,
                    );
                    try verifyFinal(&recovered, &fixture);
                },
                else => unreachable,
            }
            converged_campaigns += 1;
        }
    }

    for (tail_cuts, 0..) |cut, tail_index| {
        for (repair_phases, 0..) |phase, phase_index| {
            var name_storage: [80]u8 = undefined;
            const name = try std.fmt.bufPrint(
                &name_storage,
                "repair-death-{d}-{d}.outbox",
                .{ tail_index, phase_index },
            );
            try createPrefix(
                temporary.dir,
                name,
                &fixture,
                buffers,
                max_bytes,
                repair_prefix_records,
            );
            try seedIncompleteTail(
                temporary.dir,
                name,
                &fixture,
                cut,
            );

            var inspected = try openStore(
                temporary.dir,
                name,
                &fixture,
                buffers,
                max_bytes,
            );
            if (inspected.state != .repair_required or
                inspected.recovery_status !=
                    expectedTailStatus(cut) or
                inspected.discarded_tail_bytes != cut)
                return error.UnexpectedTailClassification;
            inspected.close();

            try expectKilled(allocator, &.{
                worker_path,
                "repair",
                absolute_directory,
                name,
                @tagName(phase),
            });
            repair_deaths += 1;

            var recovered = try openStore(
                temporary.dir,
                name,
                &fixture,
                buffers,
                max_bytes,
            );
            defer recovered.close();
            if (recovered.state != .ready or
                recovered.recovery_status != .clean)
                return error.UnexpectedRepairDeathRecovery;
            try verifyPrefix(
                &recovered,
                &fixture,
                repair_prefix_records,
            );
            try appendRemaining(
                &recovered,
                &fixture,
                repair_prefix_records,
            );
            try verifyFinal(&recovered, &fixture);
            converged_campaigns += 1;
        }
    }

    const total_deaths =
        initialization_deaths + append_deaths + repair_deaths;
    if (initialization_deaths != initialization_phases.len or
        append_deaths !=
            conformance.reference_record_count *
                append_phases.len or
        repair_deaths != tail_cuts.len * repair_phases.len or
        incomplete_append_repairs !=
            conformance.reference_record_count * 2 or
        converged_campaigns != total_deaths)
        return error.IncompleteCampaign;

    const final_chain_hex = std.fmt.bytesToHex(
        fixture.report.final_chain_sha256,
        .lower,
    );
    const final_state_hex = std.fmt.bytesToHex(
        fixture.report.final_state_sha256,
        .lower,
    );
    const ledger_hex = std.fmt.bytesToHex(
        fixture.report.ledger_sha256,
        .lower,
    );
    const anchor_hex = std.fmt.bytesToHex(
        fixture.report.closed_anchor_sha256,
        .lower,
    );
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.action-outbox-file-recovery/demo-v1\"," ++
            "\"initialization_process_deaths\":{d}," ++
            "\"append_process_deaths\":{d}," ++
            "\"repair_process_deaths\":{d}," ++
            "\"process_deaths\":{d}," ++
            "\"record_count\":{d}," ++
            "\"tail_classes\":{d}," ++
            "\"incomplete_append_repairs\":{d}," ++
            "\"converged_campaigns\":{d}," ++
            "\"final_chain_sha256\":\"{s}\"," ++
            "\"final_state_sha256\":\"{s}\"," ++
            "\"ledger_sha256\":\"{s}\"," ++
            "\"closed_anchor_sha256\":\"{s}\"," ++
            "\"descriptor_relative\":true," ++
            "\"ordered_file_sync\":true," ++
            "\"directory_sync\":true," ++
            "\"process_death_only\":true," ++
            "\"power_loss_emulated\":false," ++
            "\"external_dispatch_exercised\":false," ++
            "\"provider_truth_exercised\":false," ++
            "\"verified\":true}}\n",
        .{
            initialization_deaths,
            append_deaths,
            repair_deaths,
            total_deaths,
            conformance.reference_record_count,
            tail_cuts.len,
            incomplete_append_repairs,
            converged_campaigns,
            &final_chain_hex,
            &final_state_hex,
            &ledger_hex,
            &anchor_hex,
        },
    );
    try stdout.flush();
}
