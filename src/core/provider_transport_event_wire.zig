//! Canonical allocation-free wire for one closed provider transport attempt.
//!
//! The envelope binds transport configuration, dispatch intent, deterministic
//! script, ordered chunks, cancellation handshakes, one terminal outcome, the
//! corresponding Gateway settlement and final transport ledgers. Decoding
//! replays the lifecycle into caller-owned event storage; no live Harness,
//! Gateway pointer, provider SDK, native padding or prompt/response bytes are
//! required.

const std = @import("std");
const gateway = @import("provider_token_gateway.zig");
const transport = @import("provider_transport_harness.zig");
const settlement_wire = @import("provider_settlement_wire.zig");

pub const Digest = gateway.Digest;
pub const wire_abi: u64 = 0x4750_5457_0000_0001;
pub const magic = [_]u8{ 'G', 'P', 'T', 'W', 'I', 'R', 'E', '1' };
pub const flag_require_closed: u32 = 1 << 0;
pub const allowed_flags: u32 = flag_require_closed;
pub const max_supported_events: usize = 8192;

const envelope_domain = "glacier-provider-transport-event-wire-v1\x00";
const configuration_domain =
    "glacier-provider-transport-wire-configuration-v1\x00";
const digest_bytes = @sizeOf(Digest);
const normal_ledger_fields = std.meta.fields(transport.LedgerV1).len;
const cancel_ledger_fields = std.meta.fields(transport.CancelLedgerV1).len;

pub const header_bytes: usize = magic.len + 8 + 8 + 4 * 4;
pub const descriptor_wire_bytes: usize = 8 + 8 + 32 + 8 + 32;
pub const config_wire_bytes: usize = 8 + 32 + 4 + descriptor_wire_bytes;
pub const count_wire_bytes: usize = 1 + 8;
pub const usage_wire_bytes: usize = 8 + count_wire_bytes * 6 + 32;
pub const intent_wire_bytes: usize =
    8 + 8 + 4 + 8 + 8 + 32 + 32 + 8 + 32 + 32;
pub const script_wire_bytes: usize =
    8 + 32 * 3 + 4 + 1 + usage_wire_bytes + 32 * 2;
pub const chunk_wire_bytes: usize = 8 + 32 * 3 + 4 * 2 + 32 * 4;
pub const cancel_request_wire_bytes: usize =
    8 + 32 * 4 + 4 + 32 + 1 + 32;
pub const cancel_ack_wire_bytes: usize =
    8 + 32 + 1 + usage_wire_bytes + 32 * 2;
pub const outcome_wire_bytes: usize =
    8 + 1 + intent_wire_bytes + 32 * 3 + 4 + 32 + usage_wire_bytes + 32 * 2;
pub const cancel_outcome_wire_bytes: usize =
    8 + 1 + intent_wire_bytes + 32 * 5 + 4 + 32 + usage_wire_bytes + 32 * 2;
pub const snapshot_wire_bytes: usize = 8 + 8 + 4 + 4 + normal_ledger_fields * 8;
pub const cancel_snapshot_wire_bytes: usize = 8 + 8 + cancel_ledger_fields * 8;
pub const fixed_wire_bytes: usize = header_bytes + config_wire_bytes +
    digest_bytes + intent_wire_bytes + script_wire_bytes +
    settlement_wire.encoded_bytes + snapshot_wire_bytes +
    cancel_snapshot_wire_bytes + digest_bytes;

pub const Error = error{
    CapacityExceeded,
    LengthOverflow,
    InvalidStorage,
    InvalidMagic,
    InvalidAbi,
    InvalidLength,
    InvalidFlags,
    InvalidEnum,
    InvalidBoolean,
    InvalidEnvelope,
    InvalidEvidence,
    StateDrift,
};

pub const EventKind = enum(u8) {
    chunk,
    cancel_request,
    cancel_ack,
    outcome,
    cancel_outcome,
};

pub const EventV1 = union(EventKind) {
    chunk: transport.ChunkV1,
    cancel_request: transport.CancelRequestV1,
    cancel_ack: transport.CancelAckV1,
    outcome: transport.OutcomeV1,
    cancel_outcome: transport.CancelOutcomeV1,
};

pub const DecodedV1 = struct {
    flags: u32,
    config: transport.ConfigV1,
    slot_capacity: u32,
    intent: gateway.DispatchIntentV1,
    script: transport.ScriptV1,
    events: []const EventV1,
    settlement: settlement_wire.DecodedV1,
    final_snapshot: transport.SnapshotV1,
    final_cancel_snapshot: transport.CancelSnapshotV1,
    envelope_sha256: Digest,
};

const ReplayPhase = enum {
    streaming,
    cancel_pending,
    cancel_acked,
    complete,
};

const ReplayResult = struct {
    emitted_chunks: u32,
    normal_outcome: ?transport.OutcomeV1 = null,
    cancel_outcome: ?transport.CancelOutcomeV1 = null,
    ledger: transport.LedgerV1,
    cancel_ledger: transport.CancelLedgerV1,
};

pub fn encodedLenV1(events: []const EventV1) Error!usize {
    if (events.len == 0 or events.len > max_supported_events)
        return Error.CapacityExceeded;
    var total = fixed_wire_bytes;
    for (events) |event| {
        total = std.math.add(usize, total, 1) catch
            return Error.LengthOverflow;
        total = std.math.add(usize, total, eventPayloadBytes(event)) catch
            return Error.LengthOverflow;
    }
    return total;
}

pub fn encodeV1(
    flags: u32,
    config: transport.ConfigV1,
    slot_capacity: u32,
    intent: gateway.DispatchIntentV1,
    script: transport.ScriptV1,
    events: []const EventV1,
    encoded_settlement: []const u8,
    final_snapshot: transport.SnapshotV1,
    final_cancel_snapshot: transport.CancelSnapshotV1,
    destination: []u8,
) Error![]const u8 {
    if (flags != flag_require_closed) return Error.InvalidFlags;
    if (events.len > std.math.maxInt(u32)) return Error.CapacityExceeded;
    if (encoded_settlement.len != settlement_wire.encoded_bytes)
        return Error.InvalidLength;
    const settlement = settlement_wire.decodeAndVerifyV1(
        encoded_settlement,
    ) catch return Error.InvalidEvidence;
    try replayAndVerifyV1(
        flags,
        config,
        slot_capacity,
        intent,
        script,
        events,
        settlement,
        final_snapshot,
        final_cancel_snapshot,
    );

    const required = try encodedLenV1(events);
    if (destination.len < required) return Error.CapacityExceeded;
    const output = destination[0..required];
    if (overlap(EventV1, events, u8, output) or
        slicesOverlap(u8, encoded_settlement, u8, output))
        return Error.InvalidStorage;
    @memset(output, 0);
    errdefer @memset(output, 0);

    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&magic);
    try writer.writeU64(wire_abi);
    try writer.writeU64(@intCast(required));
    try writer.writeU32(flags);
    try writer.writeU32(@intCast(events.len));
    try writer.writeU32(slot_capacity);
    try writer.writeU32(0);
    try writeConfig(&writer, config);
    try writer.writeDigest(configurationSha256(config, slot_capacity));
    try writeIntent(&writer, intent);
    try writeScript(&writer, script);
    for (events) |event| try writeEvent(&writer, event);
    try writer.writeBytes(encoded_settlement);
    try writeSnapshot(&writer, final_snapshot);
    try writeCancelSnapshot(&writer, final_cancel_snapshot);
    if (writer.position + digest_bytes != output.len)
        return Error.InvalidLength;
    try writer.writeDigest(envelopeSha256(output[0..writer.position]));
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

pub fn decodeAndVerifyV1(
    encoded: []const u8,
    event_storage: []EventV1,
) Error!DecodedV1 {
    if (encoded.len < fixed_wire_bytes + 1) return Error.InvalidLength;
    if (slicesOverlap(u8, encoded, EventV1, event_storage))
        return Error.InvalidStorage;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(magic.len), &magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != wire_abi) return Error.InvalidAbi;
    const declared_length = try reader.readU64();
    if (declared_length != encoded.len) return Error.InvalidLength;
    const flags = try reader.readU32();
    if (flags != flag_require_closed) return Error.InvalidFlags;
    const event_count = try reader.readU32();
    if (event_count == 0 or event_count > max_supported_events or
        event_storage.len < event_count) return Error.CapacityExceeded;
    const slot_capacity = try reader.readU32();
    if (try reader.readU32() != 0) return Error.InvalidFlags;

    const root_offset = encoded.len - digest_bytes;
    const expected_root = envelopeSha256(encoded[0..root_offset]);
    if (!std.mem.eql(u8, &expected_root, encoded[root_offset..]))
        return Error.InvalidEnvelope;

    const config = try readConfig(&reader);
    const configuration_sha256 = try reader.readDigest();
    if (!std.mem.eql(
        u8,
        &configuration_sha256,
        &configurationSha256(config, slot_capacity),
    )) return Error.InvalidEvidence;
    const intent = try readIntent(&reader);
    const script = try readScript(&reader);
    const events = event_storage[0..event_count];
    zeroEvents(events);
    errdefer zeroEvents(events);
    for (events) |*event| event.* = try readEvent(&reader);
    const settlement_prefix = try reader.readBytes(
        settlement_wire.encoded_bytes,
    );
    const settlement = settlement_wire.decodeAndVerifyV1(
        settlement_prefix,
    ) catch return Error.InvalidEvidence;
    const final_snapshot = try readSnapshot(&reader);
    const final_cancel_snapshot = try readCancelSnapshot(&reader);
    const envelope_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &envelope_sha256,
        &expected_root,
    )) return Error.InvalidEnvelope;
    try replayAndVerifyV1(
        flags,
        config,
        slot_capacity,
        intent,
        script,
        events,
        settlement,
        final_snapshot,
        final_cancel_snapshot,
    );
    return .{
        .flags = flags,
        .config = config,
        .slot_capacity = slot_capacity,
        .intent = intent,
        .script = script,
        .events = events,
        .settlement = settlement,
        .final_snapshot = final_snapshot,
        .final_cancel_snapshot = final_cancel_snapshot,
        .envelope_sha256 = envelope_sha256,
    };
}

pub fn replayAndVerifyV1(
    flags: u32,
    config: transport.ConfigV1,
    slot_capacity: u32,
    intent: gateway.DispatchIntentV1,
    script: transport.ScriptV1,
    events: []const EventV1,
    settlement: settlement_wire.DecodedV1,
    final_snapshot: transport.SnapshotV1,
    final_cancel_snapshot: transport.CancelSnapshotV1,
) Error!void {
    if (flags != flag_require_closed or !configValid(config) or
        slot_capacity == 0 or !gateway.dispatchIntentValidV1(intent) or
        !transport.scriptValidV1(script) or
        script.chunk_count > config.max_chunks_per_attempt or
        !std.mem.eql(
            u8,
            &script.descriptor_sha256,
            &config.descriptor.descriptor_sha256,
        ) or !std.mem.eql(
        u8,
        &script.provider_request_sha256,
        &transport.providerRequestSha256(config.descriptor, intent),
    ) or events.len == 0 or events.len > max_supported_events)
        return Error.InvalidEvidence;

    var phase: ReplayPhase = .streaming;
    var emitted_chunks: u32 = 0;
    var current_request: transport.CancelRequestV1 = .{};
    var current_ack: transport.CancelAckV1 = .{};
    var ledger: transport.LedgerV1 = .{
        .active_attempts = 1,
        .started_attempts = 1,
    };
    var cancel_ledger: transport.CancelLedgerV1 = .{};
    var normal_outcome: ?transport.OutcomeV1 = null;
    var cancel_outcome: ?transport.CancelOutcomeV1 = null;

    for (events) |event| switch (event) {
        .chunk => |chunk| {
            if (phase != .streaming or chunk.chunk_index != emitted_chunks or
                !transport.chunkMatchesScriptV1(chunk, intent, script))
                return Error.StateDrift;
            emitted_chunks = std.math.add(u32, emitted_chunks, 1) catch
                return Error.StateDrift;
            ledger.emitted_chunks = std.math.add(
                u64,
                ledger.emitted_chunks,
                1,
            ) catch return Error.StateDrift;
        },
        .cancel_request => |request| {
            if (phase != .streaming or
                !transport.cancelRequestMatchesAttemptV1(
                    request,
                    config.descriptor,
                    intent,
                    script,
                ) or request.emitted_chunks != emitted_chunks)
                return Error.StateDrift;
            current_request = request;
            phase = .cancel_pending;
            cancel_ledger.pending_cancellations = 1;
            cancel_ledger.requested_cancellations = std.math.add(
                u64,
                cancel_ledger.requested_cancellations,
                1,
            ) catch return Error.StateDrift;
        },
        .cancel_ack => |ack| {
            if (phase != .cancel_pending or
                !transport.cancelAckMatchesRequestV1(ack, current_request))
                return Error.StateDrift;
            cancel_ledger.pending_cancellations = 0;
            if (ack.kind == .not_accepted) {
                cancel_ledger.rejected_cancellations = std.math.add(
                    u64,
                    cancel_ledger.rejected_cancellations,
                    1,
                ) catch return Error.StateDrift;
                current_request = .{};
                phase = .streaming;
            } else {
                current_ack = ack;
                phase = .cancel_acked;
            }
        },
        .outcome => |outcome| {
            if (phase != .streaming or emitted_chunks != script.chunk_count or
                !transport.outcomeMatchesScriptV1(
                    outcome,
                    config.descriptor,
                    script,
                ) or !std.meta.eql(outcome.intent, intent))
                return Error.StateDrift;
            ledger.active_attempts = 0;
            ledger.completed_unacknowledged = 1;
            switch (outcome.kind) {
                .succeeded => ledger.successful_outcomes = 1,
                .retryable_no_charge => ledger.retryable_outcomes = 1,
                .ambiguous => ledger.ambiguous_outcomes = 1,
            }
            normal_outcome = outcome;
            phase = .complete;
        },
        .cancel_outcome => |outcome| {
            if (phase != .cancel_acked or
                !transport.cancelOutcomeMatchesAttemptV1(
                    outcome,
                    config.descriptor,
                    intent,
                    script,
                    current_request,
                    current_ack,
                ) or outcome.emitted_chunks != emitted_chunks)
                return Error.StateDrift;
            ledger.active_attempts = 0;
            ledger.completed_unacknowledged = 1;
            switch (outcome.kind) {
                .confirmed => cancel_ledger.confirmed_cancellations = 1,
                .too_late_succeeded => cancel_ledger.too_late_successes = 1,
                .ambiguous => cancel_ledger.ambiguous_cancellations = 1,
            }
            if (outcome.usage.billable_tokens.known) {
                cancel_ledger.known_post_cancel_billable_tokens =
                    outcome.usage.billable_tokens.value;
            } else {
                cancel_ledger.unknown_post_cancel_usage = 1;
            }
            cancel_outcome = outcome;
            phase = .complete;
        },
    };

    if (phase != .complete or (normal_outcome == null) ==
        (cancel_outcome == null)) return Error.StateDrift;
    ledger.completed_unacknowledged = 0;
    ledger.acknowledged_attempts = 1;
    const replay: ReplayResult = .{
        .emitted_chunks = emitted_chunks,
        .normal_outcome = normal_outcome,
        .cancel_outcome = cancel_outcome,
        .ledger = ledger,
        .cancel_ledger = cancel_ledger,
    };
    if (!settlementMatchesReplay(settlement, intent, replay) or
        !snapshotMatches(
            final_snapshot,
            config,
            slot_capacity,
            ledger,
        ) or !cancelSnapshotMatches(
        final_cancel_snapshot,
        config,
        cancel_ledger,
    )) return Error.InvalidEvidence;
}

fn settlementMatchesReplay(
    settlement: settlement_wire.DecodedV1,
    intent: gateway.DispatchIntentV1,
    replay: ReplayResult,
) bool {
    if (!std.meta.eql(settlement.receipt.intent, intent)) return false;
    if (replay.normal_outcome) |outcome| {
        const expected: gateway.AttemptOutcome = switch (outcome.kind) {
            .succeeded => .succeeded,
            .retryable_no_charge => .retryable_no_charge,
            .ambiguous => .ambiguous,
        };
        return settlement.receipt.outcome == expected and
            std.meta.eql(settlement.receipt.usage, outcome.usage) and
            std.mem.eql(
                u8,
                &settlement.receipt.result_sha256,
                &outcome.result_sha256,
            );
    }
    const outcome = replay.cancel_outcome.?;
    const expected: gateway.AttemptOutcome = switch (outcome.kind) {
        .confirmed => .failed,
        .too_late_succeeded => .succeeded,
        .ambiguous => .ambiguous,
    };
    return settlement.receipt.outcome == expected and
        std.meta.eql(settlement.receipt.usage, outcome.usage) and
        std.mem.eql(
            u8,
            &settlement.receipt.result_sha256,
            &outcome.result_sha256,
        );
}

fn snapshotMatches(
    snapshot: transport.SnapshotV1,
    config: transport.ConfigV1,
    slot_capacity: u32,
    ledger: transport.LedgerV1,
) bool {
    return snapshot.abi_version == transport.snapshot_abi and
        snapshot.harness_epoch == config.harness_epoch and
        snapshot.slot_capacity == slot_capacity and
        snapshot.max_chunks_per_attempt == config.max_chunks_per_attempt and
        std.meta.eql(snapshot.ledger, ledger);
}

fn cancelSnapshotMatches(
    snapshot: transport.CancelSnapshotV1,
    config: transport.ConfigV1,
    ledger: transport.CancelLedgerV1,
) bool {
    return snapshot.abi_version == transport.cancel_snapshot_abi and
        snapshot.harness_epoch == config.harness_epoch and
        std.meta.eql(snapshot.ledger, ledger);
}

fn configValid(config: transport.ConfigV1) bool {
    return config.harness_epoch != 0 and
        !std.mem.eql(u8, &config.challenge, &transport.zero_digest) and
        config.max_chunks_per_attempt != 0 and
        config.max_chunks_per_attempt <= transport.max_supported_chunks and
        transport.descriptorValidV1(config.descriptor);
}

fn configurationSha256(
    config: transport.ConfigV1,
    slot_capacity: u32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(configuration_domain);
    hashU64(&hash, transport.abi);
    hashU64(&hash, transport.descriptor_abi);
    hashU64(&hash, transport.script_abi);
    hashU64(&hash, transport.chunk_abi);
    hashU64(&hash, transport.outcome_abi);
    hashU64(&hash, transport.cancel_request_abi);
    hashU64(&hash, transport.cancel_ack_abi);
    hashU64(&hash, transport.cancel_outcome_abi);
    hashU64(&hash, config.harness_epoch);
    hash.update(&config.challenge);
    hashU32(&hash, config.max_chunks_per_attempt);
    hash.update(&config.descriptor.descriptor_sha256);
    hashU32(&hash, slot_capacity);
    var value: Digest = undefined;
    hash.final(&value);
    return value;
}

fn eventPayloadBytes(event: EventV1) usize {
    return switch (event) {
        .chunk => chunk_wire_bytes,
        .cancel_request => cancel_request_wire_bytes,
        .cancel_ack => cancel_ack_wire_bytes,
        .outcome => outcome_wire_bytes,
        .cancel_outcome => cancel_outcome_wire_bytes,
    };
}

fn writeEvent(writer: *Writer, event: EventV1) Error!void {
    switch (event) {
        .chunk => |value| {
            try writer.writeU8(@intFromEnum(EventKind.chunk));
            try writeChunk(writer, value);
        },
        .cancel_request => |value| {
            try writer.writeU8(@intFromEnum(EventKind.cancel_request));
            try writeCancelRequest(writer, value);
        },
        .cancel_ack => |value| {
            try writer.writeU8(@intFromEnum(EventKind.cancel_ack));
            try writeCancelAck(writer, value);
        },
        .outcome => |value| {
            try writer.writeU8(@intFromEnum(EventKind.outcome));
            try writeOutcome(writer, value);
        },
        .cancel_outcome => |value| {
            try writer.writeU8(@intFromEnum(EventKind.cancel_outcome));
            try writeCancelOutcome(writer, value);
        },
    }
}

fn readEvent(reader: *Reader) Error!EventV1 {
    return switch (try reader.readU8()) {
        0 => .{ .chunk = try readChunk(reader) },
        1 => .{ .cancel_request = try readCancelRequest(reader) },
        2 => .{ .cancel_ack = try readCancelAck(reader) },
        3 => .{ .outcome = try readOutcome(reader) },
        4 => .{ .cancel_outcome = try readCancelOutcome(reader) },
        else => Error.InvalidEnum,
    };
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

fn writeConfig(writer: *Writer, value: transport.ConfigV1) Error!void {
    try writer.writeU64(value.harness_epoch);
    try writer.writeDigest(value.challenge);
    try writer.writeU32(value.max_chunks_per_attempt);
    try writeDescriptor(writer, value.descriptor);
}

fn readConfig(reader: *Reader) Error!transport.ConfigV1 {
    return .{
        .harness_epoch = try reader.readU64(),
        .challenge = try reader.readDigest(),
        .max_chunks_per_attempt = try reader.readU32(),
        .descriptor = try readDescriptor(reader),
    };
}

fn writeDescriptor(writer: *Writer, value: transport.DescriptorV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.transport_adapter_abi);
    try writer.writeDigest(value.provider_namespace_sha256);
    try writer.writeU64(value.capability_bits);
    try writer.writeDigest(value.descriptor_sha256);
}

fn readDescriptor(reader: *Reader) Error!transport.DescriptorV1 {
    return .{
        .abi_version = try reader.readU64(),
        .transport_adapter_abi = try reader.readU64(),
        .provider_namespace_sha256 = try reader.readDigest(),
        .capability_bits = try reader.readU64(),
        .descriptor_sha256 = try reader.readDigest(),
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

fn writeScript(writer: *Writer, value: transport.ScriptV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeDigest(value.descriptor_sha256);
    try writer.writeDigest(value.provider_request_sha256);
    try writer.writeDigest(value.chunk_seed_sha256);
    try writer.writeU32(value.chunk_count);
    try writer.writeU8(@intFromEnum(value.terminal_mode));
    try writeUsage(writer, value.usage);
    try writer.writeDigest(value.result_sha256);
    try writer.writeDigest(value.script_sha256);
}

fn readScript(reader: *Reader) Error!transport.ScriptV1 {
    const abi_version = try reader.readU64();
    const descriptor_sha256 = try reader.readDigest();
    const provider_request_sha256 = try reader.readDigest();
    const chunk_seed_sha256 = try reader.readDigest();
    const chunk_count = try reader.readU32();
    const terminal_mode: transport.TerminalMode = switch (try reader.readU8()) {
        0 => .succeeded,
        1 => .retryable_no_charge,
        2 => .ambiguous,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .descriptor_sha256 = descriptor_sha256,
        .provider_request_sha256 = provider_request_sha256,
        .chunk_seed_sha256 = chunk_seed_sha256,
        .chunk_count = chunk_count,
        .terminal_mode = terminal_mode,
        .usage = try readUsage(reader),
        .result_sha256 = try reader.readDigest(),
        .script_sha256 = try reader.readDigest(),
    };
}

fn writeChunk(writer: *Writer, value: transport.ChunkV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeDigest(value.intent_sha256);
    try writer.writeDigest(value.provider_request_sha256);
    try writer.writeDigest(value.script_sha256);
    try writer.writeU32(value.chunk_index);
    try writer.writeU32(value.chunk_count);
    try writer.writeDigest(value.before_chain_sha256);
    try writer.writeDigest(value.chunk_sha256);
    try writer.writeDigest(value.after_chain_sha256);
    try writer.writeDigest(value.evidence_sha256);
}

fn readChunk(reader: *Reader) Error!transport.ChunkV1 {
    return .{
        .abi_version = try reader.readU64(),
        .intent_sha256 = try reader.readDigest(),
        .provider_request_sha256 = try reader.readDigest(),
        .script_sha256 = try reader.readDigest(),
        .chunk_index = try reader.readU32(),
        .chunk_count = try reader.readU32(),
        .before_chain_sha256 = try reader.readDigest(),
        .chunk_sha256 = try reader.readDigest(),
        .after_chain_sha256 = try reader.readDigest(),
        .evidence_sha256 = try reader.readDigest(),
    };
}

fn writeCancelRequest(
    writer: *Writer,
    value: transport.CancelRequestV1,
) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeDigest(value.intent_sha256);
    try writer.writeDigest(value.descriptor_sha256);
    try writer.writeDigest(value.provider_request_sha256);
    try writer.writeDigest(value.script_sha256);
    try writer.writeU32(value.emitted_chunks);
    try writer.writeDigest(value.response_chain_sha256);
    try writer.writeU8(@intFromEnum(value.reason));
    try writer.writeDigest(value.request_sha256);
}

fn readCancelRequest(reader: *Reader) Error!transport.CancelRequestV1 {
    const abi_version = try reader.readU64();
    const intent_sha256 = try reader.readDigest();
    const descriptor_sha256 = try reader.readDigest();
    const provider_request_sha256 = try reader.readDigest();
    const script_sha256 = try reader.readDigest();
    const emitted_chunks = try reader.readU32();
    const response_chain_sha256 = try reader.readDigest();
    const reason: transport.CancelReason = switch (try reader.readU8()) {
        0 => .all_consumers_left,
        1 => .deadline_expired,
        2 => .budget_pressure,
        3 => .shutdown,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .intent_sha256 = intent_sha256,
        .descriptor_sha256 = descriptor_sha256,
        .provider_request_sha256 = provider_request_sha256,
        .script_sha256 = script_sha256,
        .emitted_chunks = emitted_chunks,
        .response_chain_sha256 = response_chain_sha256,
        .reason = reason,
        .request_sha256 = try reader.readDigest(),
    };
}

fn writeCancelAck(writer: *Writer, value: transport.CancelAckV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeDigest(value.cancel_request_sha256);
    try writer.writeU8(@intFromEnum(value.kind));
    try writeUsage(writer, value.usage);
    try writer.writeDigest(value.result_sha256);
    try writer.writeDigest(value.ack_sha256);
}

fn readCancelAck(reader: *Reader) Error!transport.CancelAckV1 {
    const abi_version = try reader.readU64();
    const cancel_request_sha256 = try reader.readDigest();
    const kind: transport.CancelAckKind = switch (try reader.readU8()) {
        0 => .not_accepted,
        1 => .confirmed,
        2 => .too_late_succeeded,
        3 => .ambiguous,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .cancel_request_sha256 = cancel_request_sha256,
        .kind = kind,
        .usage = try readUsage(reader),
        .result_sha256 = try reader.readDigest(),
        .ack_sha256 = try reader.readDigest(),
    };
}

fn writeOutcome(writer: *Writer, value: transport.OutcomeV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU8(@intFromEnum(value.kind));
    try writeIntent(writer, value.intent);
    try writer.writeDigest(value.descriptor_sha256);
    try writer.writeDigest(value.provider_request_sha256);
    try writer.writeDigest(value.script_sha256);
    try writer.writeU32(value.emitted_chunks);
    try writer.writeDigest(value.response_chain_sha256);
    try writeUsage(writer, value.usage);
    try writer.writeDigest(value.result_sha256);
    try writer.writeDigest(value.outcome_sha256);
}

fn readOutcome(reader: *Reader) Error!transport.OutcomeV1 {
    const abi_version = try reader.readU64();
    const kind: transport.OutcomeKind = switch (try reader.readU8()) {
        0 => .succeeded,
        1 => .retryable_no_charge,
        2 => .ambiguous,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .kind = kind,
        .intent = try readIntent(reader),
        .descriptor_sha256 = try reader.readDigest(),
        .provider_request_sha256 = try reader.readDigest(),
        .script_sha256 = try reader.readDigest(),
        .emitted_chunks = try reader.readU32(),
        .response_chain_sha256 = try reader.readDigest(),
        .usage = try readUsage(reader),
        .result_sha256 = try reader.readDigest(),
        .outcome_sha256 = try reader.readDigest(),
    };
}

fn writeCancelOutcome(
    writer: *Writer,
    value: transport.CancelOutcomeV1,
) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU8(@intFromEnum(value.kind));
    try writeIntent(writer, value.intent);
    try writer.writeDigest(value.descriptor_sha256);
    try writer.writeDigest(value.provider_request_sha256);
    try writer.writeDigest(value.script_sha256);
    try writer.writeDigest(value.cancel_request_sha256);
    try writer.writeDigest(value.cancel_ack_sha256);
    try writer.writeU32(value.emitted_chunks);
    try writer.writeDigest(value.response_chain_sha256);
    try writeUsage(writer, value.usage);
    try writer.writeDigest(value.result_sha256);
    try writer.writeDigest(value.outcome_sha256);
}

fn readCancelOutcome(reader: *Reader) Error!transport.CancelOutcomeV1 {
    const abi_version = try reader.readU64();
    const kind: transport.CancelOutcomeKind = switch (try reader.readU8()) {
        0 => .confirmed,
        1 => .too_late_succeeded,
        2 => .ambiguous,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .kind = kind,
        .intent = try readIntent(reader),
        .descriptor_sha256 = try reader.readDigest(),
        .provider_request_sha256 = try reader.readDigest(),
        .script_sha256 = try reader.readDigest(),
        .cancel_request_sha256 = try reader.readDigest(),
        .cancel_ack_sha256 = try reader.readDigest(),
        .emitted_chunks = try reader.readU32(),
        .response_chain_sha256 = try reader.readDigest(),
        .usage = try readUsage(reader),
        .result_sha256 = try reader.readDigest(),
        .outcome_sha256 = try reader.readDigest(),
    };
}

fn writeLedger(writer: *Writer, value: transport.LedgerV1) Error!void {
    inline for (std.meta.fields(transport.LedgerV1)) |field|
        try writer.writeU64(@field(value, field.name));
}

fn readLedger(reader: *Reader) Error!transport.LedgerV1 {
    var value: transport.LedgerV1 = .{};
    inline for (std.meta.fields(transport.LedgerV1)) |field|
        @field(value, field.name) = try reader.readU64();
    return value;
}

fn writeCancelLedger(
    writer: *Writer,
    value: transport.CancelLedgerV1,
) Error!void {
    inline for (std.meta.fields(transport.CancelLedgerV1)) |field|
        try writer.writeU64(@field(value, field.name));
}

fn readCancelLedger(reader: *Reader) Error!transport.CancelLedgerV1 {
    var value: transport.CancelLedgerV1 = .{};
    inline for (std.meta.fields(transport.CancelLedgerV1)) |field|
        @field(value, field.name) = try reader.readU64();
    return value;
}

fn writeSnapshot(writer: *Writer, value: transport.SnapshotV1) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.harness_epoch);
    try writer.writeU32(value.slot_capacity);
    try writer.writeU32(value.max_chunks_per_attempt);
    try writeLedger(writer, value.ledger);
}

fn readSnapshot(reader: *Reader) Error!transport.SnapshotV1 {
    return .{
        .abi_version = try reader.readU64(),
        .harness_epoch = try reader.readU64(),
        .slot_capacity = try reader.readU32(),
        .max_chunks_per_attempt = try reader.readU32(),
        .ledger = try readLedger(reader),
    };
}

fn writeCancelSnapshot(
    writer: *Writer,
    value: transport.CancelSnapshotV1,
) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.harness_epoch);
    try writeCancelLedger(writer, value.ledger);
}

fn readCancelSnapshot(reader: *Reader) Error!transport.CancelSnapshotV1 {
    return .{
        .abi_version = try reader.readU64(),
        .harness_epoch = try reader.readU64(),
        .ledger = try readCancelLedger(reader),
    };
}

fn envelopeSha256(prefix: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(envelope_domain);
    hash.update(prefix);
    var value: Digest = undefined;
    hash.final(&value);
    return value;
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn zeroEvents(events: []EventV1) void {
    for (events) |*event| event.* = .{ .chunk = .{} };
}

fn overlap(
    comptime Source: type,
    source: []const Source,
    comptime Destination: type,
    destination: []Destination,
) bool {
    return slicesOverlap(Source, source, Destination, destination);
}

fn slicesOverlap(
    comptime Left: type,
    left: []const Left,
    comptime Right: type,
    right: []const Right,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_bytes = std.math.mul(usize, left.len, @sizeOf(Left)) catch
        return true;
    const right_bytes = std.math.mul(usize, right.len, @sizeOf(Right)) catch
        return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch
        return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch
        return true;
    return left_start < right_end and right_start < left_end;
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

const TestScenario = enum {
    normal_success,
    normal_retry,
    normal_ambiguous,
    cancel_confirmed,
    cancel_too_late,
    cancel_ambiguous,
    cancel_rejected_then_success,
};

const TestFixture = struct {
    config: transport.ConfigV1,
    slot_capacity: u32,
    intent: gateway.DispatchIntentV1,
    script: transport.ScriptV1,
    events: [10]EventV1,
    event_count: usize,
    settlement: [settlement_wire.encoded_bytes]u8,
    final_snapshot: transport.SnapshotV1,
    final_cancel_snapshot: transport.CancelSnapshotV1,
};

fn buildTestFixture(scenario: TestScenario) !TestFixture {
    const request = try gateway.makeRequestV1(
        0x5452_414e_5350_4f52,
        0x5452_414e_5349_534f,
        7,
        1,
        testDigest(0x11),
        testDigest(0x22),
        testDigest(0x33),
        testDigest(0x44),
        testDigest(0x55),
        100,
        50,
        .in_flight,
    );
    const gateway_config: gateway.ConfigV1 = .{
        .gateway_epoch = 0x5452_414e_5347_5701,
        .challenge = testDigest(0xa1),
        .limits = .{
            .max_reserved_tokens = 1_000,
            .max_reserved_tokens_per_isolation = 1_000,
            .max_request_tokens = 500,
            .max_followers_per_owner = 1,
        },
    };
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway.FollowerSlot = .{.{}};
    var token_gateway: gateway.Gateway = .{};
    try token_gateway.init(&owner_slots, &follower_slots, gateway_config);
    const admission = try token_gateway.admit(request);
    const dispatch = try token_gateway.beginDispatch(admission.handle);

    const descriptor = try transport.makeDescriptorV1(
        0x5452_414e_5341_4450,
        testDigest(0x91),
        transport.required_capabilities |
            transport.capability_active_cancellation,
    );
    const config: transport.ConfigV1 = .{
        .harness_epoch = 0x5452_414e_5348_5201,
        .challenge = testDigest(0xa2),
        .max_chunks_per_attempt = 8,
        .descriptor = descriptor,
    };
    var attempt_slots: [1]transport.AttemptSlot = .{.{}};
    var harness: transport.Harness = .{};
    try harness.init(&attempt_slots, config);

    const terminal_mode: transport.TerminalMode = switch (scenario) {
        .normal_retry => .retryable_no_charge,
        .normal_ambiguous => .ambiguous,
        else => .succeeded,
    };
    const script_usage = switch (scenario) {
        .normal_retry => try gateway.makeUsageV1(
            null,
            null,
            null,
            null,
            null,
            0,
        ),
        .normal_ambiguous => try gateway.makeUsageV1(
            100,
            7,
            40,
            null,
            3,
            null,
        ),
        else => try gateway.makeUsageV1(100, 20, 40, 8, 0, 80),
    };
    const script = try transport.makeScriptV1(
        descriptor,
        dispatch.intent,
        testDigest(0x61),
        3,
        terminal_mode,
        script_usage,
        if (terminal_mode == .succeeded)
            testDigest(0x71)
        else
            transport.zero_digest,
    );
    const started = try harness.start(dispatch.permit, script);
    var fixture: TestFixture = undefined;
    fixture.config = config;
    fixture.slot_capacity = attempt_slots.len;
    fixture.intent = dispatch.intent;
    fixture.script = script;
    fixture.event_count = 0;

    const uses_cancel = switch (scenario) {
        .normal_success, .normal_retry, .normal_ambiguous => false,
        else => true,
    };
    const prefix_chunks: u32 = if (uses_cancel) 2 else script.chunk_count;
    var chunk_index: u32 = 0;
    while (chunk_index < prefix_chunks) : (chunk_index += 1) {
        const chunk = switch (try harness.step(started.handle)) {
            .chunk => |value| value,
            .outcome => return error.UnexpectedOutcome,
        };
        fixture.events[fixture.event_count] = .{ .chunk = chunk };
        fixture.event_count += 1;
    }

    var settlement_result: gateway.AttemptResultV2 = undefined;
    if (uses_cancel) {
        const cancellation = try harness.requestCancel(
            started.handle,
            .deadline_expired,
        );
        fixture.events[fixture.event_count] = .{
            .cancel_request = cancellation.request,
        };
        fixture.event_count += 1;
        const ack = switch (scenario) {
            .cancel_confirmed => try transport.makeCancelAckV1(
                cancellation.request,
                .confirmed,
                try gateway.makeUsageV1(100, 5, 81, 0, 0, 24),
                transport.zero_digest,
            ),
            .cancel_too_late => try transport.makeCancelAckV1(
                cancellation.request,
                .too_late_succeeded,
                try gateway.makeUsageV1(100, 20, 40, 8, 0, 80),
                testDigest(0x71),
            ),
            .cancel_ambiguous => try transport.makeCancelAckV1(
                cancellation.request,
                .ambiguous,
                try gateway.makeUsageV1(100, 7, 40, null, 3, null),
                transport.zero_digest,
            ),
            .cancel_rejected_then_success => try transport.makeCancelAckV1(
                cancellation.request,
                .not_accepted,
                try gateway.makeUsageV1(0, 0, 0, 0, 0, 0),
                transport.zero_digest,
            ),
            else => unreachable,
        };
        fixture.events[fixture.event_count] = .{ .cancel_ack = ack };
        fixture.event_count += 1;
        const applied = try harness.applyCancelAck(started.handle, ack);
        if (scenario == .cancel_rejected_then_success) {
            const resumed = switch (applied) {
                .resumed => |value| value,
                .terminal => return error.UnexpectedTerminal,
            };
            while (chunk_index < script.chunk_count) : (chunk_index += 1) {
                const chunk = switch (try harness.step(resumed)) {
                    .chunk => |value| value,
                    .outcome => return error.UnexpectedOutcome,
                };
                fixture.events[fixture.event_count] = .{ .chunk = chunk };
                fixture.event_count += 1;
            }
            const outcome = switch (try harness.step(resumed)) {
                .chunk => return error.UnexpectedChunk,
                .outcome => |value| value,
            };
            fixture.events[fixture.event_count] = .{ .outcome = outcome };
            fixture.event_count += 1;
            settlement_result = try transport.applyOutcome(
                &token_gateway,
                dispatch.permit,
                descriptor,
                script,
                outcome,
            );
        } else {
            const outcome = switch (applied) {
                .resumed => return error.UnexpectedResume,
                .terminal => |value| value,
            };
            fixture.events[fixture.event_count] = .{
                .cancel_outcome = outcome,
            };
            fixture.event_count += 1;
            settlement_result = try transport.applyCancelOutcome(
                &token_gateway,
                dispatch.permit,
                descriptor,
                script,
                cancellation.request,
                ack,
                outcome,
            );
        }
    } else {
        const outcome = switch (try harness.step(started.handle)) {
            .chunk => return error.UnexpectedChunk,
            .outcome => |value| value,
        };
        fixture.events[fixture.event_count] = .{ .outcome = outcome };
        fixture.event_count += 1;
        settlement_result = try transport.applyOutcome(
            &token_gateway,
            dispatch.permit,
            descriptor,
            script,
            outcome,
        );
    }

    _ = try settlement_wire.encodeV1(
        request,
        settlement_result.receipt,
        &fixture.settlement,
    );
    try harness.acknowledge(started.handle);
    fixture.final_cancel_snapshot = try harness.cancelSnapshot();
    fixture.final_snapshot = try harness.close();
    return fixture;
}

test "all terminal and cancellation paths round trip without allocation" {
    inline for (std.meta.tags(TestScenario)) |scenario| {
        const fixture = try buildTestFixture(scenario);
        const events = fixture.events[0..fixture.event_count];
        const required = try encodedLenV1(events);
        var bytes: [5000]u8 = undefined;
        const encoded = try encodeV1(
            flag_require_closed,
            fixture.config,
            fixture.slot_capacity,
            fixture.intent,
            fixture.script,
            events,
            &fixture.settlement,
            fixture.final_snapshot,
            fixture.final_cancel_snapshot,
            &bytes,
        );
        try std.testing.expectEqual(required, encoded.len);
        var decoded_events: [10]EventV1 = undefined;
        const decoded = try decodeAndVerifyV1(encoded, &decoded_events);
        try std.testing.expectEqual(events.len, decoded.events.len);
        try std.testing.expect(std.meta.eql(
            fixture.final_snapshot,
            decoded.final_snapshot,
        ));
        try std.testing.expect(std.meta.eql(
            fixture.final_cancel_snapshot,
            decoded.final_cancel_snapshot,
        ));
        try std.testing.expect(std.meta.eql(
            fixture.intent,
            decoded.settlement.receipt.intent,
        ));
    }
}

test "closed transport wire rejects structural lifecycle substitutions" {
    var fixture = try buildTestFixture(.cancel_confirmed);
    const events = fixture.events[0..fixture.event_count];
    const settlement = try settlement_wire.decodeAndVerifyV1(
        &fixture.settlement,
    );
    try replayAndVerifyV1(
        flag_require_closed,
        fixture.config,
        fixture.slot_capacity,
        fixture.intent,
        fixture.script,
        events,
        settlement,
        fixture.final_snapshot,
        fixture.final_cancel_snapshot,
    );

    const saved = fixture.events[1];
    fixture.events[1] = fixture.events[0];
    try std.testing.expectError(
        Error.StateDrift,
        replayAndVerifyV1(
            flag_require_closed,
            fixture.config,
            fixture.slot_capacity,
            fixture.intent,
            fixture.script,
            events,
            settlement,
            fixture.final_snapshot,
            fixture.final_cancel_snapshot,
        ),
    );
    fixture.events[1] = saved;

    var drifted_snapshot = fixture.final_snapshot;
    drifted_snapshot.ledger.emitted_chunks += 1;
    try std.testing.expectError(
        Error.InvalidEvidence,
        replayAndVerifyV1(
            flag_require_closed,
            fixture.config,
            fixture.slot_capacity,
            fixture.intent,
            fixture.script,
            events,
            settlement,
            drifted_snapshot,
            fixture.final_cancel_snapshot,
        ),
    );

    var wrong_settlement_fixture = try buildTestFixture(.normal_success);
    const wrong_settlement = try settlement_wire.decodeAndVerifyV1(
        &wrong_settlement_fixture.settlement,
    );
    try std.testing.expectError(
        Error.InvalidEvidence,
        replayAndVerifyV1(
            flag_require_closed,
            fixture.config,
            fixture.slot_capacity,
            fixture.intent,
            fixture.script,
            events,
            wrong_settlement,
            fixture.final_snapshot,
            fixture.final_cancel_snapshot,
        ),
    );
}

test "closed cancellation golden rejects every resealed byte mutation" {
    const fixture = try buildTestFixture(.cancel_confirmed);
    const events = fixture.events[0..fixture.event_count];
    var bytes: [5000]u8 = undefined;
    const encoded = try encodeV1(
        flag_require_closed,
        fixture.config,
        fixture.slot_capacity,
        fixture.intent,
        fixture.script,
        events,
        &fixture.settlement,
        fixture.final_snapshot,
        fixture.final_cancel_snapshot,
        &bytes,
    );
    try std.testing.expectEqual(@as(usize, 2987), encoded.len);
    const expected = [_]u8{
        0x49, 0x52, 0x9b, 0x99, 0x5f, 0xdd, 0x95, 0x1a,
        0xa8, 0x22, 0x8d, 0x1e, 0x75, 0xec, 0xbd, 0xd3,
        0xe0, 0xf4, 0x19, 0x93, 0x74, 0x26, 0x1e, 0x70,
        0x43, 0xba, 0x04, 0x11, 0x32, 0x10, 0x37, 0x98,
    };
    try std.testing.expectEqualSlices(
        u8,
        &expected,
        encoded[encoded.len - digest_bytes ..],
    );

    var mutated: [5000]u8 = undefined;
    var event_storage: [10]EventV1 = undefined;
    const root_offset = encoded.len - digest_bytes;
    for (0..root_offset) |offset| {
        @memcpy(mutated[0..encoded.len], encoded);
        mutated[offset] ^= 0x01;
        resealForTest(mutated[0..encoded.len]);
        if (decodeAndVerifyV1(
            mutated[0..encoded.len],
            &event_storage,
        )) |_| return error.AcceptedMutation else |_| {}
    }
}

test "transport wire bounds storage and keeps layout padding independent" {
    var fixture = try buildTestFixture(.cancel_confirmed);
    const events = fixture.events[0..fixture.event_count];
    try std.testing.expectEqual(@as(usize, 40), header_bytes);
    try std.testing.expectEqual(@as(usize, 88), descriptor_wire_bytes);
    try std.testing.expectEqual(@as(usize, 132), config_wire_bytes);
    try std.testing.expectEqual(@as(usize, 267), script_wire_bytes);
    try std.testing.expectEqual(@as(usize, 240), chunk_wire_bytes);
    try std.testing.expectEqual(@as(usize, 205), cancel_request_wire_bytes);
    try std.testing.expectEqual(@as(usize, 199), cancel_ack_wire_bytes);
    try std.testing.expectEqual(@as(usize, 471), outcome_wire_bytes);
    try std.testing.expectEqual(@as(usize, 535), cancel_outcome_wire_bytes);
    try std.testing.expectEqual(@as(usize, 1563), fixed_wire_bytes);

    var bytes: [5000]u8 = undefined;
    const encoded = try encodeV1(
        flag_require_closed,
        fixture.config,
        fixture.slot_capacity,
        fixture.intent,
        fixture.script,
        events,
        &fixture.settlement,
        fixture.final_snapshot,
        fixture.final_cancel_snapshot,
        &bytes,
    );
    var too_few_events: [4]EventV1 = undefined;
    try std.testing.expectError(
        Error.CapacityExceeded,
        decodeAndVerifyV1(encoded, &too_few_events),
    );
    var decoded_events: [10]EventV1 = undefined;
    try std.testing.expectError(
        Error.InvalidLength,
        decodeAndVerifyV1(encoded[0 .. encoded.len - 1], &decoded_events),
    );
    try std.testing.expectError(
        Error.InvalidFlags,
        encodeV1(
            0,
            fixture.config,
            fixture.slot_capacity,
            fixture.intent,
            fixture.script,
            events,
            &fixture.settlement,
            fixture.final_snapshot,
            fixture.final_cancel_snapshot,
            &bytes,
        ),
    );

    const aliased_destination = std.mem.asBytes(&fixture.events);
    try std.testing.expect(aliased_destination.len >= encoded.len);
    try std.testing.expectError(
        Error.InvalidStorage,
        encodeV1(
            flag_require_closed,
            fixture.config,
            fixture.slot_capacity,
            fixture.intent,
            fixture.script,
            events,
            &fixture.settlement,
            fixture.final_snapshot,
            fixture.final_cancel_snapshot,
            aliased_destination,
        ),
    );
}
