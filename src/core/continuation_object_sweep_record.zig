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

fn normalizeDecodeError(result: Error!DecodedV1) Error!DecodedV1 {
    return result catch return Error.InvalidSweepRecord;
}
