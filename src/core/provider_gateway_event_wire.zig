//! Canonical allocation-free wire for a complete provider Gateway event stream.
//!
//! The envelope carries configuration, every EventV2, mandatory settlement
//! evidence for each attempt outcome and a final SnapshotV2. Decoding replays
//! both the public ledger verifier and a stricter owner/consumer lifecycle
//! verifier over caller-owned storage. Native padding and pointers are never
//! serialized.

const std = @import("std");
const gateway = @import("provider_token_gateway.zig");
const settlement_wire = @import("provider_settlement_wire.zig");

pub const Digest = gateway.Digest;
pub const wire_abi: u64 = 0x4750_4557_0000_0001;
pub const magic = [_]u8{ 'G', 'P', 'E', 'W', 'I', 'R', 'E', '1' };
pub const flag_require_closed: u32 = 1 << 0;
pub const allowed_flags: u32 = flag_require_closed;
pub const max_supported_events: usize = 4096;
pub const max_supported_replay_slots: usize = 8192;

const envelope_domain = "glacier-provider-gateway-event-wire-v1\x00";
const request_set_domain = "glacier-provider-request-set-v1\x00";
const digest_bytes: usize = @sizeOf(Digest);
const ledger_fields = std.meta.fields(gateway.LedgerV2).len;

pub const header_bytes: usize = magic.len + 8 + 8 + 4 * 6;
pub const limits_wire_bytes: usize = 8 * 3 + 4;
pub const config_wire_bytes: usize = 8 + 32 + limits_wire_bytes;
pub const ledger_wire_bytes: usize = ledger_fields * 8;
pub const event_wire_bytes: usize =
    8 * 3 + 1 + 4 + 8 * 2 + 32 * 5 + 4 + 32 + 8 * 2 +
    ledger_wire_bytes * 2 + 32 * 2;
pub const event_prefix_bytes: usize = event_wire_bytes + 1;
pub const snapshot_wire_bytes: usize =
    8 + 8 + limits_wire_bytes + 4 + 4 + 8 + ledger_wire_bytes + 32;
pub const fixed_wire_bytes: usize =
    header_bytes + config_wire_bytes + snapshot_wire_bytes + digest_bytes;

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

pub const AttachmentV1 = struct {
    event_index: u32,
    encoded_settlement: []const u8,
};

pub const SettlementBindingV1 = struct {
    event_index: u32 = 0,
    settlement: settlement_wire.DecodedV1 = undefined,
};

pub const ReplayPhase = enum(u8) {
    free,
    ready,
    dispatched,
    ambiguous,
    terminal,
};

pub const ReplayOwnerV1 = struct {
    generation: u64 = 0,
    phase: ReplayPhase = .free,
    owner_request_sha256: Digest = gateway.zero_digest,
    dispatch_key_sha256: Digest = gateway.zero_digest,
    reservation_tokens: u64 = 0,
    request_set_count: u32 = 0,
    request_set_sha256: Digest = gateway.zero_digest,
    next_attempt_generation: u64 = 1,
    active_attempt_generation: u64 = 0,
    active_intent_sha256: Digest = gateway.zero_digest,
    terminal_usage_sha256: Digest = gateway.zero_digest,
    terminal_result_sha256: Digest = gateway.zero_digest,
    terminal_billable_tokens: u64 = 0,
};

pub const ReplayConsumerKind = enum(u8) {
    owner,
    follower,
};

pub const ReplayConsumerV1 = struct {
    occupied: bool = false,
    owner_slot_index: u32 = 0,
    owner_generation: u64 = 0,
    kind: ReplayConsumerKind = .owner,
    request_sha256: Digest = gateway.zero_digest,
};

pub const DecodedV1 = struct {
    flags: u32,
    config: gateway.ConfigV1,
    events: []const gateway.EventV2,
    settlements: []const SettlementBindingV1,
    final_snapshot: gateway.SnapshotV2,
    envelope_sha256: Digest,
};

pub fn encodedLenV1(event_count: usize, settlement_count: usize) Error!usize {
    if (event_count > max_supported_events or settlement_count > event_count)
        return Error.CapacityExceeded;
    const event_bytes = std.math.mul(
        usize,
        event_count,
        event_prefix_bytes,
    ) catch return Error.LengthOverflow;
    const settlement_bytes = std.math.mul(
        usize,
        settlement_count,
        settlement_wire.encoded_bytes,
    ) catch return Error.LengthOverflow;
    var total = std.math.add(
        usize,
        fixed_wire_bytes,
        event_bytes,
    ) catch return Error.LengthOverflow;
    total = std.math.add(usize, total, settlement_bytes) catch
        return Error.LengthOverflow;
    return total;
}

pub fn encodeV1(
    flags: u32,
    config: gateway.ConfigV1,
    owner_capacity: u32,
    follower_capacity: u32,
    events: []const gateway.EventV2,
    attachments: []const AttachmentV1,
    final_snapshot: gateway.SnapshotV2,
    owner_replay: []ReplayOwnerV1,
    consumer_replay: []ReplayConsumerV1,
    binding_scratch: []SettlementBindingV1,
    destination: []u8,
) Error![]const u8 {
    if (flags != flag_require_closed) return Error.InvalidFlags;
    if (events.len > std.math.maxInt(u32) or
        attachments.len > std.math.maxInt(u32)) return Error.CapacityExceeded;
    if (binding_scratch.len < attachments.len)
        return Error.CapacityExceeded;
    const bindings = binding_scratch[0..attachments.len];
    zeroBindings(bindings);
    errdefer zeroBindings(bindings);
    for (attachments, 0..) |attachment, index| {
        if (attachment.encoded_settlement.len != settlement_wire.encoded_bytes)
            return Error.InvalidLength;
        bindings[index] = .{
            .event_index = attachment.event_index,
            .settlement = settlement_wire.decodeAndVerifyV1(
                attachment.encoded_settlement,
            ) catch return Error.InvalidEvidence,
        };
    }
    try replayAndVerifyV1(
        flags,
        config,
        owner_capacity,
        follower_capacity,
        events,
        bindings,
        final_snapshot,
        owner_replay,
        consumer_replay,
    );

    const required = try encodedLenV1(events.len, attachments.len);
    if (destination.len < required) return Error.CapacityExceeded;
    const output = destination[0..required];
    if (overlap(gateway.EventV2, events, u8, output) or
        overlap(AttachmentV1, attachments, u8, output) or
        overlap(ReplayOwnerV1, owner_replay, u8, output) or
        overlap(ReplayConsumerV1, consumer_replay, u8, output) or
        overlap(SettlementBindingV1, bindings, u8, output))
        return Error.InvalidStorage;
    for (attachments) |attachment|
        if (overlap(u8, attachment.encoded_settlement, u8, output))
            return Error.InvalidStorage;

    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&magic);
    try writer.writeU64(wire_abi);
    try writer.writeU64(@intCast(required));
    try writer.writeU32(@intCast(events.len));
    try writer.writeU32(flags);
    try writer.writeU32(owner_capacity);
    try writer.writeU32(follower_capacity);
    try writer.writeU32(@intCast(attachments.len));
    try writer.writeU32(0);
    try writeConfig(&writer, config);

    var attachment_index: usize = 0;
    for (events, 0..) |event, event_index| {
        try writeEvent(&writer, event);
        const has_settlement = attachment_index < attachments.len and
            attachments[attachment_index].event_index == event_index;
        try writer.writeU8(@intFromBool(has_settlement));
        if (has_settlement) {
            try writer.writeBytes(
                attachments[attachment_index].encoded_settlement,
            );
            attachment_index += 1;
        }
    }
    if (attachment_index != attachments.len) return Error.InvalidEvidence;
    try writeSnapshot(&writer, final_snapshot);
    if (writer.position + digest_bytes != output.len)
        return Error.InvalidLength;
    try writer.writeDigest(envelopeSha256(output[0..writer.position]));
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

pub fn decodeAndVerifyV1(
    encoded: []const u8,
    event_storage: []gateway.EventV2,
    owner_replay: []ReplayOwnerV1,
    consumer_replay: []ReplayConsumerV1,
    binding_storage: []SettlementBindingV1,
) Error!DecodedV1 {
    if (encoded.len < fixed_wire_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(magic.len), &magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != wire_abi) return Error.InvalidAbi;
    if (try reader.readU64() != encoded.len) return Error.InvalidLength;
    const event_count: usize = try reader.readU32();
    const flags = try reader.readU32();
    if (flags != flag_require_closed) return Error.InvalidFlags;
    const owner_capacity = try reader.readU32();
    const follower_capacity = try reader.readU32();
    const settlement_count: usize = try reader.readU32();
    if (try reader.readU32() != 0) return Error.InvalidFlags;
    if (try encodedLenV1(event_count, settlement_count) != encoded.len)
        return Error.InvalidLength;
    const consumer_capacity = std.math.add(
        usize,
        owner_capacity,
        follower_capacity,
    ) catch return Error.CapacityExceeded;
    if (consumer_capacity > max_supported_replay_slots or
        event_storage.len < event_count or
        owner_replay.len < owner_capacity or
        consumer_replay.len < consumer_capacity or
        binding_storage.len < settlement_count)
        return Error.CapacityExceeded;

    const events = event_storage[0..event_count];
    const owners = owner_replay[0..owner_capacity];
    const consumers = consumer_replay[0..consumer_capacity];
    const bindings = binding_storage[0..settlement_count];
    if (overlap(u8, encoded, gateway.EventV2, events) or
        overlap(u8, encoded, ReplayOwnerV1, owners) or
        overlap(u8, encoded, ReplayConsumerV1, consumers) or
        overlap(u8, encoded, SettlementBindingV1, bindings) or
        overlap(gateway.EventV2, events, ReplayOwnerV1, owners) or
        overlap(gateway.EventV2, events, ReplayConsumerV1, consumers) or
        overlap(gateway.EventV2, events, SettlementBindingV1, bindings) or
        overlap(ReplayOwnerV1, owners, ReplayConsumerV1, consumers) or
        overlap(ReplayOwnerV1, owners, SettlementBindingV1, bindings) or
        overlap(ReplayConsumerV1, consumers, SettlementBindingV1, bindings))
        return Error.InvalidStorage;

    const root_offset = encoded.len - digest_bytes;
    const expected_root = envelopeSha256(encoded[0..root_offset]);
    if (!std.mem.eql(u8, &expected_root, encoded[root_offset..]))
        return Error.InvalidEnvelope;

    @memset(events, gateway.EventV2{});
    @memset(owners, ReplayOwnerV1{});
    @memset(consumers, ReplayConsumerV1{});
    zeroBindings(bindings);
    errdefer {
        @memset(events, gateway.EventV2{});
        @memset(owners, ReplayOwnerV1{});
        @memset(consumers, ReplayConsumerV1{});
        zeroBindings(bindings);
    }

    const config = try readConfig(&reader);
    var binding_index: usize = 0;
    for (events, 0..) |*event, event_index| {
        event.* = try readEvent(&reader);
        const has_settlement = switch (try reader.readU8()) {
            0 => false,
            1 => true,
            else => return Error.InvalidBoolean,
        };
        if (has_settlement) {
            if (binding_index >= bindings.len) return Error.InvalidLength;
            const settlement_bytes = try reader.readBytes(
                settlement_wire.encoded_bytes,
            );
            bindings[binding_index] = .{
                .event_index = @intCast(event_index),
                .settlement = settlement_wire.decodeAndVerifyV1(
                    settlement_bytes,
                ) catch return Error.InvalidEvidence,
            };
            binding_index += 1;
        }
    }
    if (binding_index != bindings.len) return Error.InvalidLength;
    const final_snapshot = try readSnapshot(&reader);
    const envelope_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &envelope_sha256,
        &expected_root,
    )) return Error.InvalidEnvelope;
    try replayAndVerifyV1(
        flags,
        config,
        owner_capacity,
        follower_capacity,
        events,
        bindings,
        final_snapshot,
        owners,
        consumers,
    );
    return .{
        .flags = flags,
        .config = config,
        .events = events,
        .settlements = bindings,
        .final_snapshot = final_snapshot,
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

pub fn replayAndVerifyV1(
    flags: u32,
    config: gateway.ConfigV1,
    owner_capacity: u32,
    follower_capacity: u32,
    events: []const gateway.EventV2,
    bindings: []const SettlementBindingV1,
    final_snapshot: gateway.SnapshotV2,
    owner_replay: []ReplayOwnerV1,
    consumer_replay: []ReplayConsumerV1,
) Error!void {
    if (flags != flag_require_closed or events.len > max_supported_events)
        return Error.InvalidFlags;
    const consumer_capacity = std.math.add(
        usize,
        owner_capacity,
        follower_capacity,
    ) catch return Error.CapacityExceeded;
    if (consumer_capacity > max_supported_replay_slots or
        owner_replay.len < owner_capacity or
        consumer_replay.len < consumer_capacity)
        return Error.CapacityExceeded;
    const owners = owner_replay[0..owner_capacity];
    const consumers = consumer_replay[0..consumer_capacity];
    @memset(owners, ReplayOwnerV1{});
    @memset(consumers, ReplayConsumerV1{});
    errdefer {
        @memset(owners, ReplayOwnerV1{});
        @memset(consumers, ReplayConsumerV1{});
    }

    var verifier = gateway.VerifierV2.init(
        config,
        owner_capacity,
        follower_capacity,
    ) catch return Error.InvalidEvidence;
    var binding_index: usize = 0;
    for (events, 0..) |event, event_index| {
        verifier.apply(event) catch return Error.StateDrift;
        const needs_settlement = isSettlementKind(event.kind);
        const has_settlement = binding_index < bindings.len and
            bindings[binding_index].event_index == event_index;
        if (needs_settlement != has_settlement) return Error.InvalidEvidence;
        if (has_settlement) {
            if (!settlementMatchesEvent(
                event,
                bindings[binding_index].settlement,
            )) return Error.InvalidEvidence;
            binding_index += 1;
        }
        try applyLifecycleEvent(event, owners, consumers);
    }
    if (binding_index != bindings.len) return Error.InvalidEvidence;
    const derived = verifier.snapshot();
    if (final_snapshot.abi_version != gateway.snapshot_abi or
        !std.meta.eql(derived, final_snapshot)) return Error.StateDrift;
    if (flags & flag_require_closed != 0) {
        if (!ledgerClosed(final_snapshot.ledger)) return Error.StateDrift;
        for (owners) |owner|
            if (owner.phase != .free) return Error.StateDrift;
        for (consumers) |consumer|
            if (consumer.occupied) return Error.StateDrift;
    }
}

fn applyLifecycleEvent(
    event: gateway.EventV2,
    owners: []ReplayOwnerV1,
    consumers: []ReplayConsumerV1,
) Error!void {
    if (event.owner_slot_index >= owners.len) return Error.StateDrift;
    const owner = &owners[event.owner_slot_index];
    switch (event.kind) {
        .owner_admitted => {
            if (owner.phase != .free) return Error.StateDrift;
            const expected_generation = std.math.add(
                u64,
                owner.generation,
                1,
            ) catch return Error.StateDrift;
            if (event.owner_generation != expected_generation or
                event.request_set_count != 1 or !std.mem.eql(
                u8,
                &event.request_set_sha256,
                &appendRequestSetSha256(
                    gateway.zero_digest,
                    0,
                    event.request_sha256,
                ),
            )) return Error.StateDrift;
            const consumer = freeConsumer(consumers) orelse
                return Error.CapacityExceeded;
            owner.* = .{
                .generation = event.owner_generation,
                .phase = .ready,
                .owner_request_sha256 = event.request_sha256,
                .dispatch_key_sha256 = event.dispatch_key_sha256,
                .reservation_tokens = event.reservation_tokens,
                .request_set_count = 1,
                .request_set_sha256 = event.request_set_sha256,
            };
            consumer.* = .{
                .occupied = true,
                .owner_slot_index = event.owner_slot_index,
                .owner_generation = event.owner_generation,
                .kind = .owner,
                .request_sha256 = event.request_sha256,
            };
        },
        .follower_coalesced => {
            if (owner.phase != .ready and owner.phase != .dispatched)
                return Error.StateDrift;
            if (owner.generation != event.owner_generation or
                owner.reservation_tokens != event.reservation_tokens or
                !std.mem.eql(
                    u8,
                    &owner.dispatch_key_sha256,
                    &event.dispatch_key_sha256,
                )) return Error.StateDrift;
            if (findConsumer(
                consumers,
                event.owner_slot_index,
                event.owner_generation,
                event.request_sha256,
            ) != null) return Error.StateDrift;
            const expected_count = std.math.add(
                u32,
                owner.request_set_count,
                1,
            ) catch return Error.StateDrift;
            const expected_root = appendRequestSetSha256(
                owner.request_set_sha256,
                owner.request_set_count,
                event.request_sha256,
            );
            if (event.request_set_count != expected_count or !std.mem.eql(
                u8,
                &event.request_set_sha256,
                &expected_root,
            )) return Error.StateDrift;
            const consumer = freeConsumer(consumers) orelse
                return Error.CapacityExceeded;
            consumer.* = .{
                .occupied = true,
                .owner_slot_index = event.owner_slot_index,
                .owner_generation = event.owner_generation,
                .kind = .follower,
                .request_sha256 = event.request_sha256,
            };
            owner.request_set_count = expected_count;
            owner.request_set_sha256 = expected_root;
        },
        .dispatch_started => {
            try requireOwnerCommon(event, owner, true);
            if (owner.phase != .ready or
                event.attempt_generation != owner.next_attempt_generation)
                return Error.StateDrift;
            var intent: gateway.DispatchIntentV1 = .{
                .gateway_epoch = event.gateway_epoch,
                .owner_slot_index = event.owner_slot_index,
                .owner_generation = event.owner_generation,
                .attempt_generation = event.attempt_generation,
                .request_sha256 = event.request_sha256,
                .dispatch_key_sha256 = event.dispatch_key_sha256,
                .reserved_tokens = event.reservation_tokens,
                .previous_event_chain_sha256 = event.previous_chain_sha256,
            };
            intent.intent_sha256 = gateway.dispatchIntentSha256(intent);
            if (!std.mem.eql(
                u8,
                &event.intent_sha256,
                &intent.intent_sha256,
            )) return Error.StateDrift;
            owner.phase = .dispatched;
            owner.active_attempt_generation = event.attempt_generation;
            owner.active_intent_sha256 = event.intent_sha256;
            owner.next_attempt_generation = std.math.add(
                u64,
                owner.next_attempt_generation,
                1,
            ) catch return Error.StateDrift;
        },
        .retryable_no_charge => {
            try requireActiveAttempt(event, owner, .dispatched);
            owner.phase = .ready;
            owner.active_attempt_generation = 0;
            owner.active_intent_sha256 = gateway.zero_digest;
        },
        .ambiguous => {
            try requireActiveAttempt(event, owner, .dispatched);
            owner.phase = .ambiguous;
        },
        .succeeded, .failed => {
            try requireActiveAttempt(event, owner, .dispatched);
            setTerminal(owner, event);
        },
        .resolved_success, .resolved_failure => {
            try requireActiveAttempt(event, owner, .ambiguous);
            setTerminal(owner, event);
        },
        .follower_cancelled => {
            try requireOwnerCommon(event, owner, false);
            const consumer = findConsumer(
                consumers,
                event.owner_slot_index,
                event.owner_generation,
                event.request_sha256,
            ) orelse return Error.StateDrift;
            if (consumer.kind != .follower) return Error.StateDrift;
            if (owner.phase == .ready) {
                if (event.attempt_generation != 0 or
                    !isZero(event.intent_sha256)) return Error.StateDrift;
            } else if (event.attempt_generation !=
                owner.active_attempt_generation or !std.mem.eql(
                u8,
                &event.intent_sha256,
                &owner.active_intent_sha256,
            )) return Error.StateDrift;
            consumer.* = .{};
            if (owner.phase == .terminal and
                activeConsumerCount(
                    consumers,
                    event.owner_slot_index,
                    event.owner_generation,
                ) == 0) clearOwner(owner, consumers, event.owner_slot_index);
        },
        .owner_cancelled => {
            try requireOwnerCommon(event, owner, true);
            if (owner.phase != .ready or activeFollowerCount(
                consumers,
                event.owner_slot_index,
                event.owner_generation,
            ) != 0) return Error.StateDrift;
            const consumer = findConsumer(
                consumers,
                event.owner_slot_index,
                event.owner_generation,
                event.request_sha256,
            ) orelse return Error.StateDrift;
            if (consumer.kind != .owner) return Error.StateDrift;
            consumer.* = .{};
            clearOwner(owner, consumers, event.owner_slot_index);
        },
        .acknowledged => {
            try requireOwnerCommon(event, owner, false);
            if (owner.phase != .terminal or
                event.attempt_generation != owner.active_attempt_generation or
                !std.mem.eql(
                    u8,
                    &event.intent_sha256,
                    &owner.active_intent_sha256,
                ) or !std.mem.eql(
                u8,
                &event.usage_sha256,
                &owner.terminal_usage_sha256,
            ) or !std.mem.eql(
                u8,
                &event.result_sha256,
                &owner.terminal_result_sha256,
            ) or event.billable_tokens != owner.terminal_billable_tokens)
                return Error.StateDrift;
            const consumer = findConsumer(
                consumers,
                event.owner_slot_index,
                event.owner_generation,
                event.request_sha256,
            ) orelse return Error.StateDrift;
            consumer.* = .{};
            if (activeConsumerCount(
                consumers,
                event.owner_slot_index,
                event.owner_generation,
            ) == 0) clearOwner(owner, consumers, event.owner_slot_index);
        },
    }
}

fn requireOwnerCommon(
    event: gateway.EventV2,
    owner: *const ReplayOwnerV1,
    require_owner_request: bool,
) Error!void {
    if (owner.phase == .free or owner.generation != event.owner_generation or
        owner.reservation_tokens != event.reservation_tokens or
        owner.request_set_count != event.request_set_count or
        !std.mem.eql(
            u8,
            &owner.dispatch_key_sha256,
            &event.dispatch_key_sha256,
        ) or !std.mem.eql(
        u8,
        &owner.request_set_sha256,
        &event.request_set_sha256,
    ) or require_owner_request and !std.mem.eql(
        u8,
        &owner.owner_request_sha256,
        &event.request_sha256,
    )) return Error.StateDrift;
}

fn requireActiveAttempt(
    event: gateway.EventV2,
    owner: *const ReplayOwnerV1,
    phase: ReplayPhase,
) Error!void {
    try requireOwnerCommon(event, owner, true);
    if (owner.phase != phase or
        event.attempt_generation != owner.active_attempt_generation or
        !std.mem.eql(
            u8,
            &event.intent_sha256,
            &owner.active_intent_sha256,
        )) return Error.StateDrift;
}

fn setTerminal(owner: *ReplayOwnerV1, event: gateway.EventV2) void {
    owner.phase = .terminal;
    owner.terminal_usage_sha256 = event.usage_sha256;
    owner.terminal_result_sha256 = event.result_sha256;
    owner.terminal_billable_tokens = event.billable_tokens;
}

fn clearOwner(
    owner: *ReplayOwnerV1,
    consumers: []ReplayConsumerV1,
    owner_slot_index: u32,
) void {
    const generation = owner.generation;
    for (consumers) |*consumer| {
        if (consumer.occupied and
            consumer.owner_slot_index == owner_slot_index and
            consumer.owner_generation == generation) consumer.* = .{};
    }
    owner.* = .{ .generation = generation };
}

fn freeConsumer(consumers: []ReplayConsumerV1) ?*ReplayConsumerV1 {
    for (consumers) |*consumer|
        if (!consumer.occupied) return consumer;
    return null;
}

fn findConsumer(
    consumers: []ReplayConsumerV1,
    owner_slot_index: u32,
    owner_generation: u64,
    request_sha256: Digest,
) ?*ReplayConsumerV1 {
    for (consumers) |*consumer|
        if (consumer.occupied and
            consumer.owner_slot_index == owner_slot_index and
            consumer.owner_generation == owner_generation and std.mem.eql(
            u8,
            &consumer.request_sha256,
            &request_sha256,
        )) return consumer;
    return null;
}

fn activeConsumerCount(
    consumers: []const ReplayConsumerV1,
    owner_slot_index: u32,
    owner_generation: u64,
) usize {
    var count: usize = 0;
    for (consumers) |consumer| {
        if (consumer.occupied and
            consumer.owner_slot_index == owner_slot_index and
            consumer.owner_generation == owner_generation)
        {
            count += 1;
        }
    }
    return count;
}

fn activeFollowerCount(
    consumers: []const ReplayConsumerV1,
    owner_slot_index: u32,
    owner_generation: u64,
) usize {
    var count: usize = 0;
    for (consumers) |consumer| {
        if (consumer.occupied and consumer.kind == .follower and
            consumer.owner_slot_index == owner_slot_index and
            consumer.owner_generation == owner_generation)
        {
            count += 1;
        }
    }
    return count;
}

fn isSettlementKind(kind: gateway.EventKind) bool {
    return switch (kind) {
        .retryable_no_charge,
        .ambiguous,
        .succeeded,
        .failed,
        .resolved_success,
        .resolved_failure,
        => true,
        else => false,
    };
}

fn settlementMatchesEvent(
    event: gateway.EventV2,
    decoded: settlement_wire.DecodedV1,
) bool {
    const receipt = decoded.receipt;
    const expected_outcome: gateway.AttemptOutcome = switch (event.kind) {
        .retryable_no_charge => .retryable_no_charge,
        .ambiguous => .ambiguous,
        .succeeded => .succeeded,
        .failed => .failed,
        .resolved_success => .resolved_success,
        .resolved_failure => .resolved_failure,
        else => return false,
    };
    return receipt.outcome == expected_outcome and
        std.mem.eql(u8, &decoded.request.request_sha256, &event.request_sha256) and
        receipt.intent.gateway_epoch == event.gateway_epoch and
        receipt.intent.owner_slot_index == event.owner_slot_index and
        receipt.intent.owner_generation == event.owner_generation and
        receipt.intent.attempt_generation == event.attempt_generation and
        std.mem.eql(u8, &receipt.intent.request_sha256, &event.request_sha256) and
        std.mem.eql(
            u8,
            &receipt.intent.dispatch_key_sha256,
            &event.dispatch_key_sha256,
        ) and receipt.intent.reserved_tokens == event.reservation_tokens and
        std.mem.eql(u8, &receipt.intent.intent_sha256, &event.intent_sha256) and
        std.mem.eql(u8, &receipt.usage.usage_sha256, &event.usage_sha256) and
        std.mem.eql(u8, &receipt.result_sha256, &event.result_sha256) and
        receipt.request_set_count == event.request_set_count and
        std.mem.eql(
            u8,
            &receipt.request_set_sha256,
            &event.request_set_sha256,
        ) and std.mem.eql(u8, &receipt.event_sha256, &event.event_sha256) and
        event.billable_tokens == if (receipt.usage.billable_tokens.known)
            receipt.usage.billable_tokens.value
        else
            0;
}

fn ledgerClosed(ledger: gateway.LedgerV2) bool {
    return ledger.reserved_tokens == 0 and ledger.active_handles == 0 and
        ledger.ready_owners == 0 and ledger.dispatched_owners == 0 and
        ledger.ambiguous_owners == 0;
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

fn writeLimits(writer: *Writer, value: gateway.LimitsV1) Error!void {
    try writer.writeU64(value.max_reserved_tokens);
    try writer.writeU64(value.max_reserved_tokens_per_isolation);
    try writer.writeU64(value.max_request_tokens);
    try writer.writeU32(value.max_followers_per_owner);
}

fn readLimits(reader: *Reader) Error!gateway.LimitsV1 {
    return .{
        .max_reserved_tokens = try reader.readU64(),
        .max_reserved_tokens_per_isolation = try reader.readU64(),
        .max_request_tokens = try reader.readU64(),
        .max_followers_per_owner = try reader.readU32(),
    };
}

fn writeConfig(writer: *Writer, value: gateway.ConfigV1) Error!void {
    try writer.writeU64(value.gateway_epoch);
    try writer.writeDigest(value.challenge);
    try writeLimits(writer, value.limits);
}

fn readConfig(reader: *Reader) Error!gateway.ConfigV1 {
    return .{
        .gateway_epoch = try reader.readU64(),
        .challenge = try reader.readDigest(),
        .limits = try readLimits(reader),
    };
}

fn writeLedger(writer: *Writer, value: gateway.LedgerV2) Error!void {
    inline for (std.meta.fields(gateway.LedgerV2)) |field|
        try writer.writeU64(@field(value, field.name));
}

fn readLedger(reader: *Reader) Error!gateway.LedgerV2 {
    var value: gateway.LedgerV2 = .{};
    inline for (std.meta.fields(gateway.LedgerV2)) |field|
        @field(value, field.name) = try reader.readU64();
    return value;
}

fn writeEvent(writer: *Writer, value: gateway.EventV2) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.gateway_epoch);
    try writer.writeU64(value.sequence);
    try writer.writeU8(@intFromEnum(value.kind));
    try writer.writeU32(value.owner_slot_index);
    try writer.writeU64(value.owner_generation);
    try writer.writeU64(value.attempt_generation);
    try writer.writeDigest(value.request_sha256);
    try writer.writeDigest(value.dispatch_key_sha256);
    try writer.writeDigest(value.intent_sha256);
    try writer.writeDigest(value.usage_sha256);
    try writer.writeDigest(value.result_sha256);
    try writer.writeU32(value.request_set_count);
    try writer.writeDigest(value.request_set_sha256);
    try writer.writeU64(value.reservation_tokens);
    try writer.writeU64(value.billable_tokens);
    try writeLedger(writer, value.before);
    try writeLedger(writer, value.after);
    try writer.writeDigest(value.previous_chain_sha256);
    try writer.writeDigest(value.event_sha256);
}

fn readEvent(reader: *Reader) Error!gateway.EventV2 {
    const abi_version = try reader.readU64();
    const gateway_epoch = try reader.readU64();
    const sequence = try reader.readU64();
    const kind: gateway.EventKind = switch (try reader.readU8()) {
        0 => .owner_admitted,
        1 => .follower_coalesced,
        2 => .dispatch_started,
        3 => .retryable_no_charge,
        4 => .ambiguous,
        5 => .succeeded,
        6 => .failed,
        7 => .resolved_success,
        8 => .resolved_failure,
        9 => .owner_cancelled,
        10 => .follower_cancelled,
        11 => .acknowledged,
        else => return Error.InvalidEnum,
    };
    return .{
        .abi_version = abi_version,
        .gateway_epoch = gateway_epoch,
        .sequence = sequence,
        .kind = kind,
        .owner_slot_index = try reader.readU32(),
        .owner_generation = try reader.readU64(),
        .attempt_generation = try reader.readU64(),
        .request_sha256 = try reader.readDigest(),
        .dispatch_key_sha256 = try reader.readDigest(),
        .intent_sha256 = try reader.readDigest(),
        .usage_sha256 = try reader.readDigest(),
        .result_sha256 = try reader.readDigest(),
        .request_set_count = try reader.readU32(),
        .request_set_sha256 = try reader.readDigest(),
        .reservation_tokens = try reader.readU64(),
        .billable_tokens = try reader.readU64(),
        .before = try readLedger(reader),
        .after = try readLedger(reader),
        .previous_chain_sha256 = try reader.readDigest(),
        .event_sha256 = try reader.readDigest(),
    };
}

fn writeSnapshot(writer: *Writer, value: gateway.SnapshotV2) Error!void {
    try writer.writeU64(value.abi_version);
    try writer.writeU64(value.gateway_epoch);
    try writeLimits(writer, value.limits);
    try writer.writeU32(value.owner_capacity);
    try writer.writeU32(value.follower_capacity);
    try writer.writeU64(value.next_event_sequence);
    try writeLedger(writer, value.ledger);
    try writer.writeDigest(value.event_chain_sha256);
}

fn readSnapshot(reader: *Reader) Error!gateway.SnapshotV2 {
    return .{
        .abi_version = try reader.readU64(),
        .gateway_epoch = try reader.readU64(),
        .limits = try readLimits(reader),
        .owner_capacity = try reader.readU32(),
        .follower_capacity = try reader.readU32(),
        .next_event_sequence = try reader.readU64(),
        .ledger = try readLedger(reader),
        .event_chain_sha256 = try reader.readDigest(),
    };
}

fn appendRequestSetSha256(
    before_sha256: Digest,
    count_before: u32,
    request_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(request_set_domain);
    hashU64(&hash, gateway.request_abi);
    hash.update(&before_sha256);
    hashU32(&hash, count_before);
    hash.update(&request_sha256);
    return finish(&hash);
}

fn envelopeSha256(prefix: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(envelope_domain);
    hash.update(prefix);
    return finish(&hash);
}

fn resealForTest(encoded: []u8) void {
    const root_offset = encoded.len - digest_bytes;
    const root = envelopeSha256(encoded[0..root_offset]);
    @memcpy(encoded[root_offset..], &root);
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

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn isZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &gateway.zero_digest);
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

fn zeroBindings(bindings: []SettlementBindingV1) void {
    @memset(std.mem.sliceAsBytes(bindings), 0);
}

fn testDigest(seed: u8) Digest {
    var value: Digest = undefined;
    @memset(&value, seed);
    return value;
}

fn testRequest(request_key: u64) !gateway.RequestV1 {
    return gateway.makeRequestV1(
        0x4445_4d4f_4144_5054,
        0x4445_4d4f_4953_4f4c,
        request_key,
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
}

const TestEvidence = struct {
    config: gateway.ConfigV1,
    owner_request: gateway.RequestV1,
    events: [8]gateway.EventV2,
    receipt: gateway.AttemptReceiptV1,
    final_snapshot: gateway.SnapshotV2,
};

fn testEvidence() !TestEvidence {
    const config: gateway.ConfigV1 = .{
        .gateway_epoch = 0x4445_4d4f_4757_0001,
        .challenge = testDigest(0xa5),
        .limits = .{
            .max_reserved_tokens = 1_000,
            .max_reserved_tokens_per_isolation = 800,
            .max_request_tokens = 500,
            .max_followers_per_owner = 4,
        },
    };
    var owner_slots: [2]gateway.OwnerSlot = [_]gateway.OwnerSlot{.{}} ** 2;
    var follower_slots: [4]gateway.FollowerSlot =
        [_]gateway.FollowerSlot{.{}} ** 4;
    var instance: gateway.Gateway = .{};
    try instance.init(&owner_slots, &follower_slots, config);
    var events: [8]gateway.EventV2 = undefined;
    var count: usize = 0;

    const owner_request = try testRequest(1);
    const owner = try instance.admit(owner_request);
    events[count] = owner.event.?;
    count += 1;
    const follower = try instance.admit(try testRequest(2));
    events[count] = follower.event.?;
    count += 1;
    const cancelled = try instance.admit(try testRequest(3));
    events[count] = cancelled.event.?;
    count += 1;
    events[count] = try instance.cancel(cancelled.handle);
    count += 1;
    const dispatch = try instance.beginDispatch(owner.handle);
    events[count] = dispatch.event;
    count += 1;
    const settled = try instance.settleSuccess(
        dispatch.permit,
        try gateway.makeUsageV1(100, 20, 40, 8, 0, 80),
        testDigest(0x77),
    );
    events[count] = settled.event;
    count += 1;
    events[count] = try instance.acknowledge(follower.handle);
    count += 1;
    events[count] = try instance.acknowledge(owner.handle);
    count += 1;
    if (count != events.len) return error.UnexpectedEventCount;
    return .{
        .config = config,
        .owner_request = owner_request,
        .events = events,
        .receipt = settled.receipt,
        .final_snapshot = try instance.close(),
    };
}

test "gateway event wire replays complete closed lifecycle" {
    const evidence = try testEvidence();
    var settlement_bytes: [settlement_wire.encoded_bytes]u8 = undefined;
    const settlement = try settlement_wire.encodeV1(
        evidence.owner_request,
        evidence.receipt,
        &settlement_bytes,
    );
    const attachments = [_]AttachmentV1{.{
        .event_index = 5,
        .encoded_settlement = settlement,
    }};
    const expected_len = try encodedLenV1(
        evidence.events.len,
        attachments.len,
    );
    try std.testing.expectEqual(@as(usize, 5984), expected_len);
    var owners: [2]ReplayOwnerV1 = undefined;
    var consumers: [6]ReplayConsumerV1 = undefined;
    var bindings: [1]SettlementBindingV1 = undefined;
    var bytes: [6100]u8 = [_]u8{0xcc} ** 6100;
    const encoded = try encodeV1(
        flag_require_closed,
        evidence.config,
        owners.len,
        4,
        &evidence.events,
        &attachments,
        evidence.final_snapshot,
        &owners,
        &consumers,
        &bindings,
        &bytes,
    );
    try std.testing.expectEqual(expected_len, encoded.len);
    try std.testing.expect(std.mem.allEqual(u8, bytes[encoded.len..], 0xcc));
    var decoded_events: [8]gateway.EventV2 = undefined;
    const decoded = try decodeAndVerifyV1(
        encoded,
        &decoded_events,
        &owners,
        &consumers,
        &bindings,
    );
    try std.testing.expectEqualSlices(
        gateway.EventV2,
        &evidence.events,
        decoded.events,
    );
    try std.testing.expectEqual(evidence.final_snapshot, decoded.final_snapshot);
    try std.testing.expectEqual(@as(usize, 1), decoded.settlements.len);
    const root_hex = std.fmt.bytesToHex(decoded.envelope_sha256, .lower);
    try std.testing.expectEqualStrings(
        "a7e56cb9e4127f9ced08455424d009a27b0b541ea14f36999ef726d7afaed827",
        &root_hex,
    );
}

test "every serialized byte rejects after outer reseal" {
    const evidence = try testEvidence();
    var settlement_bytes: [settlement_wire.encoded_bytes]u8 = undefined;
    const attachments = [_]AttachmentV1{.{
        .event_index = 5,
        .encoded_settlement = try settlement_wire.encodeV1(
            evidence.owner_request,
            evidence.receipt,
            &settlement_bytes,
        ),
    }};
    var owners: [2]ReplayOwnerV1 = undefined;
    var consumers: [6]ReplayConsumerV1 = undefined;
    var bindings: [1]SettlementBindingV1 = undefined;
    var original: [5984]u8 = undefined;
    const encoded = try encodeV1(
        flag_require_closed,
        evidence.config,
        owners.len,
        4,
        &evidence.events,
        &attachments,
        evidence.final_snapshot,
        &owners,
        &consumers,
        &bindings,
        &original,
    );
    var mutated: [5984]u8 = undefined;
    var decoded_events: [8]gateway.EventV2 = undefined;
    for (0..encoded.len - digest_bytes) |index| {
        @memcpy(&mutated, encoded);
        mutated[index] ^= 1;
        resealForTest(&mutated);
        if (decodeAndVerifyV1(
            &mutated,
            &decoded_events,
            &owners,
            &consumers,
            &bindings,
        )) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "retry ambiguity and authoritative resolution require three settlements" {
    const config: gateway.ConfigV1 = .{
        .gateway_epoch = 0x4d55_4c54_495f_0001,
        .challenge = testDigest(0xb5),
        .limits = .{
            .max_reserved_tokens = 500,
            .max_reserved_tokens_per_isolation = 500,
            .max_request_tokens = 500,
            .max_followers_per_owner = 0,
        },
    };
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [0]gateway.FollowerSlot = .{};
    var instance: gateway.Gateway = .{};
    try instance.init(&owner_slots, &follower_slots, config);
    const request_value = try testRequest(91);
    var events: [7]gateway.EventV2 = undefined;
    var receipts: [3]gateway.AttemptReceiptV1 = undefined;
    var event_index: usize = 0;
    var receipt_index: usize = 0;

    const admission = try instance.admit(request_value);
    events[event_index] = admission.event.?;
    event_index += 1;
    const first_dispatch = try instance.beginDispatch(admission.handle);
    events[event_index] = first_dispatch.event;
    event_index += 1;
    const retry = try instance.retryNoCharge(
        first_dispatch.permit,
        try gateway.makeUsageV1(null, null, null, null, null, 0),
    );
    events[event_index] = retry.event;
    event_index += 1;
    receipts[receipt_index] = retry.receipt;
    receipt_index += 1;

    const second_dispatch = try instance.beginDispatch(admission.handle);
    events[event_index] = second_dispatch.event;
    event_index += 1;
    const ambiguous = try instance.markAmbiguous(
        second_dispatch.permit,
        try gateway.makeUsageV1(100, 5, 20, null, 3, null),
    );
    events[event_index] = ambiguous.event;
    event_index += 1;
    receipts[receipt_index] = ambiguous.receipt;
    receipt_index += 1;
    const resolved = try instance.resolveAmbiguousFailure(
        second_dispatch.permit,
        try gateway.makeUsageV1(100, 0, 20, 0, 3, 60),
    );
    events[event_index] = resolved.event;
    event_index += 1;
    receipts[receipt_index] = resolved.receipt;
    receipt_index += 1;
    events[event_index] = try instance.acknowledge(admission.handle);
    event_index += 1;
    if (event_index != events.len or receipt_index != receipts.len)
        return error.UnexpectedEvidenceCount;
    const final_snapshot = try instance.close();

    var settlement_bytes: [3][settlement_wire.encoded_bytes]u8 = undefined;
    const first_settlement = try settlement_wire.encodeV1(
        request_value,
        receipts[0],
        &settlement_bytes[0],
    );
    const second_settlement = try settlement_wire.encodeV1(
        request_value,
        receipts[1],
        &settlement_bytes[1],
    );
    const third_settlement = try settlement_wire.encodeV1(
        request_value,
        receipts[2],
        &settlement_bytes[2],
    );
    const attachments = [_]AttachmentV1{
        .{ .event_index = 2, .encoded_settlement = first_settlement },
        .{ .event_index = 4, .encoded_settlement = second_settlement },
        .{ .event_index = 5, .encoded_settlement = third_settlement },
    };
    var owners: [1]ReplayOwnerV1 = undefined;
    var consumers: [1]ReplayConsumerV1 = undefined;
    var bindings: [3]SettlementBindingV1 = undefined;
    var bytes: [6900]u8 = undefined;
    const encoded = try encodeV1(
        flag_require_closed,
        config,
        1,
        0,
        &events,
        &attachments,
        final_snapshot,
        &owners,
        &consumers,
        &bindings,
        &bytes,
    );
    try std.testing.expectEqual(@as(usize, 6814), encoded.len);
    var decoded_events: [7]gateway.EventV2 = undefined;
    const decoded = try decodeAndVerifyV1(
        encoded,
        &decoded_events,
        &owners,
        &consumers,
        &bindings,
    );
    try std.testing.expectEqual(@as(usize, 3), decoded.settlements.len);
    try std.testing.expectEqual(
        gateway.AttemptOutcome.retryable_no_charge,
        decoded.settlements[0].settlement.receipt.outcome,
    );
    try std.testing.expectEqual(
        gateway.AttemptOutcome.ambiguous,
        decoded.settlements[1].settlement.receipt.outcome,
    );
    try std.testing.expectEqual(
        gateway.AttemptOutcome.resolved_failure,
        decoded.settlements[2].settlement.receipt.outcome,
    );
}

test "drop reorder attachment substitution and open-final drift reject" {
    const evidence = try testEvidence();
    var settlement_bytes: [settlement_wire.encoded_bytes]u8 = undefined;
    const attachments = [_]AttachmentV1{.{
        .event_index = 5,
        .encoded_settlement = try settlement_wire.encodeV1(
            evidence.owner_request,
            evidence.receipt,
            &settlement_bytes,
        ),
    }};
    var owners: [2]ReplayOwnerV1 = undefined;
    var consumers: [6]ReplayConsumerV1 = undefined;
    var bindings: [1]SettlementBindingV1 = undefined;
    var output: [5984]u8 = undefined;

    try std.testing.expectError(
        Error.StateDrift,
        encodeV1(
            flag_require_closed,
            evidence.config,
            owners.len,
            4,
            evidence.events[0 .. evidence.events.len - 1],
            &attachments,
            evidence.final_snapshot,
            &owners,
            &consumers,
            &bindings,
            &output,
        ),
    );
    var reordered = evidence.events;
    std.mem.swap(gateway.EventV2, &reordered[1], &reordered[2]);
    try std.testing.expectError(
        Error.StateDrift,
        encodeV1(
            flag_require_closed,
            evidence.config,
            owners.len,
            4,
            &reordered,
            &attachments,
            evidence.final_snapshot,
            &owners,
            &consumers,
            &bindings,
            &output,
        ),
    );
    try std.testing.expectError(
        Error.InvalidEvidence,
        encodeV1(
            flag_require_closed,
            evidence.config,
            owners.len,
            4,
            &evidence.events,
            &.{},
            evidence.final_snapshot,
            &owners,
            &consumers,
            bindings[0..0],
            &output,
        ),
    );
    var wrong_attachment = attachments;
    wrong_attachment[0].event_index = 4;
    try std.testing.expectError(
        Error.InvalidEvidence,
        encodeV1(
            flag_require_closed,
            evidence.config,
            owners.len,
            4,
            &evidence.events,
            &wrong_attachment,
            evidence.final_snapshot,
            &owners,
            &consumers,
            &bindings,
            &output,
        ),
    );
    var open_snapshot = evidence.final_snapshot;
    open_snapshot.ledger.active_handles = 1;
    try std.testing.expectError(
        Error.StateDrift,
        encodeV1(
            flag_require_closed,
            evidence.config,
            owners.len,
            4,
            &evidence.events,
            &attachments,
            open_snapshot,
            &owners,
            &consumers,
            &bindings,
            &output,
        ),
    );
}

test "wire layout sizes remain explicit and padding independent" {
    try std.testing.expectEqual(@as(usize, 48), header_bytes);
    try std.testing.expectEqual(@as(usize, 28), limits_wire_bytes);
    try std.testing.expectEqual(@as(usize, 68), config_wire_bytes);
    try std.testing.expectEqual(@as(usize, 144), ledger_wire_bytes);
    try std.testing.expectEqual(@as(usize, 609), event_wire_bytes);
    try std.testing.expectEqual(@as(usize, 610), event_prefix_bytes);
    try std.testing.expectEqual(@as(usize, 236), snapshot_wire_bytes);
    try std.testing.expectEqual(@as(usize, 384), fixed_wire_bytes);
}
