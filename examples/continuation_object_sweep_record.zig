//! Fixed, pointer-free evidence record for one committed object sweep.

const std = @import("std");
const core = @import("core");
const capsule = core.continuation_capsule;
const object_store = core.continuation_object_store;
const sweep = core.continuation_object_sweep;
const record = core.continuation_object_sweep_record;

pub fn main() !void {
    const input = demoInput(0x6a, 0x6b);
    var storage: [record.encoded_bytes]u8 = undefined;
    const encoded = try record.encodeV1(input, &storage);
    const decoded = try record.decodeV1(encoded);
    const expected = try record.expectationV1(input, decoded.record_sha256);
    _ = try record.decodeAndVerifyV1(encoded, expected);
    const plan = try record.appendPlanV1(encoded);

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
    const record_hex = std.fmt.bytesToHex(decoded.record_sha256, .lower);
    const encoded_hex = std.fmt.bytesToHex(encoded_sha256, .lower);
    const sweep_commit_hex = std.fmt.bytesToHex(
        input.commit_receipt.commit_sha256,
        .lower,
    );

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
            "\"heap_allocations\":0,\"filesystem_authority\":false," ++
            "\"network_authority\":false,\"clock_authority\":false," ++
            "\"deletion_authority\":false,\"recovery_authority\":false," ++
            "\"durable\":false," ++
            "\"record_sha256\":\"{s}\"," ++
            "\"encoded_sha256\":\"{s}\"," ++
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
            &record_hex,
            &encoded_hex,
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
