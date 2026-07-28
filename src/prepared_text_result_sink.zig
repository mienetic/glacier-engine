//! Canonical replay-safe result acknowledgement for prepared-text delivery.
//!
//! This module deliberately separates the in-process publication callback from
//! durable delivery. `lane_publication_txn.SinkV1.commit` remains bounded and
//! I/O-free; callers apply the returned `CommitReceiptV1` to this state only
//! after `SessionV3.step` returns.

const std = @import("std");
const publication = @import("lane_publication_txn.zig");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const acknowledgement_abi: u64 = 0x4750_5253_0000_0001;
pub const acknowledgement_magic =
    [_]u8{ 'G', 'P', 'R', 'S', 'A', 'C', 'K', '1' };
pub const acknowledgement_bytes: usize = 424;
pub const acknowledgement_body_bytes: usize =
    acknowledgement_bytes - @sizeOf(Digest);
pub const allowed_flags: u64 = 0;

const delivery_key_domain =
    "glacier-prepared-text-result-delivery-key-v1\x00";
const commit_receipt_domain =
    "glacier-prepared-text-result-commit-receipt-v1\x00";
const sink_prefix_domain =
    "glacier-prepared-text-result-sink-prefix-v1\x00";
const acknowledgement_domain =
    "glacier-prepared-text-result-acknowledgement-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    CapacityExceeded,
    ConflictingDelivery,
    InvalidAcknowledgement,
    InvalidCommitReceipt,
    InvalidConfiguration,
    InvalidDelivery,
    RequestMismatch,
    SequenceExhausted,
    SequenceGap,
};

/// Semantic input projected from one already committed publication receipt.
/// The stable request identity is supplied by the prepared-text request
/// context because it is intentionally not part of the process-local receipt.
pub const DeliveryInputV1 = struct {
    request_sha256: Digest,
    request_epoch: u64,
    transaction_sequence: u64,
    token_id: u32,
    proposal_sha256: Digest,
    transition_sha256: Digest,
    commit_receipt_sha256: Digest,
};

/// One newly applied visible item. Replaying the exact delivery key and exact
/// content returns this byte-identical value without advancing the sink.
pub const ResultAcknowledgementV1 = struct {
    abi_version: u64 = acknowledgement_abi,
    flags: u64 = allowed_flags,
    request_epoch: u64,
    transaction_sequence: u64,
    token_id: u32,
    application_ordinal: u64,
    /// Each acknowledgement represents exactly one external application.
    /// Exact replay returns the original acknowledgement, so this stays one.
    application_count: u64 = 1,
    request_sha256: Digest,
    proposal_sha256: Digest,
    transition_sha256: Digest,
    commit_receipt_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    delivery_key_sha256: Digest,
    predecessor_acknowledgement_sha256: Digest,
    predecessor_sink_prefix_sha256: Digest,
    result_sink_prefix_sha256: Digest,
    acknowledgement_sha256: Digest,
};

pub const AcknowledgementV1 = ResultAcknowledgementV1;

pub const ApplyDispositionV1 = enum(u8) {
    applied,
    replayed,
};

pub const ApplyResultV1 = struct {
    disposition: ApplyDispositionV1,
    acknowledgement: ResultAcknowledgementV1,
};

/// Bounded in-memory semantic ledger. It owns no file descriptor and performs
/// no I/O, so it is safe to keep outside the publication callback boundary.
pub fn ResultSinkV1(comptime capacity: usize) type {
    if (capacity == 0)
        @compileError("prepared-text result sink capacity must be nonzero");
    return struct {
        const Self = @This();

        request_sha256: Digest,
        request_epoch: u64,
        initial_sequence: u64,
        next_sequence: u64,
        sink_implementation_sha256: Digest,
        sink_instance_sha256: Digest,
        acknowledgements: [capacity]ResultAcknowledgementV1 = undefined,
        applied_count: usize = 0,

        pub fn init(
            request_sha256: Digest,
            request_epoch: u64,
            initial_sequence: u64,
            sink_implementation_sha256: Digest,
            sink_instance_sha256: Digest,
        ) Error!Self {
            if (isZero(request_sha256) or request_epoch == 0 or
                isZero(sink_implementation_sha256) or
                isZero(sink_instance_sha256))
                return Error.InvalidConfiguration;
            return .{
                .request_sha256 = request_sha256,
                .request_epoch = request_epoch,
                .initial_sequence = initial_sequence,
                .next_sequence = initial_sequence,
                .sink_implementation_sha256 = sink_implementation_sha256,
                .sink_instance_sha256 = sink_instance_sha256,
            };
        }

        pub fn apply(
            self: *Self,
            input: DeliveryInputV1,
        ) Error!ApplyResultV1 {
            try validateDeliveryInputV1(input);
            if (!digestEqual(input.request_sha256, self.request_sha256) or
                input.request_epoch != self.request_epoch)
                return Error.RequestMismatch;

            const key = deliveryKeyRootV1(
                input.request_sha256,
                input.request_epoch,
                input.transaction_sequence,
            );
            for (self.acknowledgements[0..self.applied_count]) |existing| {
                if (!digestEqual(existing.delivery_key_sha256, key))
                    continue;
                if (deliveryMatchesAcknowledgementV1(
                    input,
                    self.sink_implementation_sha256,
                    self.sink_instance_sha256,
                    existing,
                )) {
                    return .{
                        .disposition = .replayed,
                        .acknowledgement = existing,
                    };
                }
                return Error.ConflictingDelivery;
            }

            if (input.transaction_sequence != self.next_sequence)
                return Error.SequenceGap;
            if (self.applied_count == capacity)
                return Error.CapacityExceeded;
            if (self.next_sequence == std.math.maxInt(u64))
                return Error.SequenceExhausted;

            const ordinal = std.math.add(
                u64,
                @as(u64, @intCast(self.applied_count)),
                1,
            ) catch return Error.ArithmeticOverflow;
            const predecessor_ack = if (self.applied_count == 0)
                zero_digest
            else
                self.acknowledgements[self.applied_count - 1]
                    .acknowledgement_sha256;
            const predecessor_prefix = if (self.applied_count == 0)
                zero_digest
            else
                self.acknowledgements[self.applied_count - 1]
                    .result_sink_prefix_sha256;
            var acknowledgement: ResultAcknowledgementV1 = .{
                .request_epoch = input.request_epoch,
                .transaction_sequence = input.transaction_sequence,
                .token_id = input.token_id,
                .application_ordinal = ordinal,
                .request_sha256 = input.request_sha256,
                .proposal_sha256 = input.proposal_sha256,
                .transition_sha256 = input.transition_sha256,
                .commit_receipt_sha256 = input.commit_receipt_sha256,
                .sink_implementation_sha256 = self.sink_implementation_sha256,
                .sink_instance_sha256 = self.sink_instance_sha256,
                .delivery_key_sha256 = key,
                .predecessor_acknowledgement_sha256 = predecessor_ack,
                .predecessor_sink_prefix_sha256 = predecessor_prefix,
                .result_sink_prefix_sha256 = undefined,
                .acknowledgement_sha256 = undefined,
            };
            acknowledgement.result_sink_prefix_sha256 =
                resultSinkPrefixRootV1(acknowledgement);
            acknowledgement.acknowledgement_sha256 =
                acknowledgementRootV1(acknowledgement);
            try validateAcknowledgementV1(acknowledgement);

            self.acknowledgements[self.applied_count] = acknowledgement;
            self.applied_count += 1;
            self.next_sequence += 1;
            return .{
                .disposition = .applied,
                .acknowledgement = acknowledgement,
            };
        }

        pub fn applyCommitReceipt(
            self: *Self,
            request_sha256: Digest,
            receipt: publication.CommitReceiptV1,
        ) Error!ApplyResultV1 {
            return self.apply(
                try deliveryInputFromCommitReceiptV1(
                    request_sha256,
                    receipt,
                ),
            );
        }

        pub fn acknowledgementSlice(
            self: *const Self,
        ) []const ResultAcknowledgementV1 {
            return self.acknowledgements[0..self.applied_count];
        }

        pub fn resultSinkPrefix(self: *const Self) Digest {
            return if (self.applied_count == 0)
                zero_digest
            else
                self.acknowledgements[self.applied_count - 1]
                    .result_sink_prefix_sha256;
        }

        pub fn lastAcknowledgementRoot(self: *const Self) Digest {
            return if (self.applied_count == 0)
                zero_digest
            else
                self.acknowledgements[self.applied_count - 1]
                    .acknowledgement_sha256;
        }
    };
}

pub fn deliveryInputFromCommitReceiptV1(
    request_sha256: Digest,
    receipt: publication.CommitReceiptV1,
) Error!DeliveryInputV1 {
    if (isZero(request_sha256) or
        !publication.commitReceiptValidV1(receipt))
        return Error.InvalidCommitReceipt;
    const value: DeliveryInputV1 = .{
        .request_sha256 = request_sha256,
        .request_epoch = receipt.proposal.request_epoch,
        .transaction_sequence = receipt.proposal.transaction_sequence,
        .token_id = receipt.proposal.transition.token_id,
        .proposal_sha256 = receipt.proposal_sha256,
        .transition_sha256 = receipt.proposal.transition_sha256,
        .commit_receipt_sha256 = commitReceiptRootV1(receipt),
    };
    try validateDeliveryInputV1(value);
    return value;
}

pub fn validateDeliveryInputV1(input: DeliveryInputV1) Error!void {
    if (isZero(input.request_sha256) or input.request_epoch == 0 or
        isZero(input.proposal_sha256) or
        isZero(input.transition_sha256) or
        isZero(input.commit_receipt_sha256))
        return Error.InvalidDelivery;
}

pub fn encodeAcknowledgementV1(
    value: ResultAcknowledgementV1,
    destination: []u8,
) Error![]const u8 {
    try validateAcknowledgementV1(value);
    if (destination.len < acknowledgement_bytes)
        return Error.BufferTooSmall;
    encodeAcknowledgementBodyUncheckedV1(
        value,
        destination[0..acknowledgement_body_bytes],
    );
    @memcpy(
        destination[acknowledgement_body_bytes..acknowledgement_bytes],
        &value.acknowledgement_sha256,
    );
    return destination[0..acknowledgement_bytes];
}

pub fn decodeAcknowledgementV1(
    encoded: []const u8,
) Error!ResultAcknowledgementV1 {
    if (encoded.len != acknowledgement_bytes or
        !std.mem.eql(
            u8,
            encoded[0..acknowledgement_magic.len],
            &acknowledgement_magic,
        ) or
        readU64(encoded, 8) != acknowledgement_abi or
        readU64(encoded, 16) != acknowledgement_bytes or
        readU64(encoded, 24) != allowed_flags)
        return Error.InvalidAcknowledgement;
    const token_id = std.math.cast(u32, readU64(encoded, 48)) orelse
        return Error.InvalidAcknowledgement;
    const value: ResultAcknowledgementV1 = .{
        .abi_version = readU64(encoded, 8),
        .flags = readU64(encoded, 24),
        .request_epoch = readU64(encoded, 32),
        .transaction_sequence = readU64(encoded, 40),
        .token_id = token_id,
        .application_ordinal = readU64(encoded, 56),
        .application_count = readU64(encoded, 64),
        .request_sha256 = encoded[72..104].*,
        .proposal_sha256 = encoded[104..136].*,
        .transition_sha256 = encoded[136..168].*,
        .commit_receipt_sha256 = encoded[168..200].*,
        .sink_implementation_sha256 = encoded[200..232].*,
        .sink_instance_sha256 = encoded[232..264].*,
        .delivery_key_sha256 = encoded[264..296].*,
        .predecessor_acknowledgement_sha256 = encoded[296..328].*,
        .predecessor_sink_prefix_sha256 = encoded[328..360].*,
        .result_sink_prefix_sha256 = encoded[360..392].*,
        .acknowledgement_sha256 = encoded[392..424].*,
    };
    try validateAcknowledgementV1(value);
    return value;
}

pub fn validateAcknowledgementV1(
    value: ResultAcknowledgementV1,
) Error!void {
    if (value.abi_version != acknowledgement_abi or
        value.flags != allowed_flags or value.request_epoch == 0 or
        value.application_ordinal == 0 or
        value.application_count != 1 or
        isZero(value.request_sha256) or
        isZero(value.proposal_sha256) or
        isZero(value.transition_sha256) or
        isZero(value.commit_receipt_sha256) or
        isZero(value.sink_implementation_sha256) or
        isZero(value.sink_instance_sha256) or
        isZero(value.delivery_key_sha256) or
        isZero(value.result_sink_prefix_sha256) or
        isZero(value.acknowledgement_sha256))
        return Error.InvalidAcknowledgement;
    if ((value.application_ordinal == 1 and
        (!isZero(value.predecessor_acknowledgement_sha256) or
            !isZero(value.predecessor_sink_prefix_sha256))) or
        (value.application_ordinal > 1 and
            (isZero(value.predecessor_acknowledgement_sha256) or
                isZero(value.predecessor_sink_prefix_sha256))))
        return Error.InvalidAcknowledgement;
    if (!digestEqual(
        value.delivery_key_sha256,
        deliveryKeyRootV1(
            value.request_sha256,
            value.request_epoch,
            value.transaction_sequence,
        ),
    ) or !digestEqual(
        value.result_sink_prefix_sha256,
        resultSinkPrefixRootV1(value),
    ) or !digestEqual(
        value.acknowledgement_sha256,
        acknowledgementRootV1(value),
    ))
        return Error.InvalidAcknowledgement;
}

pub fn deliveryKeyRootV1(
    request_sha256: Digest,
    request_epoch: u64,
    transaction_sequence: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(delivery_key_domain);
    hashU64(&hash, acknowledgement_abi);
    hash.update(&request_sha256);
    hashU64(&hash, request_epoch);
    hashU64(&hash, transaction_sequence);
    return finish(&hash);
}

pub fn commitReceiptRootV1(
    receipt: publication.CommitReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(commit_receipt_domain);
    hashU64(&hash, receipt.abi_version);
    hash.update(&receipt.proposal_sha256);
    hashU64(&hash, receipt.prepare_ack.abi_version);
    hash.update(&receipt.prepare_ack.proposal_sha256);
    hashU64(&hash, receipt.prepare_ack.sink_epoch);
    hashU64(&hash, receipt.prepare_ack.reservation_id);
    hash.update(&receipt.service_event_sha256);
    hash.update(&receipt.transcript_sha256);
    return finish(&hash);
}

pub fn resultSinkPrefixRootV1(
    value: ResultAcknowledgementV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(sink_prefix_domain);
    hashU64(&hash, acknowledgement_abi);
    hashU64(&hash, value.request_epoch);
    hashU64(&hash, value.transaction_sequence);
    hashU64(&hash, value.token_id);
    hashU64(&hash, value.application_ordinal);
    hashU64(&hash, value.application_count);
    hash.update(&value.request_sha256);
    hash.update(&value.proposal_sha256);
    hash.update(&value.transition_sha256);
    hash.update(&value.commit_receipt_sha256);
    hash.update(&value.sink_implementation_sha256);
    hash.update(&value.sink_instance_sha256);
    hash.update(&value.delivery_key_sha256);
    hash.update(&value.predecessor_acknowledgement_sha256);
    hash.update(&value.predecessor_sink_prefix_sha256);
    return finish(&hash);
}

pub fn acknowledgementRootV1(
    value: ResultAcknowledgementV1,
) Digest {
    var body: [acknowledgement_body_bytes]u8 = undefined;
    encodeAcknowledgementBodyUncheckedV1(value, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(acknowledgement_domain);
    hash.update(&body);
    return finish(&hash);
}

fn deliveryMatchesAcknowledgementV1(
    input: DeliveryInputV1,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    acknowledgement: ResultAcknowledgementV1,
) bool {
    return input.request_epoch == acknowledgement.request_epoch and
        input.transaction_sequence ==
            acknowledgement.transaction_sequence and
        input.token_id == acknowledgement.token_id and
        digestEqual(input.request_sha256, acknowledgement.request_sha256) and
        digestEqual(input.proposal_sha256, acknowledgement.proposal_sha256) and
        digestEqual(
            input.transition_sha256,
            acknowledgement.transition_sha256,
        ) and digestEqual(
        input.commit_receipt_sha256,
        acknowledgement.commit_receipt_sha256,
    ) and digestEqual(
        sink_implementation_sha256,
        acknowledgement.sink_implementation_sha256,
    ) and digestEqual(
        sink_instance_sha256,
        acknowledgement.sink_instance_sha256,
    );
}

fn encodeAcknowledgementBodyUncheckedV1(
    value: ResultAcknowledgementV1,
    destination: []u8,
) void {
    std.debug.assert(destination.len == acknowledgement_body_bytes);
    @memset(destination, 0);
    @memcpy(destination[0..8], &acknowledgement_magic);
    writeU64(destination, 8, value.abi_version);
    writeU64(destination, 16, acknowledgement_bytes);
    writeU64(destination, 24, value.flags);
    writeU64(destination, 32, value.request_epoch);
    writeU64(destination, 40, value.transaction_sequence);
    writeU64(destination, 48, value.token_id);
    writeU64(destination, 56, value.application_ordinal);
    writeU64(destination, 64, value.application_count);
    @memcpy(destination[72..104], &value.request_sha256);
    @memcpy(destination[104..136], &value.proposal_sha256);
    @memcpy(destination[136..168], &value.transition_sha256);
    @memcpy(destination[168..200], &value.commit_receipt_sha256);
    @memcpy(
        destination[200..232],
        &value.sink_implementation_sha256,
    );
    @memcpy(destination[232..264], &value.sink_instance_sha256);
    @memcpy(destination[264..296], &value.delivery_key_sha256);
    @memcpy(
        destination[296..328],
        &value.predecessor_acknowledgement_sha256,
    );
    @memcpy(
        destination[328..360],
        &value.predecessor_sink_prefix_sha256,
    );
    @memcpy(destination[360..392], &value.result_sink_prefix_sha256);
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    @memcpy(output[offset .. offset + 8], &encoded);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var output: Digest = undefined;
    hash.final(&output);
    return output;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn testDigest(label: []const u8) Digest {
    var output: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(label, &output, .{});
    return output;
}

fn testInput(
    request_sha256: Digest,
    request_epoch: u64,
    sequence: u64,
    token_id: u32,
    label: []const u8,
) DeliveryInputV1 {
    var proposal_label: [96]u8 = undefined;
    const proposal = std.fmt.bufPrint(
        &proposal_label,
        "proposal:{s}:{d}",
        .{ label, sequence },
    ) catch unreachable;
    var transition_label: [96]u8 = undefined;
    const transition = std.fmt.bufPrint(
        &transition_label,
        "transition:{s}:{d}",
        .{ label, sequence },
    ) catch unreachable;
    var receipt_label: [96]u8 = undefined;
    const receipt = std.fmt.bufPrint(
        &receipt_label,
        "receipt:{s}:{d}",
        .{ label, sequence },
    ) catch unreachable;
    return .{
        .request_sha256 = request_sha256,
        .request_epoch = request_epoch,
        .transaction_sequence = sequence,
        .token_id = token_id,
        .proposal_sha256 = testDigest(proposal),
        .transition_sha256 = testDigest(transition),
        .commit_receipt_sha256 = testDigest(receipt),
    };
}

test "result acknowledgement wire is canonical and mutation complete" {
    const request = testDigest("request");
    var sink = try ResultSinkV1(3).init(
        request,
        71,
        9,
        testDigest("sink implementation"),
        testDigest("sink instance"),
    );
    const applied = try sink.apply(
        testInput(request, 71, 9, 42, "first"),
    );
    try std.testing.expectEqual(
        ApplyDispositionV1.applied,
        applied.disposition,
    );
    var encoded: [acknowledgement_bytes]u8 = undefined;
    const wire = try encodeAcknowledgementV1(
        applied.acknowledgement,
        &encoded,
    );
    try std.testing.expectEqual(
        applied.acknowledgement,
        try decodeAcknowledgementV1(wire),
    );
    const delivery_key_hex = std.fmt.bytesToHex(
        applied.acknowledgement.delivery_key_sha256,
        .lower,
    );
    const result_prefix_hex = std.fmt.bytesToHex(
        applied.acknowledgement.result_sink_prefix_sha256,
        .lower,
    );
    const acknowledgement_hex = std.fmt.bytesToHex(
        applied.acknowledgement.acknowledgement_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "e3187fb40ed3f4e98fbb453b7ae7a3b1fa006f45fe6de12d0bd18be8fc488821",
        &delivery_key_hex,
    );
    try std.testing.expectEqualStrings(
        "64933c85cb744c5213a143ad7e2bbf0de1e1a958ddd4b0c39ae3131e142bd49f",
        &result_prefix_hex,
    );
    try std.testing.expectEqualStrings(
        "d377155aaa28cf6027ebf1751fa8f73540f66bc366c6b8efbfc6ea8285396c48",
        &acknowledgement_hex,
    );

    var corrupted = encoded;
    for (0..corrupted.len) |index| {
        corrupted = encoded;
        corrupted[index] ^= 1;
        const accepted = if (decodeAcknowledgementV1(
            &corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }

    var forged = applied.acknowledgement;
    forged.flags = 1;
    forged.acknowledgement_sha256 =
        acknowledgementRootV1(forged);
    try std.testing.expectError(
        Error.InvalidAcknowledgement,
        validateAcknowledgementV1(forged),
    );
}

test "sink replay is byte-identical and does not apply twice" {
    const request = testDigest("request replay");
    var sink = try ResultSinkV1(3).init(
        request,
        91,
        4,
        testDigest("implementation replay"),
        testDigest("instance replay"),
    );
    const input = testInput(request, 91, 4, 17, "replay");
    const first = try sink.apply(input);
    const replay = try sink.apply(input);
    try std.testing.expectEqual(
        ApplyDispositionV1.replayed,
        replay.disposition,
    );
    try std.testing.expectEqual(
        first.acknowledgement,
        replay.acknowledgement,
    );
    try std.testing.expectEqual(@as(usize, 1), sink.applied_count);
    try std.testing.expectEqual(@as(u64, 5), sink.next_sequence);
}

test "sink rejects conflicting delivery and sequence gaps" {
    const request = testDigest("request conflicts");
    var sink = try ResultSinkV1(3).init(
        request,
        101,
        12,
        testDigest("implementation conflicts"),
        testDigest("instance conflicts"),
    );
    const first_input = testInput(
        request,
        101,
        12,
        31,
        "conflict",
    );
    _ = try sink.apply(first_input);

    var token_conflict = first_input;
    token_conflict.token_id += 1;
    try std.testing.expectError(
        Error.ConflictingDelivery,
        sink.apply(token_conflict),
    );
    var proposal_conflict = first_input;
    proposal_conflict.proposal_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.ConflictingDelivery,
        sink.apply(proposal_conflict),
    );
    var transition_conflict = first_input;
    transition_conflict.transition_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.ConflictingDelivery,
        sink.apply(transition_conflict),
    );
    var receipt_conflict = first_input;
    receipt_conflict.commit_receipt_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.ConflictingDelivery,
        sink.apply(receipt_conflict),
    );
    try std.testing.expectError(
        Error.SequenceGap,
        sink.apply(testInput(request, 101, 14, 33, "gap")),
    );
    try std.testing.expectEqual(@as(usize, 1), sink.applied_count);
}

test "sink chains exact contiguous acknowledgements" {
    const request = testDigest("request chain");
    var sink = try ResultSinkV1(3).init(
        request,
        111,
        20,
        testDigest("implementation chain"),
        testDigest("instance chain"),
    );
    const first = try sink.apply(
        testInput(request, 111, 20, 51, "first chain"),
    );
    const second = try sink.apply(
        testInput(request, 111, 21, 52, "second chain"),
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        second.acknowledgement.application_ordinal,
    );
    try std.testing.expectEqualSlices(
        u8,
        &first.acknowledgement.acknowledgement_sha256,
        &second.acknowledgement
            .predecessor_acknowledgement_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &first.acknowledgement.result_sink_prefix_sha256,
        &second.acknowledgement.predecessor_sink_prefix_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &second.acknowledgement.result_sink_prefix_sha256,
        &sink.resultSinkPrefix(),
    );
    try std.testing.expectEqual(@as(usize, 2), sink.applied_count);
}
