//! Fixed body/footer evidence record for one committed continuation-object sweep.
//!
//! The record embeds the minimum canonical fields needed to reconstruct and
//! independently verify one sweep commit grant, store receipt, and outer sweep
//! receipt. Its body root is repeated in a separate commit footer so a future
//! durable writer can sync the body before publishing the footer. This module
//! performs no filesystem I/O and grants no deletion or recovery authority.

const std = @import("std");
const capsule = @import("continuation_capsule.zig");
const object_store = @import("continuation_object_store.zig");
const sweep = @import("continuation_object_sweep.zig");

pub const Digest = capsule.Digest;
pub const abi_version: u64 = 0x4743_5352_0000_0001;
pub const body_magic = [_]u8{ 'G', 'C', 'S', 'W', 'R', 'B', '0', '1' };
pub const commit_magic = [_]u8{ 'G', 'C', 'S', 'W', 'R', 'F', '0', '1' };
pub const allowed_flags: u32 = 0;

const record_domain = "glacier-continuation-sweep-record-body-v1\x00";
const digest_bytes = @sizeOf(Digest);
const accounting_field_count = 9;
const freed_field_count = 5;
const body_digest_count = 14;
const body_u64_count = 7 + accounting_field_count * 2 + freed_field_count;

pub const accounting_before_offset: usize = 456;
pub const sequence_offset: usize = 40;
pub const body_prefix_bytes: usize =
    body_magic.len + 2 * @sizeOf(u32) +
    body_u64_count * @sizeOf(u64) + body_digest_count * digest_bytes;
pub const body_bytes: usize = body_prefix_bytes + digest_bytes;
pub const commit_footer_bytes: usize = commit_magic.len + @sizeOf(u64) + digest_bytes;
pub const encoded_bytes: usize = body_bytes + commit_footer_bytes;

comptime {
    if (body_prefix_bytes != 704 or body_bytes != 736 or encoded_bytes != 784)
        @compileError("continuation sweep record layout drifted");
    if (accounting_before_offset >= body_prefix_bytes)
        @compileError("continuation sweep accounting offset drifted");
}

pub const Error = sweep.Error || error{
    InvalidSweepRecord,
    InvalidCommitFooter,
    RecordExpectationMismatch,
    InvalidRecoveryAnchor,
};

pub const InputV1 = struct {
    record_epoch: u64,
    sequence: u64,
    previous_record_sha256: Digest,
    record_challenge_sha256: Digest,
    commit_grant: sweep.CommitGrantV1,
    commit_receipt: sweep.CommitReceiptV1,
    store_receipt: object_store.RetiredCommitReceiptV1,
};

pub const DecodedV1 = struct {
    input: InputV1,
    record_sha256: Digest,
};

pub const ExpectationV1 = struct {
    record_epoch: u64,
    sequence: u64,
    previous_record_sha256: Digest,
    sweep_commit_sha256: Digest,
    record_sha256: Digest,
};

pub const AppendPlanV1 = struct {
    body: []const u8,
    commit_footer: []const u8,
};

pub const RecoveryStatusV1 = enum(u8) {
    clean,
    short_body_tail,
    body_without_footer,
    partial_footer_tail,
    corrupt_record,
};

/// Pins the exact chain position expected at byte zero of one stream segment.
/// An origin stream uses sequence 1 and the zero previous root; a verified
/// suffix may start later by supplying its already committed predecessor.
pub const RecoveryAnchorV1 = struct {
    record_epoch: u64,
    next_sequence: u64,
    previous_record_sha256: Digest,
};

pub const RecoveryClassificationV1 = struct {
    status: RecoveryStatusV1,
    record_epoch: u64,
    first_sequence: u64,
    last_sequence: u64,
    committed_records: u64,
    committed_bytes: usize,
    tail_bytes: usize,
    final_record_sha256: Digest,
};

pub fn encodeV1(input: InputV1, output: []u8) Error![]const u8 {
    if (output.len < encoded_bytes) return Error.InvalidLength;
    try validateInputV1(input);

    var encoded: [encoded_bytes]u8 = undefined;
    var writer: Writer = .{ .bytes = &encoded };
    try writer.writeBytes(&body_magic);
    try writer.writeU64(abi_version);
    try writer.writeU64(encoded_bytes);
    try writer.writeU32(allowed_flags);
    try writer.writeU32(0);
    try writer.writeU64(input.record_epoch);
    try writer.writeU64(input.sequence);
    try writer.writeDigest(input.previous_record_sha256);
    try writer.writeDigest(input.record_challenge_sha256);

    const grant = input.commit_grant;
    try writer.writeU64(grant.authority_epoch);
    try writer.writeDigest(grant.tenant_scope_sha256);
    try writer.writeDigest(grant.bundle_sha256);
    try writer.writeDigest(grant.store_grant_sha256);
    try writer.writeDigest(grant.sweep_grant_sha256);
    try writer.writeDigest(grant.prepare_sha256);
    try writer.writeDigest(grant.expected_snapshot_sha256);
    try writer.writeDigest(grant.collection_plan_sha256);
    try writer.writeU64(grant.max_freed_entries);
    try writer.writeU64(grant.max_freed_bytes);
    try writer.writeDigest(grant.challenge_sha256);

    try writer.writeDigest(input.commit_receipt.targets_sha256);
    try writer.writeDigest(input.commit_receipt.snapshot_after_sha256);
    try writer.writeAccounting(input.store_receipt.accounting_before);
    try writer.writeAccounting(input.store_receipt.accounting_after);
    try writer.writeU64(input.commit_receipt.freed_entries);
    try writer.writeU64(input.commit_receipt.freed_payload_bytes);
    try writer.writeU64(input.commit_receipt.freed_index_bytes);
    try writer.writeU64(input.commit_receipt.freed_repair_count);
    try writer.writeU64(input.commit_receipt.allocator_deallocation_calls);
    try writer.writeDigest(input.store_receipt.commit_sha256);
    try writer.writeDigest(input.commit_receipt.commit_sha256);
    if (writer.position != body_prefix_bytes) return Error.InvalidLength;

    const record_sha256 = try recordRootV1(encoded[0..body_prefix_bytes]);
    try writer.writeDigest(record_sha256);
    if (writer.position != body_bytes) return Error.InvalidLength;
    try writer.writeBytes(&commit_magic);
    try writer.writeU64(input.sequence);
    try writer.writeDigest(record_sha256);
    if (writer.position != encoded_bytes) return Error.InvalidLength;

    std.mem.copyForwards(u8, output[0..encoded_bytes], &encoded);
    return output[0..encoded_bytes];
}

pub fn decodeV1(encoded: []const u8) Error!DecodedV1 {
    if (encoded.len != encoded_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(body_magic.len), &body_magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != abi_version) return Error.InvalidAbi;
    if (try reader.readU64() != encoded_bytes) return Error.InvalidLength;
    if (try reader.readU32() != allowed_flags or try reader.readU32() != 0)
        return Error.InvalidFlags;

    const record_epoch = try reader.readU64();
    const sequence = try reader.readU64();
    const previous_record_sha256 = try reader.readDigest();
    const record_challenge_sha256 = try reader.readDigest();
    const commit_grant: sweep.CommitGrantV1 = .{
        .authority_epoch = try reader.readU64(),
        .tenant_scope_sha256 = try reader.readDigest(),
        .bundle_sha256 = try reader.readDigest(),
        .store_grant_sha256 = try reader.readDigest(),
        .sweep_grant_sha256 = try reader.readDigest(),
        .prepare_sha256 = try reader.readDigest(),
        .expected_snapshot_sha256 = try reader.readDigest(),
        .collection_plan_sha256 = try reader.readDigest(),
        .max_freed_entries = try reader.readU64(),
        .max_freed_bytes = try reader.readU64(),
        .challenge_sha256 = try reader.readDigest(),
    };
    const targets_sha256 = try reader.readDigest();
    const snapshot_after_sha256 = try reader.readDigest();
    const accounting_before = try reader.readAccounting();
    const accounting_after = try reader.readAccounting();
    const freed_entries = try reader.readU64();
    const freed_payload_bytes = try reader.readU64();
    const freed_index_bytes = try reader.readU64();
    const freed_repair_count = try reader.readU64();
    const allocator_deallocation_calls = try reader.readU64();
    const store_commit_sha256 = try reader.readDigest();
    const sweep_commit_sha256 = try reader.readDigest();
    if (reader.position != body_prefix_bytes) return Error.InvalidLength;

    const record_sha256 = try reader.readDigest();
    const expected_record_sha256 = try recordRootV1(
        encoded[0..body_prefix_bytes],
    );
    if (!std.mem.eql(u8, &record_sha256, &expected_record_sha256))
        return Error.InvalidSweepRecord;
    if (reader.position != body_bytes) return Error.InvalidLength;
    if (!std.mem.eql(u8, try reader.readBytes(commit_magic.len), &commit_magic))
        return Error.InvalidCommitFooter;
    if (try reader.readU64() != sequence) return Error.InvalidCommitFooter;
    const committed_record_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or
        !std.mem.eql(u8, &committed_record_sha256, &record_sha256))
        return Error.InvalidCommitFooter;

    const commit_grant_sha256 = sweep.commitGrantRootV1(commit_grant) catch
        return Error.InvalidSweepRecord;
    const store_receipt: object_store.RetiredCommitReceiptV1 = .{
        .authorization_sha256 = commit_grant_sha256,
        .targets_sha256 = targets_sha256,
        .snapshot_before_sha256 = commit_grant.expected_snapshot_sha256,
        .snapshot_after_sha256 = snapshot_after_sha256,
        .accounting_before = accounting_before,
        .accounting_after = accounting_after,
        .freed_entries = freed_entries,
        .freed_payload_bytes = freed_payload_bytes,
        .freed_index_bytes = freed_index_bytes,
        .freed_repair_count = freed_repair_count,
        .allocator_deallocation_calls = allocator_deallocation_calls,
        .commit_sha256 = store_commit_sha256,
    };
    const commit_receipt: sweep.CommitReceiptV1 = .{
        .commit_grant_sha256 = commit_grant_sha256,
        .sweep_grant_sha256 = commit_grant.sweep_grant_sha256,
        .prepare_sha256 = commit_grant.prepare_sha256,
        .collection_plan_sha256 = commit_grant.collection_plan_sha256,
        .targets_sha256 = targets_sha256,
        .snapshot_before_sha256 = commit_grant.expected_snapshot_sha256,
        .snapshot_after_sha256 = snapshot_after_sha256,
        .store_commit_sha256 = store_commit_sha256,
        .freed_entries = freed_entries,
        .freed_payload_bytes = freed_payload_bytes,
        .freed_index_bytes = freed_index_bytes,
        .freed_repair_count = freed_repair_count,
        .allocator_deallocation_calls = allocator_deallocation_calls,
        .commit_sha256 = sweep_commit_sha256,
    };
    const input: InputV1 = .{
        .record_epoch = record_epoch,
        .sequence = sequence,
        .previous_record_sha256 = previous_record_sha256,
        .record_challenge_sha256 = record_challenge_sha256,
        .commit_grant = commit_grant,
        .commit_receipt = commit_receipt,
        .store_receipt = store_receipt,
    };
    try validateInputV1(input);
    return .{ .input = input, .record_sha256 = record_sha256 };
}

pub fn decodeAndVerifyV1(
    encoded: []const u8,
    expected: ExpectationV1,
) Error!DecodedV1 {
    try validateExpectationV1(expected);
    const decoded = try decodeV1(encoded);
    if (decoded.input.record_epoch != expected.record_epoch or
        decoded.input.sequence != expected.sequence or
        !std.mem.eql(
            u8,
            &decoded.input.previous_record_sha256,
            &expected.previous_record_sha256,
        ) or
        !std.mem.eql(
            u8,
            &decoded.input.commit_receipt.commit_sha256,
            &expected.sweep_commit_sha256,
        ) or
        !std.mem.eql(
            u8,
            &decoded.record_sha256,
            &expected.record_sha256,
        )) return Error.RecordExpectationMismatch;
    return decoded;
}

pub fn expectationV1(input: InputV1, record_sha256: Digest) Error!ExpectationV1 {
    try validateInputV1(input);
    const expected: ExpectationV1 = .{
        .record_epoch = input.record_epoch,
        .sequence = input.sequence,
        .previous_record_sha256 = input.previous_record_sha256,
        .sweep_commit_sha256 = input.commit_receipt.commit_sha256,
        .record_sha256 = record_sha256,
    };
    try validateExpectationV1(expected);
    return expected;
}

/// Splits one fully verified record into future durability writes. A durable
/// adapter must persist and sync `body` before appending and syncing
/// `commit_footer`; this function itself performs no I/O.
pub fn appendPlanV1(encoded: []const u8) Error!AppendPlanV1 {
    _ = try decodeV1(encoded);
    return .{
        .body = encoded[0..body_bytes],
        .commit_footer = encoded[body_bytes..encoded_bytes],
    };
}

/// Classifies a caller-owned byte stream without allocating, opening files, or
/// granting repair authority. Only complete records with valid semantic
/// evidence and an exact epoch/sequence/previous-root chain enter the committed
/// prefix. Incomplete tails are described; corrupt complete evidence is never
/// downgraded to a torn tail.
pub fn classifyRecoveryV1(
    stream: []const u8,
    anchor: RecoveryAnchorV1,
) Error!RecoveryClassificationV1 {
    try validateRecoveryAnchorV1(anchor);

    var offset: usize = 0;
    var committed_records: u64 = 0;
    var expected_sequence = anchor.next_sequence;
    var expected_previous = anchor.previous_record_sha256;
    var last_sequence = anchor.next_sequence - 1;
    var final_record_sha256 = anchor.previous_record_sha256;

    while (stream.len - offset >= encoded_bytes) {
        const decoded = decodeV1(stream[offset .. offset + encoded_bytes]) catch
            return recoveryClassificationV1(
                .corrupt_record,
                anchor,
                last_sequence,
                committed_records,
                offset,
                stream.len - offset,
                final_record_sha256,
            );
        if (!recoveryRecordMatchesV1(
            &decoded,
            anchor.record_epoch,
            expected_sequence,
            expected_previous,
        )) return recoveryClassificationV1(
            .corrupt_record,
            anchor,
            last_sequence,
            committed_records,
            offset,
            stream.len - offset,
            final_record_sha256,
        );

        offset += encoded_bytes;
        committed_records = std.math.add(
            u64,
            committed_records,
            1,
        ) catch return Error.InvalidSweepRecord;
        last_sequence = decoded.input.sequence;
        final_record_sha256 = decoded.record_sha256;
        expected_previous = decoded.record_sha256;
        if (offset < stream.len) {
            expected_sequence = std.math.add(
                u64,
                decoded.input.sequence,
                1,
            ) catch return recoveryClassificationV1(
                .corrupt_record,
                anchor,
                last_sequence,
                committed_records,
                offset,
                stream.len - offset,
                final_record_sha256,
            );
        }
    }

    const tail_bytes = stream.len - offset;
    if (tail_bytes == 0) return recoveryClassificationV1(
        .clean,
        anchor,
        last_sequence,
        committed_records,
        offset,
        0,
        final_record_sha256,
    );
    if (tail_bytes < body_bytes) return recoveryClassificationV1(
        .short_body_tail,
        anchor,
        last_sequence,
        committed_records,
        offset,
        tail_bytes,
        final_record_sha256,
    );

    const body = stream[offset .. offset + body_bytes];
    const decoded_body = decodeBodyForRecoveryV1(body) catch
        return recoveryClassificationV1(
            .corrupt_record,
            anchor,
            last_sequence,
            committed_records,
            offset,
            tail_bytes,
            final_record_sha256,
        );
    if (!recoveryRecordMatchesV1(
        &decoded_body,
        anchor.record_epoch,
        expected_sequence,
        expected_previous,
    )) return recoveryClassificationV1(
        .corrupt_record,
        anchor,
        last_sequence,
        committed_records,
        offset,
        tail_bytes,
        final_record_sha256,
    );

    if (tail_bytes == body_bytes) return recoveryClassificationV1(
        .body_without_footer,
        anchor,
        last_sequence,
        committed_records,
        offset,
        tail_bytes,
        final_record_sha256,
    );

    var expected_footer: [commit_footer_bytes]u8 = undefined;
    buildExpectedFooterV1(body, &expected_footer);
    const partial_footer = stream[offset + body_bytes ..];
    if (!std.mem.eql(
        u8,
        partial_footer,
        expected_footer[0..partial_footer.len],
    )) return recoveryClassificationV1(
        .corrupt_record,
        anchor,
        last_sequence,
        committed_records,
        offset,
        tail_bytes,
        final_record_sha256,
    );
    return recoveryClassificationV1(
        .partial_footer_tail,
        anchor,
        last_sequence,
        committed_records,
        offset,
        tail_bytes,
        final_record_sha256,
    );
}

pub fn recordRootV1(prefix: []const u8) Error!Digest {
    if (prefix.len != body_prefix_bytes) return Error.InvalidLength;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(record_domain);
    hash.update(prefix);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn validateInputV1(input: InputV1) Error!void {
    if (input.record_epoch == 0 or input.sequence == 0 or
        isZero(input.record_challenge_sha256))
        return Error.InvalidSweepRecord;
    if ((input.sequence == 1) != isZero(input.previous_record_sha256))
        return Error.InvalidSweepRecord;
    sweep.verifyCommitReceiptV1(
        input.commit_grant,
        input.commit_receipt,
        input.store_receipt,
    ) catch return Error.InvalidSweepRecord;
}

fn validateExpectationV1(expected: ExpectationV1) Error!void {
    if (expected.record_epoch == 0 or expected.sequence == 0 or
        isZero(expected.sweep_commit_sha256) or
        isZero(expected.record_sha256) or
        ((expected.sequence == 1) !=
            isZero(expected.previous_record_sha256)))
        return Error.RecordExpectationMismatch;
}

fn validateRecoveryAnchorV1(anchor: RecoveryAnchorV1) Error!void {
    if (anchor.record_epoch == 0 or anchor.next_sequence == 0 or
        ((anchor.next_sequence == 1) !=
            isZero(anchor.previous_record_sha256)))
        return Error.InvalidRecoveryAnchor;
}

fn recoveryRecordMatchesV1(
    decoded: *const DecodedV1,
    record_epoch: u64,
    sequence: u64,
    previous_record_sha256: Digest,
) bool {
    return decoded.input.record_epoch == record_epoch and
        decoded.input.sequence == sequence and
        std.mem.eql(
            u8,
            &decoded.input.previous_record_sha256,
            &previous_record_sha256,
        );
}

fn decodeBodyForRecoveryV1(body: []const u8) Error!DecodedV1 {
    if (body.len != body_bytes) return Error.InvalidLength;
    var encoded: [encoded_bytes]u8 = undefined;
    @memcpy(encoded[0..body_bytes], body);
    buildExpectedFooterV1(body, encoded[body_bytes..encoded_bytes]);
    return decodeV1(&encoded);
}

fn buildExpectedFooterV1(body: []const u8, footer: []u8) void {
    std.debug.assert(body.len == body_bytes);
    std.debug.assert(footer.len == commit_footer_bytes);
    @memcpy(footer[0..commit_magic.len], &commit_magic);
    @memcpy(
        footer[commit_magic.len .. commit_magic.len + @sizeOf(u64)],
        body[sequence_offset .. sequence_offset + @sizeOf(u64)],
    );
    @memcpy(
        footer[commit_magic.len + @sizeOf(u64) .. commit_footer_bytes],
        body[body_prefix_bytes..body_bytes],
    );
}

fn recoveryClassificationV1(
    status: RecoveryStatusV1,
    anchor: RecoveryAnchorV1,
    last_sequence: u64,
    committed_records: u64,
    committed_bytes: usize,
    tail_bytes: usize,
    final_record_sha256: Digest,
) RecoveryClassificationV1 {
    return .{
        .status = status,
        .record_epoch = anchor.record_epoch,
        .first_sequence = anchor.next_sequence,
        .last_sequence = last_sequence,
        .committed_records = committed_records,
        .committed_bytes = committed_bytes,
        .tail_bytes = tail_bytes,
        .final_record_sha256 = final_record_sha256,
    };
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        const end = std.math.add(usize, self.position, value.len) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        std.mem.copyForwards(u8, self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeU64(self: *Writer, value: u64) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        try self.writeBytes(&value);
    }

    fn writeAccounting(
        self: *Writer,
        value: object_store.LogicalAccountingV1,
    ) Error!void {
        try self.writeU64(value.entry_count);
        try self.writeU64(value.live_entries);
        try self.writeU64(value.quarantined_entries);
        try self.writeU64(value.retired_entries);
        try self.writeU64(value.payload_bytes);
        try self.writeU64(value.logical_index_bytes);
        try self.writeU64(value.reference_count);
        try self.writeU64(value.active_leases);
        try self.writeU64(value.repair_count);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(self: *Reader, length: usize) Error![]const u8 {
        const end = std.math.add(usize, self.position, length) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        const value = self.bytes[self.position..end];
        self.position = end;
        return value;
    }

    fn readU32(self: *Reader) Error!u32 {
        var bytes: [4]u8 = undefined;
        @memcpy(&bytes, try self.readBytes(bytes.len));
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        var bytes: [8]u8 = undefined;
        @memcpy(&bytes, try self.readBytes(bytes.len));
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        var value: Digest = undefined;
        @memcpy(&value, try self.readBytes(digest_bytes));
        return value;
    }

    fn readAccounting(self: *Reader) Error!object_store.LogicalAccountingV1 {
        return .{
            .entry_count = try self.readU64(),
            .live_entries = try self.readU64(),
            .quarantined_entries = try self.readU64(),
            .retired_entries = try self.readU64(),
            .payload_bytes = try self.readU64(),
            .logical_index_bytes = try self.readU64(),
            .reference_count = try self.readU64(),
            .active_leases = try self.readU64(),
            .repair_count = try self.readU64(),
        };
    }
};

fn testDigest(byte: u8) Digest {
    return [_]u8{byte} ** digest_bytes;
}

fn testInput(commit_challenge: u8, record_challenge: u8) InputV1 {
    const commit_grant: sweep.CommitGrantV1 = .{
        .authority_epoch = 11,
        .tenant_scope_sha256 = testDigest(0x61),
        .bundle_sha256 = testDigest(0x62),
        .store_grant_sha256 = testDigest(0x63),
        .sweep_grant_sha256 = testDigest(0x64),
        .prepare_sha256 = testDigest(0x65),
        .expected_snapshot_sha256 = testDigest(0x66),
        .collection_plan_sha256 = testDigest(0x67),
        .max_freed_entries = 2,
        .max_freed_bytes = 128,
        .challenge_sha256 = testDigest(commit_challenge),
    };
    const commit_grant_sha256 = sweep.commitGrantRootV1(commit_grant) catch
        unreachable;
    var store_receipt: object_store.RetiredCommitReceiptV1 = .{
        .authorization_sha256 = commit_grant_sha256,
        .targets_sha256 = testDigest(0x68),
        .snapshot_before_sha256 = commit_grant.expected_snapshot_sha256,
        .snapshot_after_sha256 = testDigest(0x69),
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
        .freed_index_bytes = 128,
        .freed_repair_count = 0,
        .allocator_deallocation_calls = 1,
        .commit_sha256 = capsule.zero_digest,
    };
    store_receipt.commit_sha256 =
        object_store.retiredCommitReceiptRootV1(store_receipt);
    var commit_receipt: sweep.CommitReceiptV1 = .{
        .commit_grant_sha256 = commit_grant_sha256,
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
        .record_challenge_sha256 = testDigest(record_challenge),
        .commit_grant = commit_grant,
        .commit_receipt = commit_receipt,
        .store_receipt = store_receipt,
    };
}

fn resealRecordForTest(encoded: []u8) void {
    const root = recordRootV1(encoded[0..body_prefix_bytes]) catch unreachable;
    @memcpy(encoded[body_prefix_bytes..body_bytes], &root);
    @memcpy(
        encoded[body_bytes + commit_magic.len + 8 .. encoded_bytes],
        &root,
    );
}

fn testRecoveryAnchor() RecoveryAnchorV1 {
    return .{
        .record_epoch = 0x5357_4545_5000_0001,
        .next_sequence = 1,
        .previous_record_sha256 = capsule.zero_digest,
    };
}

fn encodeTestStreamV1(storage: []u8, record_count: usize) Error![]const u8 {
    const length = std.math.mul(
        usize,
        record_count,
        encoded_bytes,
    ) catch return Error.InvalidLength;
    if (record_count > 3 or storage.len < length) return Error.InvalidLength;
    var previous_record_sha256 = capsule.zero_digest;
    for (0..record_count) |index| {
        const byte_offset: u8 = @intCast(index);
        var input = testInput(0x6a + byte_offset, 0x6b + byte_offset);
        input.sequence = @as(u64, @intCast(index)) + 1;
        input.previous_record_sha256 = previous_record_sha256;
        const offset = index * encoded_bytes;
        const encoded = try encodeV1(
            input,
            storage[offset .. offset + encoded_bytes],
        );
        previous_record_sha256 = (try decodeV1(encoded)).record_sha256;
    }
    return storage[0..length];
}

test "sweep record round trips exact commit evidence and append plan" {
    const input = testInput(0x6a, 0x6b);
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(input, &storage);
    const decoded = try decodeV1(encoded);
    try std.testing.expect(std.meta.eql(input, decoded.input));
    const expected = try expectationV1(input, decoded.record_sha256);
    const verified = try decodeAndVerifyV1(encoded, expected);
    try std.testing.expect(std.meta.eql(decoded, verified));
    const plan = try appendPlanV1(encoded);
    try std.testing.expectEqual(@as(usize, 704), body_prefix_bytes);
    try std.testing.expectEqual(@as(usize, 736), body_bytes);
    try std.testing.expectEqual(@as(usize, 48), commit_footer_bytes);
    try std.testing.expectEqual(@as(usize, 784), encoded_bytes);
    try std.testing.expectEqual(body_bytes, plan.body.len);
    try std.testing.expectEqual(commit_footer_bytes, plan.commit_footer.len);
    const record_hex = std.fmt.bytesToHex(decoded.record_sha256, .lower);
    try std.testing.expectEqualStrings(
        "a9adfd0946468252bd879acc81456e2afe2e145b38f850869c75fd471d0bba06",
        &record_hex,
    );
    var encoded_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &encoded_sha256, .{});
    const encoded_hex = std.fmt.bytesToHex(encoded_sha256, .lower);
    try std.testing.expectEqualStrings(
        "3b3fb1adf8ed0b13b8e8719a3ade7dbb2a7133c0ea6d307598ee3b2941d7c6d3",
        &encoded_hex,
    );

    var chained = input;
    chained.sequence = 2;
    chained.previous_record_sha256 = decoded.record_sha256;
    var chained_storage: [encoded_bytes]u8 = undefined;
    const chained_encoded = try encodeV1(chained, &chained_storage);
    const chained_decoded = try decodeV1(chained_encoded);
    try std.testing.expectEqual(@as(u64, 2), chained_decoded.input.sequence);
    try std.testing.expectEqualSlices(
        u8,
        &decoded.record_sha256,
        &chained_decoded.input.previous_record_sha256,
    );
}

test "sweep record rejects every byte mutation truncation and extension" {
    const input = testInput(0x6a, 0x6b);
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(input, &storage);
    for (0..encoded.len) |index| {
        var corrupted = storage;
        corrupted[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidSweepRecord,
            normalizeDecodeError(decodeV1(&corrupted)),
        );
    }
    for (0..encoded.len) |length| {
        try std.testing.expectError(
            Error.InvalidSweepRecord,
            normalizeDecodeError(decodeV1(encoded[0..length])),
        );
    }
    var extended: [encoded_bytes + 1]u8 = undefined;
    @memcpy(extended[0..encoded_bytes], encoded);
    extended[encoded_bytes] = 0;
    try std.testing.expectError(
        Error.InvalidSweepRecord,
        normalizeDecodeError(decodeV1(&extended)),
    );
}

test "sweep record rejects rehashed contradiction and valid foreign record" {
    const input = testInput(0x6a, 0x6b);
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(input, &storage);
    const decoded = try decodeV1(encoded);
    const expected = try expectationV1(input, decoded.record_sha256);

    var contradiction = storage;
    contradiction[accounting_before_offset] += 1;
    resealRecordForTest(&contradiction);
    try std.testing.expectError(
        Error.InvalidSweepRecord,
        normalizeDecodeError(decodeV1(&contradiction)),
    );

    const foreign_input = testInput(0x7a, 0x7b);
    var foreign_storage: [encoded_bytes]u8 = undefined;
    const foreign = try encodeV1(foreign_input, &foreign_storage);
    _ = try decodeV1(foreign);
    try std.testing.expectError(
        Error.RecordExpectationMismatch,
        decodeAndVerifyV1(foreign, expected),
    );
}

test "sweep record encode failure leaves caller output unchanged" {
    const input = testInput(0x6a, 0x6b);
    var insufficient = [_]u8{0xa5} ** (encoded_bytes - 1);
    try std.testing.expectError(
        Error.InvalidLength,
        encodeV1(input, &insufficient),
    );
    try std.testing.expect(std.mem.allEqual(u8, &insufficient, 0xa5));

    var invalid = input;
    invalid.sequence = 2;
    var output = [_]u8{0x5a} ** encoded_bytes;
    try std.testing.expectError(Error.InvalidSweepRecord, encodeV1(invalid, &output));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0x5a));
    try std.testing.expectError(Error.InvalidLength, recordRootV1(&[_]u8{}));
}

test "recovery classifier verifies clean origin and anchored suffix chains" {
    var storage: [encoded_bytes * 3]u8 = undefined;
    const stream = try encodeTestStreamV1(&storage, 3);
    const anchor = testRecoveryAnchor();

    const empty = try classifyRecoveryV1(&[_]u8{}, anchor);
    try std.testing.expectEqual(RecoveryStatusV1.clean, empty.status);
    try std.testing.expectEqual(@as(u64, 0), empty.committed_records);
    try std.testing.expectEqual(@as(u64, 0), empty.last_sequence);
    try std.testing.expectEqual(@as(usize, 0), empty.committed_bytes);
    try std.testing.expectEqualSlices(
        u8,
        &capsule.zero_digest,
        &empty.final_record_sha256,
    );

    const clean = try classifyRecoveryV1(stream, anchor);
    try std.testing.expectEqual(RecoveryStatusV1.clean, clean.status);
    try std.testing.expectEqual(@as(u64, 3), clean.committed_records);
    try std.testing.expectEqual(@as(u64, 1), clean.first_sequence);
    try std.testing.expectEqual(@as(u64, 3), clean.last_sequence);
    try std.testing.expectEqual(stream.len, clean.committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), clean.tail_bytes);
    var stream_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(stream, &stream_sha256, .{});
    const stream_hex = std.fmt.bytesToHex(stream_sha256, .lower);
    try std.testing.expectEqualStrings(
        "03c9ce6901d43ef0a7b262e003dc59a1ee1259cdb4fe9b9c28a0a429ac0396bf",
        &stream_hex,
    );

    const first = try decodeV1(stream[0..encoded_bytes]);
    const suffix_anchor: RecoveryAnchorV1 = .{
        .record_epoch = anchor.record_epoch,
        .next_sequence = 2,
        .previous_record_sha256 = first.record_sha256,
    };
    const empty_suffix = try classifyRecoveryV1(&[_]u8{}, suffix_anchor);
    try std.testing.expectEqual(RecoveryStatusV1.clean, empty_suffix.status);
    try std.testing.expectEqual(@as(u64, 0), empty_suffix.committed_records);
    try std.testing.expectEqual(@as(u64, 1), empty_suffix.last_sequence);
    try std.testing.expectEqualSlices(
        u8,
        &first.record_sha256,
        &empty_suffix.final_record_sha256,
    );
    const suffix = try classifyRecoveryV1(stream[encoded_bytes..], suffix_anchor);
    try std.testing.expectEqual(RecoveryStatusV1.clean, suffix.status);
    try std.testing.expectEqual(@as(u64, 2), suffix.committed_records);
    try std.testing.expectEqual(@as(u64, 2), suffix.first_sequence);
    try std.testing.expectEqual(@as(u64, 3), suffix.last_sequence);
    try std.testing.expectEqualSlices(
        u8,
        &clean.final_record_sha256,
        &suffix.final_record_sha256,
    );
}

test "recovery classifier names every body and footer crash boundary" {
    var storage: [encoded_bytes * 2]u8 = undefined;
    const stream = try encodeTestStreamV1(&storage, 2);
    const anchor = testRecoveryAnchor();
    const first = try decodeV1(stream[0..encoded_bytes]);
    const second = try decodeV1(stream[encoded_bytes .. encoded_bytes * 2]);
    var stream_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(stream, &stream_sha256, .{});
    const stream_hex = std.fmt.bytesToHex(stream_sha256, .lower);
    try std.testing.expectEqualStrings(
        "25009ee1f7e27989e54554fc797f19cec21dd96d3c392f25364d7ab868ee5538",
        &stream_hex,
    );

    for (0..encoded_bytes + 1) |tail_length| {
        const classified = try classifyRecoveryV1(
            stream[0 .. encoded_bytes + tail_length],
            anchor,
        );
        const expected_status: RecoveryStatusV1 = if (tail_length == 0 or
            tail_length == encoded_bytes)
            .clean
        else if (tail_length < body_bytes)
            .short_body_tail
        else if (tail_length == body_bytes)
            .body_without_footer
        else
            .partial_footer_tail;
        try std.testing.expectEqual(expected_status, classified.status);
        const expected_records: u64 = if (tail_length == encoded_bytes) 2 else 1;
        try std.testing.expectEqual(expected_records, classified.committed_records);
        try std.testing.expectEqual(
            expected_records * encoded_bytes,
            classified.committed_bytes,
        );
        try std.testing.expectEqual(
            if (tail_length == encoded_bytes) 0 else tail_length,
            classified.tail_bytes,
        );
        try std.testing.expectEqualSlices(
            u8,
            if (tail_length == encoded_bytes)
                &second.record_sha256
            else
                &first.record_sha256,
            &classified.final_record_sha256,
        );
    }

    var corrupt_partial = storage;
    corrupt_partial[encoded_bytes + body_bytes] ^= 1;
    const classified = try classifyRecoveryV1(
        corrupt_partial[0 .. encoded_bytes + body_bytes + 1],
        anchor,
    );
    try std.testing.expectEqual(RecoveryStatusV1.corrupt_record, classified.status);
    try std.testing.expectEqual(@as(u64, 1), classified.committed_records);
}

test "recovery classifier rejects every complete mutation and foreign chain" {
    var storage: [encoded_bytes * 2]u8 = undefined;
    const stream = try encodeTestStreamV1(&storage, 2);
    const anchor = testRecoveryAnchor();
    const first = try decodeV1(stream[0..encoded_bytes]);

    for (0..encoded_bytes) |index| {
        var corrupted = storage;
        corrupted[encoded_bytes + index] ^= 1;
        const classified = try classifyRecoveryV1(&corrupted, anchor);
        try std.testing.expectEqual(
            RecoveryStatusV1.corrupt_record,
            classified.status,
        );
        try std.testing.expectEqual(@as(u64, 1), classified.committed_records);
        try std.testing.expectEqual(encoded_bytes, classified.committed_bytes);
    }

    var contradiction = storage;
    contradiction[encoded_bytes + accounting_before_offset] += 1;
    resealRecordForTest(contradiction[encoded_bytes .. encoded_bytes * 2]);
    const contradictory = try classifyRecoveryV1(&contradiction, anchor);
    try std.testing.expectEqual(
        RecoveryStatusV1.corrupt_record,
        contradictory.status,
    );

    var foreign_storage: [encoded_bytes * 2]u8 = undefined;
    @memcpy(foreign_storage[0..encoded_bytes], stream[0..encoded_bytes]);
    var foreign = testInput(0x7a, 0x7b);
    foreign.sequence = 2;
    foreign.previous_record_sha256 = testDigest(0x7c);
    _ = try encodeV1(foreign, foreign_storage[encoded_bytes..]);
    const wrong_previous = try classifyRecoveryV1(&foreign_storage, anchor);
    try std.testing.expectEqual(
        RecoveryStatusV1.corrupt_record,
        wrong_previous.status,
    );

    foreign.record_epoch += 1;
    foreign.previous_record_sha256 = first.record_sha256;
    _ = try encodeV1(foreign, foreign_storage[encoded_bytes..]);
    const wrong_epoch = try classifyRecoveryV1(&foreign_storage, anchor);
    try std.testing.expectEqual(RecoveryStatusV1.corrupt_record, wrong_epoch.status);

    foreign.record_epoch = anchor.record_epoch;
    foreign.sequence = 3;
    _ = try encodeV1(foreign, foreign_storage[encoded_bytes..]);
    const wrong_sequence = try classifyRecoveryV1(&foreign_storage, anchor);
    try std.testing.expectEqual(
        RecoveryStatusV1.corrupt_record,
        wrong_sequence.status,
    );
}

test "recovery classifier rejects invalid caller anchors" {
    const valid = testRecoveryAnchor();
    var invalid = valid;
    invalid.record_epoch = 0;
    try std.testing.expectError(
        Error.InvalidRecoveryAnchor,
        classifyRecoveryV1(&[_]u8{}, invalid),
    );
    invalid = valid;
    invalid.next_sequence = 2;
    try std.testing.expectError(
        Error.InvalidRecoveryAnchor,
        classifyRecoveryV1(&[_]u8{}, invalid),
    );
    invalid = valid;
    invalid.previous_record_sha256 = testDigest(0x81);
    try std.testing.expectError(
        Error.InvalidRecoveryAnchor,
        classifyRecoveryV1(&[_]u8{}, invalid),
    );

    var terminal_input = testInput(0x82, 0x83);
    terminal_input.sequence = std.math.maxInt(u64);
    terminal_input.previous_record_sha256 = testDigest(0x84);
    var terminal_storage: [encoded_bytes + 1]u8 = undefined;
    _ = try encodeV1(
        terminal_input,
        terminal_storage[0..encoded_bytes],
    );
    const terminal_anchor: RecoveryAnchorV1 = .{
        .record_epoch = terminal_input.record_epoch,
        .next_sequence = terminal_input.sequence,
        .previous_record_sha256 = terminal_input.previous_record_sha256,
    };
    const terminal = try classifyRecoveryV1(
        terminal_storage[0..encoded_bytes],
        terminal_anchor,
    );
    try std.testing.expectEqual(RecoveryStatusV1.clean, terminal.status);
    terminal_storage[encoded_bytes] = 0;
    const overflow = try classifyRecoveryV1(&terminal_storage, terminal_anchor);
    try std.testing.expectEqual(RecoveryStatusV1.corrupt_record, overflow.status);
    try std.testing.expectEqual(@as(u64, 1), overflow.committed_records);
}

fn normalizeDecodeError(result: Error!DecodedV1) Error!DecodedV1 {
    return result catch return Error.InvalidSweepRecord;
}
