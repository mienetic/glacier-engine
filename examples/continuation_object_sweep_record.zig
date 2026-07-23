//! Fixed, pointer-free evidence record for one committed object sweep.

const std = @import("std");
const core = @import("core");
const capsule = core.continuation_capsule;
const object_store = core.continuation_object_store;
const sweep = core.continuation_object_sweep;
const record = core.continuation_object_sweep_record;
const sweep_writer = core.continuation_object_sweep_writer;

pub fn main() !void {
    const input = demoInput(0x6a, 0x6b);
    var storage: [record.encoded_bytes]u8 = undefined;
    const encoded = try record.encodeV1(input, &storage);
    const decoded = try record.decodeV1(encoded);
    const expected = try record.expectationV1(input, decoded.record_sha256);
    _ = try record.decodeAndVerifyV1(encoded, expected);
    const plan = try record.appendPlanV1(encoded);

    var second_input = demoInput(0x6b, 0x6c);
    second_input.sequence = 2;
    second_input.previous_record_sha256 = decoded.record_sha256;
    var second_storage: [record.encoded_bytes]u8 = undefined;
    const second = try record.encodeV1(second_input, &second_storage);
    var stream: [record.encoded_bytes * 2]u8 = undefined;
    @memcpy(stream[0..record.encoded_bytes], encoded);
    @memcpy(stream[record.encoded_bytes..], second);
    const recovery_anchor: record.RecoveryAnchorV1 = .{
        .record_epoch = input.record_epoch,
        .next_sequence = 1,
        .previous_record_sha256 = capsule.zero_digest,
    };
    const clean_recovery = try record.classifyRecoveryV1(&stream, recovery_anchor);
    const short_recovery = try record.classifyRecoveryV1(
        stream[0 .. record.encoded_bytes + 100],
        recovery_anchor,
    );
    const body_recovery = try record.classifyRecoveryV1(
        stream[0 .. record.encoded_bytes + record.body_bytes],
        recovery_anchor,
    );
    const partial_footer_recovery = try record.classifyRecoveryV1(
        stream[0 .. record.encoded_bytes + record.body_bytes + 1],
        recovery_anchor,
    );
    var corrupt_stream = stream;
    corrupt_stream[record.encoded_bytes + record.accounting_before_offset] ^= 1;
    const corrupt_recovery = try record.classifyRecoveryV1(
        &corrupt_stream,
        recovery_anchor,
    );
    if (clean_recovery.status != .clean or
        clean_recovery.committed_records != 2 or
        short_recovery.status != .short_body_tail or
        body_recovery.status != .body_without_footer or
        partial_footer_recovery.status != .partial_footer_tail or
        corrupt_recovery.status != .corrupt_record or
        corrupt_recovery.committed_records != 1)
        return error.RecoveryClassificationMismatch;

    var writer_backing: [record.encoded_bytes * 2]u8 = undefined;
    var model_storage = try sweep_writer.DeterministicStorageV1.init(
        &writer_backing,
        encoded,
        41,
    );
    var writer_lease = try model_storage.acquire();
    var durable_writer = try sweep_writer.WriterV1.openClean(
        model_storage.bytes(),
        recovery_anchor,
        try writer_lease.appendCapability(),
    );
    const append_receipt = try durable_writer.appendRecord(second);
    if (!std.mem.eql(u8, model_storage.bytes(), &stream) or
        model_storage.trace().len != 4 or
        append_receipt.sequence != 2 or
        !append_receipt.body_sync_exercised or
        !append_receipt.footer_sync_exercised)
        return error.WriterContractMismatch;
    try writer_lease.release();

    var repair_backing: [record.encoded_bytes * 2]u8 = undefined;
    const repair_tail_bytes = record.body_bytes + 7;
    var repair_storage = try sweep_writer.DeterministicStorageV1.init(
        &repair_backing,
        stream[0 .. record.encoded_bytes + repair_tail_bytes],
        42,
    );
    var repair_lease = try repair_storage.acquire();
    const recovery_plan = try sweep_writer.planRecoveryV1(
        repair_storage.bytes(),
        recovery_anchor,
        repair_lease.snapshot,
    );
    var repairer = try sweep_writer.RepairerV1.init(
        repair_storage.bytes(),
        recovery_anchor,
        try repair_lease.prepareRepair(repair_storage.bytes(), recovery_anchor),
    );
    const repair_receipt = try repairer.apply();
    try repair_lease.release();
    var repaired_lease = try repair_storage.acquire();
    var repaired_writer = try sweep_writer.WriterV1.openClean(
        repair_storage.bytes(),
        recovery_anchor,
        try repaired_lease.appendCapability(),
    );
    _ = try repaired_writer.appendRecord(second);
    if (recovery_plan.action != .repair_incomplete_tail or
        recovery_plan.classification.status != .partial_footer_tail or
        repair_receipt.discarded_tail_bytes != repair_tail_bytes or
        !std.mem.eql(u8, repair_storage.bytes(), &stream))
        return error.RepairContractMismatch;
    try repaired_lease.release();

    var corrupted = storage;
    corrupted[record.accounting_before_offset] ^= 1;
    if (record.decodeV1(&corrupted)) |_| {
        return error.MutationWasAccepted;
    } else |_| {}

    const foreign_input = demoInput(0x7a, 0x7b);
    var foreign_storage: [record.encoded_bytes]u8 = undefined;
    const foreign = try record.encodeV1(foreign_input, &foreign_storage);
    _ = try record.decodeV1(foreign);
    if (record.decodeAndVerifyV1(foreign, expected)) |_| {
        return error.ForeignRecordWasAccepted;
    } else |err| switch (err) {
        record.Error.RecordExpectationMismatch => {},
        else => return err,
    }

    var encoded_sha256: record.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &encoded_sha256, .{});
    var stream_sha256: record.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(&stream, &stream_sha256, .{});
    const record_hex = std.fmt.bytesToHex(decoded.record_sha256, .lower);
    const encoded_hex = std.fmt.bytesToHex(encoded_sha256, .lower);
    const sweep_commit_hex = std.fmt.bytesToHex(
        input.commit_receipt.commit_sha256,
        .lower,
    );
    const stream_hex = std.fmt.bytesToHex(stream_sha256, .lower);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.continuation-object-sweep-record/demo-v1\"," ++
            "\"encoded_bytes\":{d},\"body_bytes\":{d}," ++
            "\"commit_footer_bytes\":{d},\"sequence\":{d}," ++
            "\"previous_record_is_zero\":true," ++
            "\"entry_count_before\":{d},\"entry_count_after\":{d}," ++
            "\"retired_entries_before\":{d}," ++
            "\"retired_entries_after\":{d}," ++
            "\"payload_bytes_before\":{d}," ++
            "\"payload_bytes_after\":{d}," ++
            "\"freed_entries\":{d},\"freed_payload_bytes\":{d}," ++
            "\"freed_index_bytes\":{d}," ++
            "\"allocator_deallocation_calls\":{d}," ++
            "\"append_plan_body_first\":true," ++
            "\"mutation_rejected\":true," ++
            "\"valid_foreign_record_rejected\":true," ++
            "\"stream_records\":{d},\"stream_bytes\":{d}," ++
            "\"recovery_clean_status\":\"{s}\"," ++
            "\"recovery_short_status\":\"{s}\"," ++
            "\"recovery_body_status\":\"{s}\"," ++
            "\"recovery_partial_footer_status\":\"{s}\"," ++
            "\"recovery_corrupt_status\":\"{s}\"," ++
            "\"recovery_corrupt_safe_records\":{d}," ++
            "\"recovery_modifies_input\":false," ++
            "\"recovery_repair_authority\":false," ++
            "\"writer_snapshot_bound\":true," ++
            "\"writer_exclusive_lease\":true," ++
            "\"writer_phase_count\":{d}," ++
            "\"writer_body_sync\":true,\"writer_footer_sync\":true," ++
            "\"writer_poison_on_uncertain_io\":true," ++
            "\"repair_action\":\"{s}\",\"repair_status\":\"{s}\"," ++
            "\"repair_discarded_tail_bytes\":{d}," ++
            "\"repair_requires_reacquire\":true," ++
            "\"append_authority_can_truncate\":false," ++
            "\"repair_authority_can_append\":false," ++
            "\"heap_allocations\":0,\"filesystem_authority\":false," ++
            "\"network_authority\":false,\"clock_authority\":false," ++
            "\"deletion_authority\":false,\"recovery_authority\":false," ++
            "\"durable\":false," ++
            "\"record_sha256\":\"{s}\"," ++
            "\"encoded_sha256\":\"{s}\"," ++
            "\"stream_sha256\":\"{s}\"," ++
            "\"sweep_commit_sha256\":\"{s}\",\"verified\":true}}\n",
        .{
            encoded.len,
            plan.body.len,
            plan.commit_footer.len,
            input.sequence,
            input.store_receipt.accounting_before.entry_count,
            input.store_receipt.accounting_after.entry_count,
            input.store_receipt.accounting_before.retired_entries,
            input.store_receipt.accounting_after.retired_entries,
            input.store_receipt.accounting_before.payload_bytes,
            input.store_receipt.accounting_after.payload_bytes,
            input.commit_receipt.freed_entries,
            input.commit_receipt.freed_payload_bytes,
            input.commit_receipt.freed_index_bytes,
            input.commit_receipt.allocator_deallocation_calls,
            clean_recovery.committed_records,
            stream.len,
            @tagName(clean_recovery.status),
            @tagName(short_recovery.status),
            @tagName(body_recovery.status),
            @tagName(partial_footer_recovery.status),
            @tagName(corrupt_recovery.status),
            corrupt_recovery.committed_records,
            model_storage.trace().len,
            @tagName(recovery_plan.action),
            @tagName(recovery_plan.classification.status),
            repair_receipt.discarded_tail_bytes,
            &record_hex,
            &encoded_hex,
            &stream_hex,
            &sweep_commit_hex,
        },
    );
    try stdout.flush();
}

fn digest(byte: u8) record.Digest {
    return [_]u8{byte} ** @sizeOf(record.Digest);
}

fn demoInput(commit_challenge: u8, record_challenge: u8) record.InputV1 {
    const commit_grant: sweep.CommitGrantV1 = .{
        .authority_epoch = 11,
        .tenant_scope_sha256 = digest(0x61),
        .bundle_sha256 = digest(0x62),
        .store_grant_sha256 = digest(0x63),
        .sweep_grant_sha256 = digest(0x64),
        .prepare_sha256 = digest(0x65),
        .expected_snapshot_sha256 = digest(0x66),
        .collection_plan_sha256 = digest(0x67),
        .max_freed_entries = 2,
        .max_freed_bytes = 128,
        .challenge_sha256 = digest(commit_challenge),
    };
    const grant_sha256 = sweep.commitGrantRootV1(commit_grant) catch
        unreachable;
    var store_receipt: object_store.RetiredCommitReceiptV1 = .{
        .authorization_sha256 = grant_sha256,
        .targets_sha256 = digest(0x68),
        .snapshot_before_sha256 = commit_grant.expected_snapshot_sha256,
        .snapshot_after_sha256 = digest(0x69),
        .accounting_before = .{
            .entry_count = 8,
            .live_entries = 6,
            .quarantined_entries = 1,
            .retired_entries = 1,
            .payload_bytes = 255,
            .logical_index_bytes = 1024,
            .reference_count = 8,
            .active_leases = 1,
            .repair_count = 0,
        },
        .accounting_after = .{
            .entry_count = 7,
            .live_entries = 6,
            .quarantined_entries = 1,
            .retired_entries = 0,
            .payload_bytes = 216,
            .logical_index_bytes = 896,
            .reference_count = 8,
            .active_leases = 1,
            .repair_count = 0,
        },
        .freed_entries = 1,
        .freed_payload_bytes = 39,
        .freed_index_bytes = object_store.logical_index_entry_bytes,
        .freed_repair_count = 0,
        .allocator_deallocation_calls = 1,
        .commit_sha256 = capsule.zero_digest,
    };
    store_receipt.commit_sha256 =
        object_store.retiredCommitReceiptRootV1(store_receipt);
    var commit_receipt: sweep.CommitReceiptV1 = .{
        .commit_grant_sha256 = grant_sha256,
        .sweep_grant_sha256 = commit_grant.sweep_grant_sha256,
        .prepare_sha256 = commit_grant.prepare_sha256,
        .collection_plan_sha256 = commit_grant.collection_plan_sha256,
        .targets_sha256 = store_receipt.targets_sha256,
        .snapshot_before_sha256 = store_receipt.snapshot_before_sha256,
        .snapshot_after_sha256 = store_receipt.snapshot_after_sha256,
        .store_commit_sha256 = store_receipt.commit_sha256,
        .freed_entries = store_receipt.freed_entries,
        .freed_payload_bytes = store_receipt.freed_payload_bytes,
        .freed_index_bytes = store_receipt.freed_index_bytes,
        .freed_repair_count = store_receipt.freed_repair_count,
        .allocator_deallocation_calls = store_receipt.allocator_deallocation_calls,
        .commit_sha256 = capsule.zero_digest,
    };
    commit_receipt.commit_sha256 = sweep.commitRootV1(commit_receipt);
    return .{
        .record_epoch = 0x5357_4545_5000_0001,
        .sequence = 1,
        .previous_record_sha256 = capsule.zero_digest,
        .record_challenge_sha256 = digest(record_challenge),
        .commit_grant = commit_grant,
        .commit_receipt = commit_receipt,
        .store_receipt = store_receipt,
    };
}
