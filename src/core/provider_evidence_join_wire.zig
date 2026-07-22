//! Canonical root manifest joining one provider attempt across evidence planes.
//!
//! The fixed-size wire does not duplicate the journal, Gateway history or
//! transport transcript. Instead it binds their verified roots and the exact
//! request/attempt/cost identities. Decoding requires the original evidence
//! blobs and independently replays every nested verifier before accepting the
//! join. The manifest grants no dispatch, append, lock or recovery authority.

const std = @import("std");
const gateway = @import("provider_token_gateway.zig");
const journal = @import("provider_cost_journal.zig");
const gateway_wire = @import("provider_gateway_event_wire.zig");
const transport_wire = @import("provider_transport_event_wire.zig");

pub const Digest = gateway.Digest;
pub const wire_abi: u64 = 0x4750_4a4f_0000_0001;
pub const magic = [_]u8{ 'G', 'P', 'J', 'O', 'I', 'N', 'R', '1' };
pub const flag_require_closed: u32 = 1 << 0;
pub const allowed_flags: u32 = flag_require_closed;

const envelope_domain = "glacier-provider-evidence-join-wire-v1\x00";
const digest_bytes = @sizeOf(Digest);
pub const digest_field_count: usize = 20;
pub const header_bytes: usize = magic.len + 8 + 8 + 4 + 4 + 8 + 4 + 4 + 8 * 3;
pub const encoded_bytes: usize = header_bytes + digest_field_count * digest_bytes;

pub const Error = error{
    CapacityExceeded,
    InvalidStorage,
    InvalidMagic,
    InvalidAbi,
    InvalidLength,
    InvalidFlags,
    InvalidEnvelope,
    InvalidEvidence,
    InvalidComposition,
};

pub const ScratchV1 = struct {
    gateway_events: []gateway.EventV2,
    gateway_owners: []gateway_wire.ReplayOwnerV1,
    gateway_consumers: []gateway_wire.ReplayConsumerV1,
    gateway_bindings: []gateway_wire.SettlementBindingV1,
    transport_events: []transport_wire.EventV1,
};

pub const DecodedV1 = struct {
    flags: u32 = flag_require_closed,
    journal_sequence: u64 = 0,
    gateway_event_index: u32 = 0,
    transport_event_count: u32 = 0,
    journal_frame_bytes: u64 = 0,
    gateway_wire_bytes: u64 = 0,
    transport_wire_bytes: u64 = 0,
    journal_header_sha256: Digest = gateway.zero_digest,
    journal_previous_chain_sha256: Digest = gateway.zero_digest,
    journal_entry_sha256: Digest = gateway.zero_digest,
    cost_envelope_sha256: Digest = gateway.zero_digest,
    settlement_envelope_sha256: Digest = gateway.zero_digest,
    request_sha256: Digest = gateway.zero_digest,
    dispatch_key_sha256: Digest = gateway.zero_digest,
    intent_sha256: Digest = gateway.zero_digest,
    receipt_sha256: Digest = gateway.zero_digest,
    price_sha256: Digest = gateway.zero_digest,
    quote_sha256: Digest = gateway.zero_digest,
    cost_settlement_sha256: Digest = gateway.zero_digest,
    gateway_envelope_sha256: Digest = gateway.zero_digest,
    gateway_event_sha256: Digest = gateway.zero_digest,
    gateway_final_chain_sha256: Digest = gateway.zero_digest,
    transport_envelope_sha256: Digest = gateway.zero_digest,
    provider_request_sha256: Digest = gateway.zero_digest,
    response_chain_sha256: Digest = gateway.zero_digest,
    transport_outcome_sha256: Digest = gateway.zero_digest,
    envelope_sha256: Digest = gateway.zero_digest,
};

const TerminalRootsV1 = struct {
    provider_request_sha256: Digest,
    response_chain_sha256: Digest,
    outcome_sha256: Digest,
};

pub fn encodeV1(
    header: journal.HeaderV1,
    journal_sequence: u64,
    journal_previous_chain_sha256: Digest,
    encoded_frame: []const u8,
    gateway_event_index: u32,
    encoded_gateway: []const u8,
    encoded_transport: []const u8,
    scratch: ScratchV1,
    destination: []u8,
) Error![]const u8 {
    if (destination.len < encoded_bytes) return Error.CapacityExceeded;
    const output = destination[0..encoded_bytes];
    if (slicesOverlap(u8, encoded_frame, u8, output) or
        slicesOverlap(u8, encoded_gateway, u8, output) or
        slicesOverlap(u8, encoded_transport, u8, output) or
        overlapsScratch(output, scratch) or
        invalidScratchLayout(
            encoded_frame,
            encoded_gateway,
            encoded_transport,
            scratch,
        ))
        return Error.InvalidStorage;

    const value = try composeV1(
        header,
        journal_sequence,
        journal_previous_chain_sha256,
        encoded_frame,
        gateway_event_index,
        encoded_gateway,
        encoded_transport,
        scratch,
    );
    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&magic);
    try writer.writeU64(wire_abi);
    try writer.writeU64(encoded_bytes);
    try writer.writeU32(value.flags);
    try writer.writeU32(0);
    try writer.writeU64(value.journal_sequence);
    try writer.writeU32(value.gateway_event_index);
    try writer.writeU32(value.transport_event_count);
    try writer.writeU64(value.journal_frame_bytes);
    try writer.writeU64(value.gateway_wire_bytes);
    try writer.writeU64(value.transport_wire_bytes);
    try writeDigests(&writer, value);
    if (writer.position + digest_bytes != output.len)
        return Error.InvalidLength;
    try writer.writeDigest(envelopeSha256(output[0..writer.position]));
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

pub fn decodeAndVerifyV1(
    encoded: []const u8,
    header: journal.HeaderV1,
    encoded_frame: []const u8,
    encoded_gateway: []const u8,
    encoded_transport: []const u8,
    scratch: ScratchV1,
) Error!DecodedV1 {
    if (encoded.len != encoded_bytes) return Error.InvalidLength;
    if (overlapsScratch(encoded, scratch) or invalidScratchLayout(
        encoded_frame,
        encoded_gateway,
        encoded_transport,
        scratch,
    ))
        return Error.InvalidStorage;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(magic.len), &magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != wire_abi) return Error.InvalidAbi;
    if (try reader.readU64() != encoded_bytes) return Error.InvalidLength;
    var value: DecodedV1 = .{};
    value.flags = try reader.readU32();
    if (value.flags != flag_require_closed or try reader.readU32() != 0)
        return Error.InvalidFlags;
    value.journal_sequence = try reader.readU64();
    value.gateway_event_index = try reader.readU32();
    value.transport_event_count = try reader.readU32();
    value.journal_frame_bytes = try reader.readU64();
    value.gateway_wire_bytes = try reader.readU64();
    value.transport_wire_bytes = try reader.readU64();
    try readDigests(&reader, &value);
    value.envelope_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &value.envelope_sha256,
        &envelopeSha256(encoded[0 .. encoded.len - digest_bytes]),
    )) return Error.InvalidEnvelope;

    var expected_storage: [encoded_bytes]u8 = undefined;
    const expected = try encodeV1(
        header,
        value.journal_sequence,
        value.journal_previous_chain_sha256,
        encoded_frame,
        value.gateway_event_index,
        encoded_gateway,
        encoded_transport,
        scratch,
        &expected_storage,
    );
    if (!std.mem.eql(u8, encoded, expected)) return Error.InvalidComposition;
    return value;
}

fn composeV1(
    header: journal.HeaderV1,
    journal_sequence: u64,
    journal_previous_chain_sha256: Digest,
    encoded_frame: []const u8,
    gateway_event_index: u32,
    encoded_gateway: []const u8,
    encoded_transport: []const u8,
    scratch: ScratchV1,
) Error!DecodedV1 {
    if (!journal.headerValidV1(header) or journal_sequence == 0 or
        isZero(journal_previous_chain_sha256) or
        (journal_sequence == 1 and !std.mem.eql(
            u8,
            &journal_previous_chain_sha256,
            &header.header_sha256,
        )) or
        encoded_frame.len != journal.frame_bytes)
        return Error.InvalidEvidence;
    const frame = journal.decodeFrameAndVerifyV1(
        header,
        journal_sequence,
        journal_previous_chain_sha256,
        encoded_frame,
    ) catch return Error.InvalidEvidence;
    const decoded_gateway = gateway_wire.decodeAndVerifyV1(
        encoded_gateway,
        scratch.gateway_events,
        scratch.gateway_owners,
        scratch.gateway_consumers,
        scratch.gateway_bindings,
    ) catch return Error.InvalidEvidence;
    const decoded_transport = transport_wire.decodeAndVerifyV1(
        encoded_transport,
        scratch.transport_events,
    ) catch return Error.InvalidEvidence;
    if (gateway_event_index >= decoded_gateway.events.len or
        decoded_transport.events.len > std.math.maxInt(u32))
        return Error.InvalidComposition;

    const selected_binding = for (decoded_gateway.settlements) |binding| {
        if (binding.event_index == gateway_event_index) break binding;
    } else return Error.InvalidComposition;
    if (!std.meta.eql(
        frame.cost.provider_settlement,
        selected_binding.settlement,
    ) or !std.meta.eql(
        frame.cost.provider_settlement,
        decoded_transport.settlement,
    )) return Error.InvalidComposition;
    const terminal = try terminalRootsV1(decoded_transport.events);
    const settlement = frame.cost.provider_settlement;
    const selected_event = decoded_gateway.events[gateway_event_index];
    return .{
        .flags = flag_require_closed,
        .journal_sequence = journal_sequence,
        .gateway_event_index = gateway_event_index,
        .transport_event_count = @intCast(decoded_transport.events.len),
        .journal_frame_bytes = encoded_frame.len,
        .gateway_wire_bytes = encoded_gateway.len,
        .transport_wire_bytes = encoded_transport.len,
        .journal_header_sha256 = header.header_sha256,
        .journal_previous_chain_sha256 = journal_previous_chain_sha256,
        .journal_entry_sha256 = frame.entry_sha256,
        .cost_envelope_sha256 = frame.cost.envelope_sha256,
        .settlement_envelope_sha256 = settlement.envelope_sha256,
        .request_sha256 = settlement.request.request_sha256,
        .dispatch_key_sha256 = settlement.receipt.intent.dispatch_key_sha256,
        .intent_sha256 = settlement.receipt.intent.intent_sha256,
        .receipt_sha256 = settlement.receipt.receipt_sha256,
        .price_sha256 = frame.cost.price.price_sha256,
        .quote_sha256 = frame.cost.quote.quote_sha256,
        .cost_settlement_sha256 = frame.cost.cost_settlement.settlement_sha256,
        .gateway_envelope_sha256 = decoded_gateway.envelope_sha256,
        .gateway_event_sha256 = selected_event.event_sha256,
        .gateway_final_chain_sha256 = decoded_gateway.final_snapshot.event_chain_sha256,
        .transport_envelope_sha256 = decoded_transport.envelope_sha256,
        .provider_request_sha256 = terminal.provider_request_sha256,
        .response_chain_sha256 = terminal.response_chain_sha256,
        .transport_outcome_sha256 = terminal.outcome_sha256,
    };
}

fn terminalRootsV1(events: []const transport_wire.EventV1) Error!TerminalRootsV1 {
    var value: ?TerminalRootsV1 = null;
    for (events) |event| switch (event) {
        .outcome => |outcome| {
            if (value != null) return Error.InvalidComposition;
            value = .{
                .provider_request_sha256 = outcome.provider_request_sha256,
                .response_chain_sha256 = outcome.response_chain_sha256,
                .outcome_sha256 = outcome.outcome_sha256,
            };
        },
        .cancel_outcome => |outcome| {
            if (value != null) return Error.InvalidComposition;
            value = .{
                .provider_request_sha256 = outcome.provider_request_sha256,
                .response_chain_sha256 = outcome.response_chain_sha256,
                .outcome_sha256 = outcome.outcome_sha256,
            };
        },
        else => {},
    };
    return value orelse Error.InvalidComposition;
}

fn writeDigests(writer: *Writer, value: DecodedV1) Error!void {
    try writer.writeDigest(value.journal_header_sha256);
    try writer.writeDigest(value.journal_previous_chain_sha256);
    try writer.writeDigest(value.journal_entry_sha256);
    try writer.writeDigest(value.cost_envelope_sha256);
    try writer.writeDigest(value.settlement_envelope_sha256);
    try writer.writeDigest(value.request_sha256);
    try writer.writeDigest(value.dispatch_key_sha256);
    try writer.writeDigest(value.intent_sha256);
    try writer.writeDigest(value.receipt_sha256);
    try writer.writeDigest(value.price_sha256);
    try writer.writeDigest(value.quote_sha256);
    try writer.writeDigest(value.cost_settlement_sha256);
    try writer.writeDigest(value.gateway_envelope_sha256);
    try writer.writeDigest(value.gateway_event_sha256);
    try writer.writeDigest(value.gateway_final_chain_sha256);
    try writer.writeDigest(value.transport_envelope_sha256);
    try writer.writeDigest(value.provider_request_sha256);
    try writer.writeDigest(value.response_chain_sha256);
    try writer.writeDigest(value.transport_outcome_sha256);
}

fn readDigests(reader: *Reader, value: *DecodedV1) Error!void {
    value.journal_header_sha256 = try reader.readDigest();
    value.journal_previous_chain_sha256 = try reader.readDigest();
    value.journal_entry_sha256 = try reader.readDigest();
    value.cost_envelope_sha256 = try reader.readDigest();
    value.settlement_envelope_sha256 = try reader.readDigest();
    value.request_sha256 = try reader.readDigest();
    value.dispatch_key_sha256 = try reader.readDigest();
    value.intent_sha256 = try reader.readDigest();
    value.receipt_sha256 = try reader.readDigest();
    value.price_sha256 = try reader.readDigest();
    value.quote_sha256 = try reader.readDigest();
    value.cost_settlement_sha256 = try reader.readDigest();
    value.gateway_envelope_sha256 = try reader.readDigest();
    value.gateway_event_sha256 = try reader.readDigest();
    value.gateway_final_chain_sha256 = try reader.readDigest();
    value.transport_envelope_sha256 = try reader.readDigest();
    value.provider_request_sha256 = try reader.readDigest();
    value.response_chain_sha256 = try reader.readDigest();
    value.transport_outcome_sha256 = try reader.readDigest();
}

fn envelopeSha256(prefix: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(envelope_domain);
    hash.update(prefix);
    var value: Digest = undefined;
    hash.final(&value);
    return value;
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn overlapsScratch(bytes: []const u8, scratch: ScratchV1) bool {
    return slicesOverlap(u8, bytes, gateway.EventV2, scratch.gateway_events) or
        slicesOverlap(u8, bytes, gateway_wire.ReplayOwnerV1, scratch.gateway_owners) or
        slicesOverlap(u8, bytes, gateway_wire.ReplayConsumerV1, scratch.gateway_consumers) or
        slicesOverlap(u8, bytes, gateway_wire.SettlementBindingV1, scratch.gateway_bindings) or
        slicesOverlap(u8, bytes, transport_wire.EventV1, scratch.transport_events);
}

fn scratchOverlapsEvidence(
    comptime T: type,
    values: []const T,
    encoded_frame: []const u8,
    encoded_gateway: []const u8,
    encoded_transport: []const u8,
) bool {
    return slicesOverlap(T, values, u8, encoded_frame) or
        slicesOverlap(T, values, u8, encoded_gateway) or
        slicesOverlap(T, values, u8, encoded_transport);
}

fn invalidScratchLayout(
    encoded_frame: []const u8,
    encoded_gateway: []const u8,
    encoded_transport: []const u8,
    scratch: ScratchV1,
) bool {
    if (scratchOverlapsEvidence(
        gateway.EventV2,
        scratch.gateway_events,
        encoded_frame,
        encoded_gateway,
        encoded_transport,
    ) or scratchOverlapsEvidence(
        gateway_wire.ReplayOwnerV1,
        scratch.gateway_owners,
        encoded_frame,
        encoded_gateway,
        encoded_transport,
    ) or scratchOverlapsEvidence(
        gateway_wire.ReplayConsumerV1,
        scratch.gateway_consumers,
        encoded_frame,
        encoded_gateway,
        encoded_transport,
    ) or scratchOverlapsEvidence(
        gateway_wire.SettlementBindingV1,
        scratch.gateway_bindings,
        encoded_frame,
        encoded_gateway,
        encoded_transport,
    ) or scratchOverlapsEvidence(
        transport_wire.EventV1,
        scratch.transport_events,
        encoded_frame,
        encoded_gateway,
        encoded_transport,
    )) return true;

    return slicesOverlap(
        gateway.EventV2,
        scratch.gateway_events,
        gateway_wire.ReplayOwnerV1,
        scratch.gateway_owners,
    ) or slicesOverlap(
        gateway.EventV2,
        scratch.gateway_events,
        gateway_wire.ReplayConsumerV1,
        scratch.gateway_consumers,
    ) or slicesOverlap(
        gateway.EventV2,
        scratch.gateway_events,
        gateway_wire.SettlementBindingV1,
        scratch.gateway_bindings,
    ) or slicesOverlap(
        gateway.EventV2,
        scratch.gateway_events,
        transport_wire.EventV1,
        scratch.transport_events,
    ) or slicesOverlap(
        gateway_wire.ReplayOwnerV1,
        scratch.gateway_owners,
        gateway_wire.ReplayConsumerV1,
        scratch.gateway_consumers,
    ) or slicesOverlap(
        gateway_wire.ReplayOwnerV1,
        scratch.gateway_owners,
        gateway_wire.SettlementBindingV1,
        scratch.gateway_bindings,
    ) or slicesOverlap(
        gateway_wire.ReplayOwnerV1,
        scratch.gateway_owners,
        transport_wire.EventV1,
        scratch.transport_events,
    ) or slicesOverlap(
        gateway_wire.ReplayConsumerV1,
        scratch.gateway_consumers,
        gateway_wire.SettlementBindingV1,
        scratch.gateway_bindings,
    ) or slicesOverlap(
        gateway_wire.ReplayConsumerV1,
        scratch.gateway_consumers,
        transport_wire.EventV1,
        scratch.transport_events,
    ) or slicesOverlap(
        gateway_wire.SettlementBindingV1,
        scratch.gateway_bindings,
        transport_wire.EventV1,
        scratch.transport_events,
    );
}

fn slicesOverlap(
    comptime A: type,
    a: []const A,
    comptime B: type,
    b: []const B,
) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = a_start + a.len * @sizeOf(A);
    const b_end = b_start + b.len * @sizeOf(B);
    return a_start < b_end and b_start < a_end;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        if (value.len > self.bytes.len - self.position)
            return Error.InvalidLength;
        @memcpy(self.bytes[self.position .. self.position + value.len], value);
        self.position += value.len;
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
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(self: *Reader, length: usize) Error![]const u8 {
        if (length > self.bytes.len - self.position)
            return Error.InvalidLength;
        const value = self.bytes[self.position .. self.position + length];
        self.position += length;
        return value;
    }

    fn readU32(self: *Reader) Error!u32 {
        var bytes: [4]u8 = undefined;
        @memcpy(&bytes, try self.readBytes(4));
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        var bytes: [8]u8 = undefined;
        @memcpy(&bytes, try self.readBytes(8));
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        var value: Digest = undefined;
        @memcpy(&value, try self.readBytes(digest_bytes));
        return value;
    }
};

test "join wire layout is fixed" {
    try std.testing.expectEqual(@as(usize, 72), header_bytes);
    try std.testing.expectEqual(@as(usize, 20), digest_field_count);
    try std.testing.expectEqual(@as(usize, 712), encoded_bytes);
}

test "join scratch rejects cross-plane aliasing" {
    const storage_bytes = @max(
        @sizeOf(gateway.EventV2),
        @sizeOf(transport_wire.EventV1),
    );
    const storage_alignment = @max(
        @alignOf(gateway.EventV2),
        @alignOf(transport_wire.EventV1),
    );
    var shared: [storage_bytes]u8 align(storage_alignment) = undefined;
    const gateway_events = @as(
        [*]gateway.EventV2,
        @ptrCast(&shared),
    )[0..1];
    const transport_events = @as(
        [*]transport_wire.EventV1,
        @ptrCast(&shared),
    )[0..1];
    var owners: [0]gateway_wire.ReplayOwnerV1 = .{};
    var consumers: [0]gateway_wire.ReplayConsumerV1 = .{};
    var bindings: [0]gateway_wire.SettlementBindingV1 = .{};
    const scratch: ScratchV1 = .{
        .gateway_events = gateway_events,
        .gateway_owners = &owners,
        .gateway_consumers = &consumers,
        .gateway_bindings = &bindings,
        .transport_events = transport_events,
    };
    try std.testing.expect(invalidScratchLayout(
        &.{},
        &.{},
        &.{},
        scratch,
    ));
}
