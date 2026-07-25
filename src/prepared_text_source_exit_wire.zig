//! Canonical wire encoding for a prepared-text source-exit receipt.
//!
//! This module is intentionally independent of source and target lease state.
//! Both sides use the same decoder so a selector claim cannot advance over an
//! authority archive that merely has plausible outer metadata.

const std = @import("std");
const core = @import("core");
const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;

pub const Digest = [32]u8;
pub const wire_abi: u64 = 0x4750_5458_0000_0001;
pub const wire_magic =
    [_]u8{ 'G', 'P', 'T', 'E', 'X', 'I', '1', 0 };
pub const wire_bytes: usize = 640;
pub const wire_body_bytes: usize = wire_bytes - 32;
pub const wire_flags: u64 = 0;

const wire_domain =
    "glacier-prepared-text-source-exit-wire-v1\x00";

pub const Error = error{
    InvalidLength,
    InvalidSourceExit,
    UnsafeDestination,
};

pub fn encodeV1(
    receipt: lane.SourceExitReceiptV1,
    destination: []u8,
) Error![]u8 {
    if (destination.len != wire_bytes)
        return Error.InvalidLength;
    if (!lane.sourceExitReceiptStructurallyValidV1(receipt))
        return Error.InvalidSourceExit;
    var local: [wire_bytes]u8 = undefined;
    writeBodyV1(
        receipt,
        local[0..wire_body_bytes],
    );
    const root = rootV1(local[0..wire_body_bytes]);
    @memcpy(local[wire_body_bytes..], &root);
    if (slicesOverlap(destination, local[0..]))
        return Error.UnsafeDestination;
    @memcpy(destination, &local);
    return destination;
}

pub fn decodeV1(
    encoded: []const u8,
) Error!lane.SourceExitReceiptV1 {
    if (encoded.len != wire_bytes)
        return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &wire_magic) or
        readU64(encoded, 8) != wire_abi or
        readU64(encoded, 16) != wire_bytes or
        readU64(encoded, 24) != wire_flags or
        !digestEqual(
            encoded[wire_body_bytes..][0..32].*,
            rootV1(encoded[0..wire_body_bytes]),
        ))
        return Error.InvalidSourceExit;

    var reader: Reader = .{
        .bytes = encoded[32..wire_body_bytes],
    };
    const scheduler_epoch = try reader.readU64();
    const coordinator_id = try reader.readU64();
    const handoff_generation = try reader.readU64();
    const handle_scheduler_epoch = try reader.readU64();
    const handle_slot_index = try reader.readU32AsU64();
    const handle_slot_generation = try reader.readU64();
    const handle_tenant_key = try reader.readU64();
    const handle_request_key = try reader.readU64();
    const handle_request_generation = try reader.readU64();
    const publication_request_epoch = try reader.readU64();
    const expected_next_sequence = try reader.readU64();
    const source_last_generation = try reader.readU64();
    const source_receipt = try reader.readReceipt();
    const cancel_event_sequence = try reader.readU64();
    const value: lane.SourceExitReceiptV1 = .{
        .scheduler_epoch = scheduler_epoch,
        .coordinator_id = coordinator_id,
        .handoff_generation = handoff_generation,
        .handle = .{
            .scheduler_epoch = handle_scheduler_epoch,
            .slot_index = handle_slot_index,
            .slot_generation = handle_slot_generation,
            .tenant_key = handle_tenant_key,
            .request_key = handle_request_key,
            .request_generation = handle_request_generation,
        },
        .publication_request_epoch = publication_request_epoch,
        .expected_next_sequence = expected_next_sequence,
        .source_last_publication_permit_generation = source_last_generation,
        .source_receipt = source_receipt,
        .source_receipt_sha256 = try reader.readDigest(),
        .scheduler_chain_head_before_sha256 = try reader.readDigest(),
        .checkpoint_sha256 = try reader.readDigest(),
        .successor_segment_sha256 = try reader.readDigest(),
        .target_ownership_intent_sha256 = try reader.readDigest(),
        .prepared_archive_sha256 = try reader.readDigest(),
        .predecessor_selector_sha256 = try reader.readDigest(),
        .cancel_event_sequence = cancel_event_sequence,
        .cancel_event_sha256 = try reader.readDigest(),
        .source_exit_sha256 = try reader.readDigest(),
    };
    if (!allZero(reader.remaining()) or
        !lane.sourceExitReceiptStructurallyValidV1(value))
        return Error.InvalidSourceExit;
    return value;
}

pub fn rootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(wire_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn writeBodyV1(
    value: lane.SourceExitReceiptV1,
    destination: []u8,
) void {
    std.debug.assert(destination.len == wire_body_bytes);
    @memset(destination, 0);
    @memcpy(destination[0..8], &wire_magic);
    writeU64(destination, 8, wire_abi);
    writeU64(destination, 16, wire_bytes);
    writeU64(destination, 24, wire_flags);
    var writer: Writer = .{ .bytes = destination[32..] };
    writer.writeU64(value.scheduler_epoch);
    writer.writeU64(value.coordinator_id);
    writer.writeU64(value.handoff_generation);
    writer.writeU64(value.handle.scheduler_epoch);
    writer.writeU64(value.handle.slot_index);
    writer.writeU64(value.handle.slot_generation);
    writer.writeU64(value.handle.tenant_key);
    writer.writeU64(value.handle.request_key);
    writer.writeU64(value.handle.request_generation);
    writer.writeU64(value.publication_request_epoch);
    writer.writeU64(value.expected_next_sequence);
    writer.writeU64(
        value.source_last_publication_permit_generation,
    );
    writer.writeReceipt(value.source_receipt);
    writer.writeU64(value.cancel_event_sequence);
    writer.writeDigest(value.source_receipt_sha256);
    writer.writeDigest(
        value.scheduler_chain_head_before_sha256,
    );
    writer.writeDigest(value.checkpoint_sha256);
    writer.writeDigest(value.successor_segment_sha256);
    writer.writeDigest(
        value.target_ownership_intent_sha256,
    );
    writer.writeDigest(value.prepared_archive_sha256);
    writer.writeDigest(value.predecessor_selector_sha256);
    writer.writeDigest(value.cancel_event_sha256);
    writer.writeDigest(value.source_exit_sha256);
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeU64(self: *Writer, value: anytype) void {
        std.debug.assert(self.position + 8 <= self.bytes.len);
        std.mem.writeInt(
            u64,
            self.bytes[self.position..][0..8],
            @intCast(value),
            .little,
        );
        self.position += 8;
    }

    fn writeDigest(self: *Writer, value: Digest) void {
        std.debug.assert(self.position + 32 <= self.bytes.len);
        @memcpy(
            self.bytes[self.position .. self.position + 32],
            &value,
        );
        self.position += 32;
    }

    fn writeClaim(
        self: *Writer,
        value: resource_bank.Claim,
    ) void {
        inline for (std.meta.fields(resource_bank.Claim)) |field| {
            self.writeU64(@field(value, field.name));
        }
    }

    fn writeReceipt(
        self: *Writer,
        value: resource_bank.Receipt,
    ) void {
        self.writeU64(value.bank_epoch);
        self.writeU64(value.slot_index);
        self.writeU64(value.generation);
        self.writeU64(value.owner_key);
        self.writeClaim(value.claim);
        self.writeU64(value.integrity);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readU64(self: *Reader) Error!u64 {
        if (self.position + 8 > self.bytes.len)
            return Error.InvalidSourceExit;
        const value = std.mem.readInt(
            u64,
            self.bytes[self.position..][0..8],
            .little,
        );
        self.position += 8;
        return value;
    }

    fn readU32AsU64(self: *Reader) Error!u32 {
        const value = try self.readU64();
        return std.math.cast(u32, value) orelse
            Error.InvalidSourceExit;
    }

    fn readDigest(self: *Reader) Error!Digest {
        if (self.position + 32 > self.bytes.len)
            return Error.InvalidSourceExit;
        const value = self.bytes[self.position..][0..32].*;
        self.position += 32;
        return value;
    }

    fn readClaim(self: *Reader) Error!resource_bank.Claim {
        var value: resource_bank.Claim = .{};
        inline for (std.meta.fields(resource_bank.Claim)) |field| {
            @field(value, field.name) = try self.readU64();
        }
        return value;
    }

    fn readReceipt(self: *Reader) Error!resource_bank.Receipt {
        const bank_epoch = try self.readU64();
        const slot_index = try self.readU32AsU64();
        const generation = try self.readU64();
        const owner_key = try self.readU64();
        const claim = try self.readClaim();
        const integrity = try self.readU64();
        return .{
            .bank_epoch = bank_epoch,
            .slot_index = slot_index,
            .generation = generation,
            .owner_key = owner_key,
            .claim = claim,
            .integrity = integrity,
        };
    }

    fn remaining(self: *const Reader) []const u8 {
        return self.bytes[self.position..];
    }
};

fn writeU64(destination: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(
        u64,
        destination[offset..][0..8],
        value,
        .little,
    );
}

fn readU64(source: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        source[offset..][0..8],
        .little,
    );
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = left_start + left.len;
    const right_end = right_start + right.len;
    return left_start < right_end and right_start < left_end;
}
