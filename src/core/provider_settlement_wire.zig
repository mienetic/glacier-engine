//! Canonical allocation-free wire for one provider request and attempt receipt.
//!
//! The fixed-size envelope carries the exact owner request, dispatch intent,
//! known-or-unknown usage counters and terminal or non-terminal settlement.
//! Integers are little-endian, enums and booleans are one byte and native
//! struct padding is never serialized. The semantic verifier binds the request
//! to its intent, dispatch key and exact conservative reservation before an
//! independently recomputed envelope digest is accepted.

const std = @import("std");
const gateway = @import("provider_token_gateway.zig");

pub const Digest = gateway.Digest;
pub const wire_abi: u64 = 0x4750_5357_0000_0001;
pub const magic = [_]u8{ 'G', 'P', 'S', 'W', 'I', 'R', 'E', '1' };
pub const flags_none: u32 = 0;

const envelope_domain = "glacier-provider-settlement-wire-v1\x00";
const digest_bytes: usize = @sizeOf(Digest);

pub const header_bytes: usize = magic.len + 8 + 8 + 4 + 4;
pub const request_wire_bytes: usize = 8 * 5 + 32 * 5 + 8 * 2 + 1 + 32;
pub const count_wire_bytes: usize = 1 + 8;
pub const usage_wire_bytes: usize = 8 + count_wire_bytes * 6 + 32;
pub const intent_wire_bytes: usize =
    8 + 8 + 4 + 8 + 8 + 32 + 32 + 8 + 32 + 32;
pub const receipt_wire_bytes: usize =
    8 + 1 + intent_wire_bytes + usage_wire_bytes + 32 + 4 + 32 + 32 + 32;
pub const encoded_bytes: usize =
    header_bytes + request_wire_bytes + receipt_wire_bytes + digest_bytes;

pub const Error = error{
    CapacityExceeded,
    InvalidMagic,
    InvalidAbi,
    InvalidLength,
    InvalidFlags,
    InvalidEnum,
    InvalidBoolean,
    InvalidEnvelope,
    InvalidEvidence,
};

pub const DecodedV1 = struct {
    request: gateway.RequestV1,
    receipt: gateway.AttemptReceiptV1,
    envelope_sha256: Digest,
};

/// Verifies the self-contained Gateway semantics not requiring a live Gateway
/// or its full event chain. The receipt's event and request-set roots remain
/// committed evidence boundaries for the corresponding canonical streams.
pub fn verifyRequestSettlementV1(
    request: gateway.RequestV1,
    receipt: gateway.AttemptReceiptV1,
) bool {
    if (!gateway.requestValidV1(request) or
        !gateway.attemptReceiptValidV1(receipt) or
        !std.mem.eql(
            u8,
            &request.request_sha256,
            &receipt.intent.request_sha256,
        ) or !std.mem.eql(
        u8,
        &receipt.intent.dispatch_key_sha256,
        &gateway.dispatchKeySha256(request),
    )) return false;
    const reserved_tokens = std.math.add(
        u64,
        request.input_token_estimate,
        request.max_output_tokens,
    ) catch return false;
    return receipt.intent.reserved_tokens == reserved_tokens;
}

/// Writes exactly `encoded_bytes` into caller-owned storage. Any error after
/// writing begins wipes the written envelope instead of exposing partial
/// evidence as if it were sealed.
pub fn encodeV1(
    request: gateway.RequestV1,
    receipt: gateway.AttemptReceiptV1,
    destination: []u8,
) Error![]const u8 {
    if (!verifyRequestSettlementV1(request, receipt))
        return Error.InvalidEvidence;
    if (destination.len < encoded_bytes) return Error.CapacityExceeded;
    const output = destination[0..encoded_bytes];
    @memset(output, 0);
    errdefer @memset(output, 0);

    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&magic);
    try writer.writeU64(wire_abi);
    try writer.writeU64(encoded_bytes);
    try writer.writeU32(flags_none);
    try writer.writeU32(0);
    try writeRequest(&writer, request);
    try writeReceipt(&writer, receipt);
    if (writer.position + digest_bytes != output.len)
        return Error.InvalidLength;
    try writer.writeDigest(envelopeSha256(output[0..writer.position]));
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

/// Parses and verifies the canonical envelope without allocating. No live
/// Gateway pointer or provider SDK is required to check the evidence.
pub fn decodeAndVerifyV1(encoded: []const u8) Error!DecodedV1 {
    if (encoded.len != encoded_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(magic.len), &magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != wire_abi) return Error.InvalidAbi;
    if (try reader.readU64() != encoded_bytes) return Error.InvalidLength;
    if (try reader.readU32() != flags_none) return Error.InvalidFlags;
    if (try reader.readU32() != 0) return Error.InvalidFlags;

    const root_offset = encoded.len - digest_bytes;
    const expected_root = envelopeSha256(encoded[0..root_offset]);
    if (!std.mem.eql(u8, &expected_root, encoded[root_offset..]))
        return Error.InvalidEnvelope;

    const request = try readRequest(&reader);
    const receipt = try readReceipt(&reader);
    const envelope_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &envelope_sha256,
        &expected_root,
    )) return Error.InvalidEnvelope;
    if (!verifyRequestSettlementV1(request, receipt))
        return Error.InvalidEvidence;
    return .{
        .request = request,
        .receipt = receipt,
        .envelope_sha256 = envelope_sha256,
    };
}

pub fn envelopeSha256V1(encoded: []const u8) Error!Digest {
    if (encoded.len != encoded_bytes) return Error.InvalidLength;
    const root_offset = encoded.len - digest_bytes;
    const expected = envelopeSha256(encoded[0..root_offset]);
    if (!std.mem.eql(u8, &expected, encoded[root_offset..]))
        return Error.InvalidEnvelope;
    return expected;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        const end = std.math.add(usize, self.position, value.len) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.CapacityExceeded;
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeU8(self: *Writer, value: u8) Error!void {
        try self.writeBytes(&.{value});
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
        const end = std.math.add(usize, self.position, length) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        const result = self.bytes[self.position..end];
        self.position = end;
        return result;
    }

    fn readU8(self: *Reader) Error!u8 {
        return (try self.readBytes(1))[0];
    }

    fn readU32(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.readBytes(4))[0..4], .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try self.readBytes(8))[0..8], .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        var value: Digest = undefined;
        @memcpy(&value, try self.readBytes(digest_bytes));
        return value;
    }
};

fn writeRequest(writer: *Writer, value: gateway.RequestV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.provider_adapter_abi);
    try writer.writeU64(value.isolation_key);
    try writer.writeU64(value.request_key);
    try writer.writeU64(value.request_generation);
    try writer.writeDigest(value.model_sha256);
    try writer.writeDigest(value.context_sha256);
    try writer.writeDigest(value.tool_schema_sha256);
    try writer.writeDigest(value.policy_sha256);
    try writer.writeDigest(value.sampling_sha256);
    try writer.writeU64(value.input_token_estimate);
    try writer.writeU64(value.max_output_tokens);
    try writer.writeU8(@intFromEnum(value.reuse_policy));
    try writer.writeDigest(value.request_sha256);
}

fn readRequest(reader: *Reader) Error!gateway.RequestV1 {
    const abi_version = try reader.readU64();
    const provider_adapter_abi = try reader.readU64();
    const isolation_key = try reader.readU64();
    const request_key = try reader.readU64();
    const request_generation = try reader.readU64();
    const model_sha256 = try reader.readDigest();
    const context_sha256 = try reader.readDigest();
    const tool_schema_sha256 = try reader.readDigest();
    const policy_sha256 = try reader.readDigest();
    const sampling_sha256 = try reader.readDigest();
    const input_token_estimate = try reader.readU64();
    const max_output_tokens = try reader.readU64();
    const reuse_policy: gateway.ReusePolicy = switch (try reader.readU8()) {
        0 => .none,
        1 => .in_flight,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .provider_adapter_abi = provider_adapter_abi,
        .isolation_key = isolation_key,
        .request_key = request_key,
        .request_generation = request_generation,
        .model_sha256 = model_sha256,
        .context_sha256 = context_sha256,
        .tool_schema_sha256 = tool_schema_sha256,
        .policy_sha256 = policy_sha256,
        .sampling_sha256 = sampling_sha256,
        .input_token_estimate = input_token_estimate,
        .max_output_tokens = max_output_tokens,
        .reuse_policy = reuse_policy,
        .request_sha256 = try reader.readDigest(),
    };
}

fn writeCount(writer: *Writer, value: gateway.CountV1) Error!void {
    try writer.writeU8(@intFromBool(value.known));
    try writer.writeU64(value.value);
}

fn readCount(reader: *Reader) Error!gateway.CountV1 {
    const known = switch (try reader.readU8()) {
        0 => false,
        1 => true,
        else => return Error.InvalidBoolean,
    };
    return .{ .known = known, .value = try reader.readU64() };
}

fn writeUsage(writer: *Writer, value: gateway.UsageV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writeCount(writer, value.input_tokens);
    try writeCount(writer, value.output_tokens);
    try writeCount(writer, value.cached_input_tokens);
    try writeCount(writer, value.reasoning_tokens);
    try writeCount(writer, value.retry_tokens);
    try writeCount(writer, value.billable_tokens);
    try writer.writeDigest(value.usage_sha256);
}

fn readUsage(reader: *Reader) Error!gateway.UsageV1 {
    return .{
        .abi_version = try reader.readU64(),
        .input_tokens = try readCount(reader),
        .output_tokens = try readCount(reader),
        .cached_input_tokens = try readCount(reader),
        .reasoning_tokens = try readCount(reader),
        .retry_tokens = try readCount(reader),
        .billable_tokens = try readCount(reader),
        .usage_sha256 = try reader.readDigest(),
    };
}

fn writeIntent(writer: *Writer, value: gateway.DispatchIntentV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.gateway_epoch);
    try writer.writeU32(value.owner_slot_index);
    try writer.writeU64(value.owner_generation);
    try writer.writeU64(value.attempt_generation);
    try writer.writeDigest(value.request_sha256);
    try writer.writeDigest(value.dispatch_key_sha256);
    try writer.writeU64(value.reserved_tokens);
    try writer.writeDigest(value.previous_event_chain_sha256);
    try writer.writeDigest(value.intent_sha256);
}

fn readIntent(reader: *Reader) Error!gateway.DispatchIntentV1 {
    return .{
        .abi_version = try reader.readU64(),
        .gateway_epoch = try reader.readU64(),
        .owner_slot_index = try reader.readU32(),
        .owner_generation = try reader.readU64(),
        .attempt_generation = try reader.readU64(),
        .request_sha256 = try reader.readDigest(),
        .dispatch_key_sha256 = try reader.readDigest(),
        .reserved_tokens = try reader.readU64(),
        .previous_event_chain_sha256 = try reader.readDigest(),
        .intent_sha256 = try reader.readDigest(),
    };
}

fn writeReceipt(
    writer: *Writer,
    value: gateway.AttemptReceiptV1,
) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU8(@intFromEnum(value.outcome));
    try writeIntent(writer, value.intent);
    try writeUsage(writer, value.usage);
    try writer.writeDigest(value.result_sha256);
    try writer.writeU32(value.request_set_count);
    try writer.writeDigest(value.request_set_sha256);
    try writer.writeDigest(value.event_sha256);
    try writer.writeDigest(value.receipt_sha256);
}

fn readReceipt(reader: *Reader) Error!gateway.AttemptReceiptV1 {
    const abi_version = try reader.readU64();
    const outcome: gateway.AttemptOutcome = switch (try reader.readU8()) {
        0 => .retryable_no_charge,
        1 => .ambiguous,
        2 => .succeeded,
        3 => .failed,
        4 => .resolved_success,
        5 => .resolved_failure,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .outcome = outcome,
        .intent = try readIntent(reader),
        .usage = try readUsage(reader),
        .result_sha256 = try reader.readDigest(),
        .request_set_count = try reader.readU32(),
        .request_set_sha256 = try reader.readDigest(),
        .event_sha256 = try reader.readDigest(),
        .receipt_sha256 = try reader.readDigest(),
    };
}

fn envelopeSha256(prefix: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(envelope_domain);
    hash.update(prefix);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn resealForTest(encoded: []u8) void {
    const root_offset = encoded.len - digest_bytes;
    const root = envelopeSha256(encoded[0..root_offset]);
    @memcpy(encoded[root_offset..], &root);
}

fn testDigest(seed: u8) Digest {
    var value: Digest = undefined;
    @memset(&value, seed);
    return value;
}

const TestEvidence = struct {
    request: gateway.RequestV1,
    receipt: gateway.AttemptReceiptV1,
};

fn testEvidence(outcome: gateway.AttemptOutcome) !TestEvidence {
    const request = try gateway.makeRequestV1(
        0x5445_5354_4144_5054,
        0x5445_5354_4953_4f4c,
        71,
        3,
        testDigest(0x11),
        testDigest(0x22),
        testDigest(0x33),
        testDigest(0x44),
        testDigest(0x55),
        100,
        50,
        .in_flight,
    );
    var intent: gateway.DispatchIntentV1 = .{
        .gateway_epoch = 0x5445_5354_4757_0001,
        .owner_slot_index = 2,
        .owner_generation = 9,
        .attempt_generation = 4,
        .request_sha256 = request.request_sha256,
        .dispatch_key_sha256 = gateway.dispatchKeySha256(request),
        .reserved_tokens = 150,
        .previous_event_chain_sha256 = testDigest(0x66),
    };
    intent.intent_sha256 = gateway.dispatchIntentSha256(intent);
    const usage = switch (outcome) {
        .retryable_no_charge => try gateway.makeUsageV1(
            null,
            null,
            null,
            null,
            null,
            0,
        ),
        .ambiguous => try gateway.makeUsageV1(100, 7, 40, null, 3, null),
        .succeeded, .resolved_success => try gateway.makeUsageV1(
            100,
            20,
            40,
            8,
            0,
            80,
        ),
        .failed, .resolved_failure => try gateway.makeUsageV1(
            100,
            0,
            40,
            0,
            0,
            60,
        ),
    };
    var receipt: gateway.AttemptReceiptV1 = .{
        .outcome = outcome,
        .intent = intent,
        .usage = usage,
        .result_sha256 = switch (outcome) {
            .succeeded, .resolved_success => testDigest(0x77),
            else => gateway.zero_digest,
        },
        .request_set_count = 3,
        .request_set_sha256 = testDigest(0x88),
        .event_sha256 = testDigest(0x99),
    };
    receipt.receipt_sha256 = gateway.attemptReceiptSha256(receipt);
    return .{ .request = request, .receipt = receipt };
}

test "settlement wire round trips without allocation" {
    const evidence = try testEvidence(.succeeded);
    var bytes: [encoded_bytes + 16]u8 = [_]u8{0xcc} ** (encoded_bytes + 16);
    const encoded = try encodeV1(evidence.request, evidence.receipt, &bytes);
    try std.testing.expectEqual(@as(usize, 720), encoded.len);
    try std.testing.expect(std.mem.allEqual(u8, bytes[encoded.len..], 0xcc));
    const decoded = try decodeAndVerifyV1(encoded);
    try std.testing.expectEqual(evidence.request, decoded.request);
    try std.testing.expectEqual(evidence.receipt, decoded.receipt);
    try std.testing.expectEqual(
        try envelopeSha256V1(encoded),
        decoded.envelope_sha256,
    );
    const root_hex = std.fmt.bytesToHex(decoded.envelope_sha256, .lower);
    try std.testing.expectEqualStrings(
        "9d2aec698e62176966ef11193fce5d447b67fe77ea2ba6938ae6aa9bd9a7c3ba",
        &root_hex,
    );
}

test "known zero unknown and every outcome retain distinct semantics" {
    inline for (std.meta.tags(gateway.AttemptOutcome)) |outcome| {
        const evidence = try testEvidence(outcome);
        var bytes: [encoded_bytes]u8 = undefined;
        const decoded = try decodeAndVerifyV1(try encodeV1(
            evidence.request,
            evidence.receipt,
            &bytes,
        ));
        try std.testing.expectEqual(outcome, decoded.receipt.outcome);
        if (outcome == .retryable_no_charge) {
            try std.testing.expect(decoded.receipt.usage.billable_tokens.known);
            try std.testing.expectEqual(
                @as(u64, 0),
                decoded.receipt.usage.billable_tokens.value,
            );
            try std.testing.expect(!decoded.receipt.usage.input_tokens.known);
        } else if (outcome == .ambiguous) {
            try std.testing.expect(!decoded.receipt.usage.billable_tokens.known);
            try std.testing.expectEqual(
                @as(u64, 0),
                decoded.receipt.usage.billable_tokens.value,
            );
        } else {
            try std.testing.expect(decoded.receipt.usage.billable_tokens.known);
        }
    }
}

test "every serialized byte mutation rejects after envelope reseal" {
    const evidence = try testEvidence(.succeeded);
    var original: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(
        evidence.request,
        evidence.receipt,
        &original,
    );
    var mutated: [encoded_bytes]u8 = undefined;
    for (0..encoded.len - digest_bytes) |index| {
        @memcpy(&mutated, encoded);
        mutated[index] ^= 1;
        resealForTest(&mutated);
        if (decodeAndVerifyV1(&mutated)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "capacity length outer drift and semantic substitution reject" {
    const evidence = try testEvidence(.succeeded);
    var bytes: [encoded_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.CapacityExceeded,
        encodeV1(
            evidence.request,
            evidence.receipt,
            bytes[0 .. encoded_bytes - 1],
        ),
    );
    const encoded = try encodeV1(evidence.request, evidence.receipt, &bytes);
    try std.testing.expectError(
        Error.InvalidLength,
        decodeAndVerifyV1(encoded[0 .. encoded.len - 1]),
    );
    bytes[header_bytes] ^= 1;
    try std.testing.expectError(Error.InvalidEnvelope, decodeAndVerifyV1(&bytes));

    var foreign = (try testEvidence(.succeeded)).request;
    foreign.request_key += 1;
    foreign.request_sha256 = gateway.requestSha256(foreign);
    var output: [encoded_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.InvalidEvidence,
        encodeV1(foreign, evidence.receipt, &output),
    );
}

test "coordinated semantic drift cannot be blessed by nested resealing" {
    const evidence = try testEvidence(.succeeded);
    var output: [encoded_bytes]u8 = undefined;

    var unknown_with_value = evidence.receipt;
    unknown_with_value.usage.input_tokens = .{ .known = false, .value = 1 };
    unknown_with_value.usage.usage_sha256 = gateway.usageSha256(
        unknown_with_value.usage,
    );
    unknown_with_value.receipt_sha256 = gateway.attemptReceiptSha256(
        unknown_with_value,
    );
    try std.testing.expectError(
        Error.InvalidEvidence,
        encodeV1(evidence.request, unknown_with_value, &output),
    );

    var reservation_drift = evidence.receipt;
    reservation_drift.intent.reserved_tokens += 1;
    reservation_drift.intent.intent_sha256 = gateway.dispatchIntentSha256(
        reservation_drift.intent,
    );
    reservation_drift.receipt_sha256 = gateway.attemptReceiptSha256(
        reservation_drift,
    );
    try std.testing.expectError(
        Error.InvalidEvidence,
        encodeV1(evidence.request, reservation_drift, &output),
    );

    var false_failure = evidence.receipt;
    false_failure.outcome = .failed;
    false_failure.receipt_sha256 = gateway.attemptReceiptSha256(false_failure);
    try std.testing.expectError(
        Error.InvalidEvidence,
        encodeV1(evidence.request, false_failure, &output),
    );

    const overflow_request = try gateway.makeRequestV1(
        evidence.request.provider_adapter_abi,
        evidence.request.isolation_key,
        evidence.request.request_key,
        evidence.request.request_generation,
        evidence.request.model_sha256,
        evidence.request.context_sha256,
        evidence.request.tool_schema_sha256,
        evidence.request.policy_sha256,
        evidence.request.sampling_sha256,
        std.math.maxInt(u64),
        1,
        evidence.request.reuse_policy,
    );
    var overflow_receipt = evidence.receipt;
    overflow_receipt.intent.request_sha256 = overflow_request.request_sha256;
    overflow_receipt.intent.dispatch_key_sha256 = gateway.dispatchKeySha256(
        overflow_request,
    );
    overflow_receipt.intent.intent_sha256 = gateway.dispatchIntentSha256(
        overflow_receipt.intent,
    );
    overflow_receipt.receipt_sha256 = gateway.attemptReceiptSha256(
        overflow_receipt,
    );
    try std.testing.expectError(
        Error.InvalidEvidence,
        encodeV1(overflow_request, overflow_receipt, &output),
    );
}

test "wire layout sizes remain explicit and padding independent" {
    try std.testing.expectEqual(@as(usize, 32), header_bytes);
    try std.testing.expectEqual(@as(usize, 249), request_wire_bytes);
    try std.testing.expectEqual(@as(usize, 9), count_wire_bytes);
    try std.testing.expectEqual(@as(usize, 94), usage_wire_bytes);
    try std.testing.expectEqual(@as(usize, 172), intent_wire_bytes);
    try std.testing.expectEqual(@as(usize, 407), receipt_wire_bytes);
    try std.testing.expectEqual(@as(usize, 720), encoded_bytes);
}
