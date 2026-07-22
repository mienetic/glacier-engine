//! Canonical allocation-free wire for complete provider-context evidence.
//!
//! The wire contains every object required to verify a packed context and its
//! adapter execution in another process: descriptor, domain, policy, logical
//! spans, packing decisions, receipt, execution and the retained packed wire.
//! Integers are little-endian, enums are one byte and struct padding is never
//! serialized. Decoding uses caller-owned storage and rejects trailing bytes,
//! unknown flags, stale ABIs, aliasing, envelope drift and every invalid nested
//! semantic commitment.

const std = @import("std");
const context_pack = @import("provider_context_pack.zig");
const context_adapter = @import("provider_context_adapter.zig");

pub const Digest = context_pack.Digest;
pub const wire_abi: u64 = 0x4750_435a_0000_0001;
pub const magic = [_]u8{ 'G', 'P', 'C', 'W', 'I', 'R', 'E', '1' };
pub const flags_none: u32 = 0;

const envelope_domain = "glacier-provider-context-evidence-wire-v1\x00";
const digest_bytes: usize = @sizeOf(Digest);

pub const header_bytes: usize = magic.len + 8 + 8 + 4 + 4 + 8;
pub const descriptor_wire_bytes: usize = 8 + 8 + 32 * 3 + 8 + 8 + 32;
pub const domain_wire_bytes: usize = 8 + 8 + 8 + 32 * 5;
pub const policy_wire_bytes: usize = 8 + 4 + 8 + 8 + 32;
pub const span_wire_bytes: usize = 8 + 4 + 1 + 1 + 1 + 32 * 4 + 8;
pub const decision_wire_bytes: usize =
    8 + 4 + 1 + 32 + 4 + 32 + 8 + 8 + 32;
pub const receipt_wire_bytes: usize = 8 + 32 * 2 + 4 * 4 + 8 * 3 + 32 * 3;
pub const observation_wire_bytes: usize = 8 + 1 + 32 * 5 + 8;
pub const reconciliation_wire_bytes: usize = 8 + 32 * 7 + 8 * 5;
pub const execution_wire_bytes: usize =
    8 + 32 * 5 + 8 * 2 + observation_wire_bytes * 2 +
    reconciliation_wire_bytes + 32;
pub const fixed_wire_bytes: usize = header_bytes + descriptor_wire_bytes +
    domain_wire_bytes + policy_wire_bytes + receipt_wire_bytes +
    execution_wire_bytes + digest_bytes;

pub const Error = error{
    CapacityExceeded,
    LengthOverflow,
    InvalidStorage,
    InvalidMagic,
    InvalidAbi,
    InvalidLength,
    InvalidFlags,
    InvalidEnum,
    InvalidEnvelope,
    InvalidEvidence,
};

pub const DecodedV1 = struct {
    descriptor: context_adapter.DescriptorV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    execution: context_adapter.ExecutionV1,
    packed_wire: []const u8,
    envelope_sha256: Digest,
};

pub fn encodedLenV1(span_count: usize, packed_wire_bytes: usize) Error!usize {
    if (span_count > context_pack.max_supported_spans or
        packed_wire_bytes > context_adapter.max_supported_wire_bytes)
        return Error.CapacityExceeded;
    const span_bytes = std.math.mul(
        usize,
        span_count,
        span_wire_bytes,
    ) catch return Error.LengthOverflow;
    const decision_bytes = std.math.mul(
        usize,
        span_count,
        decision_wire_bytes,
    ) catch return Error.LengthOverflow;
    var total = std.math.add(
        usize,
        fixed_wire_bytes,
        span_bytes,
    ) catch return Error.LengthOverflow;
    total = std.math.add(usize, total, decision_bytes) catch
        return Error.LengthOverflow;
    return std.math.add(usize, total, packed_wire_bytes) catch
        return Error.LengthOverflow;
}

/// Encodes and seals a complete independently verifiable evidence envelope.
/// The returned slice is the exact prefix used; unused destination capacity is
/// untouched. Any error after writing begins wipes that exact prefix.
pub fn encodeV1(
    descriptor: context_adapter.DescriptorV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: []const context_pack.SpanV1,
    decisions: []const context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    execution: context_adapter.ExecutionV1,
    packed_wire: []const u8,
    destination: []u8,
) Error![]const u8 {
    if (spans.len != decisions.len or spans.len > std.math.maxInt(u32) or
        !context_pack.verifyPackV1(
            domain,
            policy,
            spans,
            decisions,
            receipt,
        ) or !context_adapter.verifyRetainedPackedExecutionV1(
        descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        packed_wire,
        execution,
    )) return Error.InvalidEvidence;

    const required = try encodedLenV1(spans.len, packed_wire.len);
    if (destination.len < required) return Error.CapacityExceeded;
    const output = destination[0..required];
    if (overlap(context_pack.SpanV1, spans, u8, output) or
        overlap(context_pack.DecisionV1, decisions, u8, output) or
        overlap(u8, packed_wire, u8, output)) return Error.InvalidStorage;

    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&magic);
    try writer.writeU64(wire_abi);
    try writer.writeU64(@intCast(required));
    try writer.writeU32(@intCast(spans.len));
    try writer.writeU32(flags_none);
    try writer.writeU64(@intCast(packed_wire.len));
    try writeDescriptor(&writer, descriptor);
    try writeDomain(&writer, domain);
    try writePolicy(&writer, policy);
    for (spans) |span| try writeSpan(&writer, span);
    for (decisions) |decision| try writeDecision(&writer, decision);
    try writeReceipt(&writer, receipt);
    try writeExecution(&writer, execution);
    try writer.writeBytes(packed_wire);
    if (writer.position + digest_bytes != output.len)
        return Error.InvalidLength;
    const envelope_sha256 = envelopeSha256(output[0..writer.position]);
    try writer.writeDigest(envelope_sha256);
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

/// Decodes into caller-owned span/decision storage and verifies the entire
/// pack, adapter execution and retained packed wire. No decoded semantic state
/// survives an error after storage mutation begins.
pub fn decodeAndVerifyV1(
    encoded: []const u8,
    span_storage: []context_pack.SpanV1,
    decision_storage: []context_pack.DecisionV1,
) Error!DecodedV1 {
    if (encoded.len < fixed_wire_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(magic.len), &magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != wire_abi) return Error.InvalidAbi;
    const declared_bytes = try reader.readU64();
    if (declared_bytes != encoded.len) return Error.InvalidLength;
    const span_count: usize = try reader.readU32();
    if (try reader.readU32() != flags_none) return Error.InvalidFlags;
    const packed_wire_bytes_u64 = try reader.readU64();
    const packed_wire_bytes = std.math.cast(
        usize,
        packed_wire_bytes_u64,
    ) orelse return Error.InvalidLength;
    const expected_len = try encodedLenV1(span_count, packed_wire_bytes);
    if (expected_len != encoded.len) return Error.InvalidLength;
    if (span_storage.len < span_count or
        decision_storage.len < span_count) return Error.CapacityExceeded;

    const spans = span_storage[0..span_count];
    const decisions = decision_storage[0..span_count];
    if (overlap(u8, encoded, context_pack.SpanV1, spans) or
        overlap(u8, encoded, context_pack.DecisionV1, decisions) or
        overlap(context_pack.SpanV1, spans, context_pack.DecisionV1, decisions))
        return Error.InvalidStorage;

    const root_offset = encoded.len - digest_bytes;
    const expected_root = envelopeSha256(encoded[0..root_offset]);
    if (!std.mem.eql(u8, &expected_root, encoded[root_offset..]))
        return Error.InvalidEnvelope;

    @memset(spans, context_pack.SpanV1{});
    @memset(decisions, context_pack.DecisionV1{});
    errdefer {
        @memset(spans, context_pack.SpanV1{});
        @memset(decisions, context_pack.DecisionV1{});
    }

    const descriptor = try readDescriptor(&reader);
    const domain = try readDomain(&reader);
    const policy = try readPolicy(&reader);
    for (spans) |*span| span.* = try readSpan(&reader);
    for (decisions) |*decision| decision.* = try readDecision(&reader);
    const receipt = try readReceipt(&reader);
    const execution = try readExecution(&reader);
    const packed_wire = try reader.readBytes(packed_wire_bytes);
    const envelope_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &envelope_sha256,
        &expected_root,
    )) return Error.InvalidEnvelope;
    if (!context_pack.verifyPackV1(
        domain,
        policy,
        spans,
        decisions,
        receipt,
    ) or !context_adapter.verifyRetainedPackedExecutionV1(
        descriptor,
        domain,
        policy,
        spans,
        decisions,
        receipt,
        packed_wire,
        execution,
    )) return Error.InvalidEvidence;
    return .{
        .descriptor = descriptor,
        .domain = domain,
        .policy = policy,
        .spans = spans,
        .decisions = decisions,
        .receipt = receipt,
        .execution = execution,
        .packed_wire = packed_wire,
        .envelope_sha256 = envelope_sha256,
    };
}

pub fn envelopeSha256V1(encoded: []const u8) Error!Digest {
    if (encoded.len < digest_bytes) return Error.InvalidLength;
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
            return Error.LengthOverflow;
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

fn writeDescriptor(
    writer: *Writer,
    value: context_adapter.DescriptorV1,
) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.adapter_abi);
    try writer.writeDigest(value.provider_namespace_sha256);
    try writer.writeDigest(value.tokenizer_sha256);
    try writer.writeDigest(value.render_policy_sha256);
    try writer.writeU64(value.capability_bits);
    try writer.writeU64(value.max_wire_bytes);
    try writer.writeDigest(value.descriptor_sha256);
}

fn readDescriptor(reader: *Reader) Error!context_adapter.DescriptorV1 {
    return .{
        .abi_version = try reader.readU64(),
        .adapter_abi = try reader.readU64(),
        .provider_namespace_sha256 = try reader.readDigest(),
        .tokenizer_sha256 = try reader.readDigest(),
        .render_policy_sha256 = try reader.readDigest(),
        .capability_bits = try reader.readU64(),
        .max_wire_bytes = try reader.readU64(),
        .descriptor_sha256 = try reader.readDigest(),
    };
}

fn writeDomain(writer: *Writer, value: context_pack.DomainV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.isolation_key);
    try writer.writeU64(value.adapter_abi);
    try writer.writeDigest(value.provider_namespace_sha256);
    try writer.writeDigest(value.model_sha256);
    try writer.writeDigest(value.tokenizer_sha256);
    try writer.writeDigest(value.render_policy_sha256);
    try writer.writeDigest(value.domain_sha256);
}

fn readDomain(reader: *Reader) Error!context_pack.DomainV1 {
    return .{
        .abi_version = try reader.readU64(),
        .isolation_key = try reader.readU64(),
        .adapter_abi = try reader.readU64(),
        .provider_namespace_sha256 = try reader.readDigest(),
        .model_sha256 = try reader.readDigest(),
        .tokenizer_sha256 = try reader.readDigest(),
        .render_policy_sha256 = try reader.readDigest(),
        .domain_sha256 = try reader.readDigest(),
    };
}

fn writePolicy(writer: *Writer, value: context_pack.PolicyV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU32(value.max_spans);
    try writer.writeU64(value.max_input_tokens);
    try writer.writeU64(value.fixed_overhead_tokens);
    try writer.writeDigest(value.policy_sha256);
}

fn readPolicy(reader: *Reader) Error!context_pack.PolicyV1 {
    return .{
        .abi_version = try reader.readU64(),
        .max_spans = try reader.readU32(),
        .max_input_tokens = try reader.readU64(),
        .fixed_overhead_tokens = try reader.readU64(),
        .policy_sha256 = try reader.readDigest(),
    };
}

fn writeSpan(writer: *Writer, value: context_pack.SpanV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU32(value.sequence);
    try writer.writeU8(@intFromEnum(value.kind));
    try writer.writeU8(@intFromEnum(value.reuse_mode));
    try writer.writeU8(@intFromEnum(value.retention));
    try writer.writeDigest(value.content_sha256);
    try writer.writeDigest(value.rendered_sha256);
    try writer.writeDigest(value.provenance_sha256);
    try writer.writeU64(value.token_count);
    try writer.writeDigest(value.span_sha256);
}

fn readSpan(reader: *Reader) Error!context_pack.SpanV1 {
    const abi_version = try reader.readU64();
    const sequence = try reader.readU32();
    const kind: context_pack.SpanKind = switch (try reader.readU8()) {
        0 => .system,
        1 => .tool,
        2 => .user,
        3 => .assistant,
        4 => .evidence,
        else => return Error.InvalidEnum,
    };
    const reuse_mode: context_pack.ReuseMode = switch (try reader.readU8()) {
        0 => .unique,
        1 => .idempotent_exact,
        else => return Error.InvalidEnum,
    };
    const retention: context_pack.Retention = switch (try reader.readU8()) {
        0 => .required,
        1 => .preserved,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .sequence = sequence,
        .kind = kind,
        .reuse_mode = reuse_mode,
        .retention = retention,
        .content_sha256 = try reader.readDigest(),
        .rendered_sha256 = try reader.readDigest(),
        .provenance_sha256 = try reader.readDigest(),
        .token_count = try reader.readU64(),
        .span_sha256 = try reader.readDigest(),
    };
}

fn writeDecision(writer: *Writer, value: context_pack.DecisionV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU32(value.sequence);
    try writer.writeU8(@intFromEnum(value.action));
    try writer.writeDigest(value.span_sha256);
    try writer.writeU32(value.representative_sequence);
    try writer.writeDigest(value.representative_span_sha256);
    try writer.writeU64(value.logical_tokens);
    try writer.writeU64(value.emitted_tokens);
    try writer.writeDigest(value.decision_sha256);
}

fn readDecision(reader: *Reader) Error!context_pack.DecisionV1 {
    const abi_version = try reader.readU64();
    const sequence = try reader.readU32();
    const action: context_pack.DecisionAction = switch (try reader.readU8()) {
        0 => .emit,
        1 => .alias,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .sequence = sequence,
        .action = action,
        .span_sha256 = try reader.readDigest(),
        .representative_sequence = try reader.readU32(),
        .representative_span_sha256 = try reader.readDigest(),
        .logical_tokens = try reader.readU64(),
        .emitted_tokens = try reader.readU64(),
        .decision_sha256 = try reader.readDigest(),
    };
}

fn writeReceipt(writer: *Writer, value: context_pack.ReceiptV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeDigest(value.domain_sha256);
    try writer.writeDigest(value.policy_sha256);
    try writer.writeU32(value.input_spans);
    try writer.writeU32(value.emitted_spans);
    try writer.writeU32(value.aliased_spans);
    try writer.writeU32(value.required_spans);
    try writer.writeU64(value.logical_tokens);
    try writer.writeU64(value.emitted_tokens);
    try writer.writeU64(value.deduplicated_tokens);
    try writer.writeDigest(value.mapping_chain_sha256);
    try writer.writeDigest(value.emitted_chain_sha256);
    try writer.writeDigest(value.receipt_sha256);
}

fn readReceipt(reader: *Reader) Error!context_pack.ReceiptV1 {
    return .{
        .abi_version = try reader.readU64(),
        .domain_sha256 = try reader.readDigest(),
        .policy_sha256 = try reader.readDigest(),
        .input_spans = try reader.readU32(),
        .emitted_spans = try reader.readU32(),
        .aliased_spans = try reader.readU32(),
        .required_spans = try reader.readU32(),
        .logical_tokens = try reader.readU64(),
        .emitted_tokens = try reader.readU64(),
        .deduplicated_tokens = try reader.readU64(),
        .mapping_chain_sha256 = try reader.readDigest(),
        .emitted_chain_sha256 = try reader.readDigest(),
        .receipt_sha256 = try reader.readDigest(),
    };
}

fn writeObservation(
    writer: *Writer,
    value: context_pack.TokenObservationV1,
) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU8(@intFromEnum(value.arm));
    try writer.writeDigest(value.domain_sha256);
    try writer.writeDigest(value.context_chain_sha256);
    try writer.writeDigest(value.wire_sha256);
    try writer.writeDigest(value.tokenizer_execution_sha256);
    try writer.writeU64(value.wire_tokens);
    try writer.writeDigest(value.observation_sha256);
}

fn readObservation(reader: *Reader) Error!context_pack.TokenObservationV1 {
    const abi_version = try reader.readU64();
    const arm: context_pack.ContextArm = switch (try reader.readU8()) {
        0 => .raw,
        1 => .packed_context,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .arm = arm,
        .domain_sha256 = try reader.readDigest(),
        .context_chain_sha256 = try reader.readDigest(),
        .wire_sha256 = try reader.readDigest(),
        .tokenizer_execution_sha256 = try reader.readDigest(),
        .wire_tokens = try reader.readU64(),
        .observation_sha256 = try reader.readDigest(),
    };
}

fn writeReconciliation(
    writer: *Writer,
    value: context_pack.ReconciliationV1,
) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeDigest(value.domain_sha256);
    try writer.writeDigest(value.policy_sha256);
    try writer.writeDigest(value.receipt_sha256);
    try writer.writeDigest(value.raw_observation_sha256);
    try writer.writeDigest(value.packed_observation_sha256);
    try writer.writeDigest(value.tokenizer_execution_sha256);
    try writer.writeU64(value.raw_wire_tokens);
    try writer.writeU64(value.packed_wire_tokens);
    try writer.writeU64(value.wire_deduplicated_tokens);
    try writer.writeU64(value.max_input_tokens);
    try writer.writeU64(value.packed_budget_headroom);
    try writer.writeDigest(value.reconciliation_sha256);
}

fn readReconciliation(reader: *Reader) Error!context_pack.ReconciliationV1 {
    return .{
        .abi_version = try reader.readU64(),
        .domain_sha256 = try reader.readDigest(),
        .policy_sha256 = try reader.readDigest(),
        .receipt_sha256 = try reader.readDigest(),
        .raw_observation_sha256 = try reader.readDigest(),
        .packed_observation_sha256 = try reader.readDigest(),
        .tokenizer_execution_sha256 = try reader.readDigest(),
        .raw_wire_tokens = try reader.readU64(),
        .packed_wire_tokens = try reader.readU64(),
        .wire_deduplicated_tokens = try reader.readU64(),
        .max_input_tokens = try reader.readU64(),
        .packed_budget_headroom = try reader.readU64(),
        .reconciliation_sha256 = try reader.readDigest(),
    };
}

fn writeExecution(
    writer: *Writer,
    value: context_adapter.ExecutionV1,
) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeDigest(value.descriptor_sha256);
    try writer.writeDigest(value.domain_sha256);
    try writer.writeDigest(value.policy_sha256);
    try writer.writeDigest(value.pack_receipt_sha256);
    try writer.writeDigest(value.render_execution_sha256);
    try writer.writeU64(value.raw_wire_bytes);
    try writer.writeU64(value.packed_wire_bytes);
    try writeObservation(writer, value.raw_observation);
    try writeObservation(writer, value.packed_observation);
    try writeReconciliation(writer, value.reconciliation);
    try writer.writeDigest(value.execution_sha256);
}

fn readExecution(reader: *Reader) Error!context_adapter.ExecutionV1 {
    return .{
        .abi_version = try reader.readU64(),
        .descriptor_sha256 = try reader.readDigest(),
        .domain_sha256 = try reader.readDigest(),
        .policy_sha256 = try reader.readDigest(),
        .pack_receipt_sha256 = try reader.readDigest(),
        .render_execution_sha256 = try reader.readDigest(),
        .raw_wire_bytes = try reader.readU64(),
        .packed_wire_bytes = try reader.readU64(),
        .raw_observation = try readObservation(reader),
        .packed_observation = try readObservation(reader),
        .reconciliation = try readReconciliation(reader),
        .execution_sha256 = try reader.readDigest(),
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

fn overlap(
    comptime Left: type,
    left: []const Left,
    comptime Right: type,
    right: []const Right,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const left_bytes = std.math.mul(usize, left.len, @sizeOf(Left)) catch
        return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch
        return true;
    const right_start = @intFromPtr(right.ptr);
    const right_bytes = std.math.mul(usize, right.len, @sizeOf(Right)) catch
        return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch
        return true;
    return left_start < right_end and right_start < left_end;
}

fn testDigest(seed: u8) Digest {
    var value: Digest = undefined;
    @memset(&value, seed);
    return value;
}

const TestAdapter = struct {
    render_execution_sha256: Digest = testDigest(0x71),
    tokenizer_execution_sha256: Digest = testDigest(0x72),

    fn adapter(
        self: *TestAdapter,
        descriptor: context_adapter.DescriptorV1,
    ) context_adapter.AdapterV1 {
        return .{
            .adapter_context = self,
            .descriptor = descriptor,
            .renderFn = render,
            .countFn = count,
        };
    }

    fn render(
        pointer: *anyopaque,
        arm: context_pack.ContextArm,
        spans: []const context_pack.SpanV1,
        decisions: []const context_pack.DecisionV1,
        destination: []u8,
    ) context_adapter.CallbackError!context_adapter.RenderResult {
        const self: *TestAdapter = @ptrCast(@alignCast(pointer));
        const raw = "[AABBBBBBC]";
        const packed_bytes = "[AABBBC]";
        const source = switch (arm) {
            .raw => raw,
            .packed_context => packed_bytes,
        };
        if (spans.len != 4 or decisions.len != 4 or
            destination.len < source.len)
            return context_adapter.CallbackError.WireCapacityExceeded;
        @memcpy(destination[0..source.len], source);
        return .{
            .written = source.len,
            .render_execution_sha256 = self.render_execution_sha256,
        };
    }

    fn count(
        pointer: *anyopaque,
        wire: []const u8,
    ) context_adapter.CallbackError!context_adapter.TokenCountResult {
        const self: *TestAdapter = @ptrCast(@alignCast(pointer));
        return .{
            .tokens = @intCast(wire.len),
            .tokenizer_execution_sha256 = self.tokenizer_execution_sha256,
        };
    }
};

const TestEvidence = struct {
    descriptor: context_adapter.DescriptorV1,
    domain: context_pack.DomainV1,
    policy: context_pack.PolicyV1,
    spans: [4]context_pack.SpanV1,
    decisions: [4]context_pack.DecisionV1,
    receipt: context_pack.ReceiptV1,
    execution: context_adapter.ExecutionV1,
    packed_wire: [8]u8,
};

fn testSpan(
    sequence: u32,
    kind: context_pack.SpanKind,
    reuse_mode: context_pack.ReuseMode,
    retention: context_pack.Retention,
    content: u8,
    provenance: u8,
    tokens: u64,
) !context_pack.SpanV1 {
    return context_pack.makeSpanV1(
        sequence,
        kind,
        reuse_mode,
        retention,
        testDigest(content),
        testDigest(content),
        testDigest(provenance),
        tokens,
    );
}

fn testEvidence() !TestEvidence {
    const adapter_abi: u64 = 0x5445_5354_5749_5201;
    const provider = testDigest(0x11);
    const tokenizer = testDigest(0x22);
    const render_policy = testDigest(0x33);
    const domain = try context_pack.makeDomainV1(
        91,
        adapter_abi,
        provider,
        testDigest(0x44),
        tokenizer,
        render_policy,
    );
    const policy = try context_pack.makePolicyV1(4, 10, 2);
    const spans = [_]context_pack.SpanV1{
        try testSpan(0, .system, .unique, .required, 0xa1, 0xb1, 2),
        try testSpan(1, .tool, .idempotent_exact, .required, 0xa2, 0xb2, 3),
        try testSpan(2, .tool, .idempotent_exact, .required, 0xa2, 0xb3, 3),
        try testSpan(3, .user, .unique, .preserved, 0xa3, 0xb4, 1),
    };
    var decisions = [_]context_pack.DecisionV1{.{}} ** spans.len;
    const receipt = try context_pack.packV1(
        domain,
        policy,
        &spans,
        &decisions,
    );
    const descriptor = try context_adapter.makeDescriptorV1(
        adapter_abi,
        provider,
        tokenizer,
        render_policy,
        context_adapter.required_capabilities,
        64,
    );
    var adapter: TestAdapter = .{};
    var scratch: [64]u8 = undefined;
    const execution = try context_adapter.executeReusedScratchV1(
        adapter.adapter(descriptor),
        domain,
        policy,
        &spans,
        &decisions,
        receipt,
        &scratch,
    );
    var packed_wire: [8]u8 = undefined;
    @memcpy(&packed_wire, scratch[0..packed_wire.len]);
    return .{
        .descriptor = descriptor,
        .domain = domain,
        .policy = policy,
        .spans = spans,
        .decisions = decisions,
        .receipt = receipt,
        .execution = execution,
        .packed_wire = packed_wire,
    };
}

test "context evidence wire round trips without allocation" {
    const evidence = try testEvidence();
    const expected_len = try encodedLenV1(
        evidence.spans.len,
        evidence.packed_wire.len,
    );
    try std.testing.expectEqual(@as(usize, 2654), expected_len);
    var bytes: [4096]u8 = [_]u8{0xcc} ** 4096;
    const encoded = try encodeV1(
        evidence.descriptor,
        evidence.domain,
        evidence.policy,
        &evidence.spans,
        &evidence.decisions,
        evidence.receipt,
        evidence.execution,
        &evidence.packed_wire,
        &bytes,
    );
    try std.testing.expectEqual(expected_len, encoded.len);
    try std.testing.expect(std.mem.allEqual(u8, bytes[encoded.len..], 0xcc));
    var spans: [4]context_pack.SpanV1 = undefined;
    var decisions: [4]context_pack.DecisionV1 = undefined;
    const decoded = try decodeAndVerifyV1(encoded, &spans, &decisions);
    try std.testing.expectEqual(evidence.descriptor, decoded.descriptor);
    try std.testing.expectEqual(evidence.domain, decoded.domain);
    try std.testing.expectEqual(evidence.policy, decoded.policy);
    try std.testing.expectEqualSlices(
        context_pack.SpanV1,
        &evidence.spans,
        decoded.spans,
    );
    try std.testing.expectEqualSlices(
        context_pack.DecisionV1,
        &evidence.decisions,
        decoded.decisions,
    );
    try std.testing.expectEqual(evidence.receipt, decoded.receipt);
    try std.testing.expectEqual(evidence.execution, decoded.execution);
    try std.testing.expectEqualStrings(&evidence.packed_wire, decoded.packed_wire);
    try std.testing.expectEqual(
        try envelopeSha256V1(encoded),
        decoded.envelope_sha256,
    );
}

test "every serialized byte mutation rejects after envelope reseal" {
    const evidence = try testEvidence();
    var original: [4096]u8 = undefined;
    const encoded = try encodeV1(
        evidence.descriptor,
        evidence.domain,
        evidence.policy,
        &evidence.spans,
        &evidence.decisions,
        evidence.receipt,
        evidence.execution,
        &evidence.packed_wire,
        &original,
    );
    const encoded_len = encoded.len;
    var mutated: [4096]u8 = undefined;
    var spans: [4]context_pack.SpanV1 = undefined;
    var decisions: [4]context_pack.DecisionV1 = undefined;
    for (0..encoded_len - digest_bytes) |index| {
        @memcpy(mutated[0..encoded_len], encoded);
        mutated[index] ^= 1;
        resealForTest(mutated[0..encoded_len]);
        if (decodeAndVerifyV1(
            mutated[0..encoded_len],
            &spans,
            &decisions,
        )) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "capacity alias and unsealed drift fail closed" {
    const evidence = try testEvidence();
    var bytes: [4096]u8 = [_]u8{0xaa} ** 4096;
    const required = try encodedLenV1(
        evidence.spans.len,
        evidence.packed_wire.len,
    );
    try std.testing.expectError(
        Error.CapacityExceeded,
        encodeV1(
            evidence.descriptor,
            evidence.domain,
            evidence.policy,
            &evidence.spans,
            &evidence.decisions,
            evidence.receipt,
            evidence.execution,
            &evidence.packed_wire,
            bytes[0 .. required - 1],
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0xaa));

    const encoded = try encodeV1(
        evidence.descriptor,
        evidence.domain,
        evidence.policy,
        &evidence.spans,
        &evidence.decisions,
        evidence.receipt,
        evidence.execution,
        &evidence.packed_wire,
        &bytes,
    );
    var too_few_spans: [3]context_pack.SpanV1 = undefined;
    var decisions: [4]context_pack.DecisionV1 = undefined;
    try std.testing.expectError(
        Error.CapacityExceeded,
        decodeAndVerifyV1(encoded, &too_few_spans, &decisions),
    );
    bytes[header_bytes] ^= 1;
    var spans: [4]context_pack.SpanV1 = undefined;
    try std.testing.expectError(
        Error.InvalidEnvelope,
        decodeAndVerifyV1(encoded, &spans, &decisions),
    );
}

test "wire layout sizes remain explicit and padding independent" {
    try std.testing.expectEqual(@as(usize, 40), header_bytes);
    try std.testing.expectEqual(@as(usize, 160), descriptor_wire_bytes);
    try std.testing.expectEqual(@as(usize, 184), domain_wire_bytes);
    try std.testing.expectEqual(@as(usize, 60), policy_wire_bytes);
    try std.testing.expectEqual(@as(usize, 151), span_wire_bytes);
    try std.testing.expectEqual(@as(usize, 129), decision_wire_bytes);
    try std.testing.expectEqual(@as(usize, 208), receipt_wire_bytes);
    try std.testing.expectEqual(@as(usize, 177), observation_wire_bytes);
    try std.testing.expectEqual(@as(usize, 272), reconciliation_wire_bytes);
    try std.testing.expectEqual(@as(usize, 842), execution_wire_bytes);
    try std.testing.expectEqual(@as(usize, 1526), fixed_wire_bytes);
}
