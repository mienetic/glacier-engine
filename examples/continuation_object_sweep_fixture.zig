//! Shared deterministic sweep-record fixture for filesystem conformance tools.

const core = @import("core");
const capsule = core.continuation_capsule;
const bundle = core.continuation_bundle;
const object_store = core.continuation_object_store;
const sweep = core.continuation_object_sweep;
const record = core.continuation_object_sweep_record;

pub const Digest = record.Digest;

pub const RecordsV1 = struct {
    first: [record.encoded_bytes]u8,
    second: [record.encoded_bytes]u8,
    first_root: Digest,
    second_root: Digest,
};

pub fn recordsV1() !RecordsV1 {
    var first: [record.encoded_bytes]u8 = undefined;
    const first_input = inputV1(0x6A, 0x6B);
    _ = try record.encodeV1(first_input, &first);
    const first_root = (try record.decodeV1(&first)).record_sha256;

    var second_input = inputV1(0x7A, 0x7B);
    second_input.sequence = 2;
    second_input.previous_record_sha256 = first_root;
    var second: [record.encoded_bytes]u8 = undefined;
    _ = try record.encodeV1(second_input, &second);
    const second_root = (try record.decodeV1(&second)).record_sha256;
    return .{
        .first = first,
        .second = second,
        .first_root = first_root,
        .second_root = second_root,
    };
}

pub fn originAnchorV1() record.RecoveryAnchorV1 {
    return .{
        .record_epoch = 0x5357_4545_5000_0001,
        .next_sequence = 1,
        .previous_record_sha256 = capsule.zero_digest,
    };
}

pub fn payloadRecordV1(
    tenant_scope_sha256: Digest,
    target: bundle.BlobRefV1,
    entry_count_before: u64,
    payload_bytes_before: u64,
) ![record.encoded_bytes]u8 {
    if (entry_count_before < 1 or
        payload_bytes_before < target.byte_length)
        return error.InvalidPayloadFixture;
    var targets = [_]bundle.BlobRefV1{target};
    object_store.sortRootReferencesV1(&targets);
    const targets_sha256 = try object_store.retiredTargetsRootV1(&targets);
    const commit_grant: sweep.CommitGrantV1 = .{
        .authority_epoch = 21,
        .tenant_scope_sha256 = tenant_scope_sha256,
        .bundle_sha256 = digest(0x82),
        .store_grant_sha256 = digest(0x83),
        .sweep_grant_sha256 = digest(0x84),
        .prepare_sha256 = digest(0x85),
        .expected_snapshot_sha256 = digest(0x86),
        .collection_plan_sha256 = digest(0x87),
        .max_freed_entries = 1,
        .max_freed_bytes = target.byte_length,
        .challenge_sha256 = digest(0x88),
    };
    const grant_sha256 = try sweep.commitGrantRootV1(commit_grant);
    const live_entries = entry_count_before - 1;
    var store_receipt: object_store.RetiredCommitReceiptV1 = .{
        .authorization_sha256 = grant_sha256,
        .targets_sha256 = targets_sha256,
        .snapshot_before_sha256 = commit_grant.expected_snapshot_sha256,
        .snapshot_after_sha256 = digest(0x89),
        .accounting_before = .{
            .entry_count = entry_count_before,
            .live_entries = live_entries,
            .quarantined_entries = 0,
            .retired_entries = 1,
            .payload_bytes = payload_bytes_before,
            .logical_index_bytes = entry_count_before * object_store.logical_index_entry_bytes,
            .reference_count = live_entries,
            .active_leases = 0,
            .repair_count = 0,
        },
        .accounting_after = .{
            .entry_count = live_entries,
            .live_entries = live_entries,
            .quarantined_entries = 0,
            .retired_entries = 0,
            .payload_bytes = payload_bytes_before - target.byte_length,
            .logical_index_bytes = live_entries * object_store.logical_index_entry_bytes,
            .reference_count = live_entries,
            .active_leases = 0,
            .repair_count = 0,
        },
        .freed_entries = 1,
        .freed_payload_bytes = target.byte_length,
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
        .targets_sha256 = targets_sha256,
        .snapshot_before_sha256 = store_receipt.snapshot_before_sha256,
        .snapshot_after_sha256 = store_receipt.snapshot_after_sha256,
        .store_commit_sha256 = store_receipt.commit_sha256,
        .freed_entries = 1,
        .freed_payload_bytes = target.byte_length,
        .freed_index_bytes = object_store.logical_index_entry_bytes,
        .freed_repair_count = 0,
        .allocator_deallocation_calls = 1,
        .commit_sha256 = capsule.zero_digest,
    };
    commit_receipt.commit_sha256 = sweep.commitRootV1(commit_receipt);
    const input: record.InputV1 = .{
        .record_epoch = 0x5357_4545_5000_0001,
        .sequence = 1,
        .previous_record_sha256 = capsule.zero_digest,
        .record_challenge_sha256 = digest(0x8a),
        .commit_grant = commit_grant,
        .commit_receipt = commit_receipt,
        .store_receipt = store_receipt,
    };
    var encoded: [record.encoded_bytes]u8 = undefined;
    _ = try record.encodeV1(input, &encoded);
    return encoded;
}

fn inputV1(commit_challenge: u8, record_challenge: u8) record.InputV1 {
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

fn digest(byte: u8) Digest {
    return [_]u8{byte} ** @sizeOf(Digest);
}
