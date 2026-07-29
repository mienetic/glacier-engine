//! Pure committed-output reconciliation for durable prepared text.
//!
//! The caller first verifies one selected checkpoint and one selected result
//! ledger through their format-specific decoders. This module then admits only
//! an aligned pair or a result sink that is exactly one acknowledgement ahead
//! of the checkpoint. It performs no allocation or I/O and grants no storage,
//! execution, publication, or recovery authority.
//!
//! The retained tokenizer profile maps each output token in `[0, 255]` to the
//! byte with the same value. Model output is therefore lossless as bytes but is
//! not necessarily valid UTF-8. Text is a derived view only when strict UTF-8
//! validation succeeds.

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const result_sink = @import("prepared_text_result_sink.zig");
const sink_file = @import("prepared_text_result_sink_file.zig");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const view_abi: u64 = 0x4750_434f_0000_0001;
pub const maximum_visible_tokens: usize = 16 * 1024;
pub const committed_output_view_abi = view_abi;
pub const maximum_visible_output_tokens = maximum_visible_tokens;

pub const token_domain =
    "glacier-prepared-text-committed-output-token-v1\x00";
pub const bytes_domain =
    "glacier-prepared-text-committed-output-bytes-v1\x00";
pub const view_domain =
    "glacier-prepared-text-committed-output-view-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidAcknowledgement,
    InvalidAlignment,
    InvalidCheckpoint,
    InvalidContext,
    InvalidSinkSelection,
    InvalidToken,
    OutputTooLarge,
    UnsafeDestination,
};

/// Contextually verified portable input and tokenizer identities. These roots
/// bind the view to its already-decoded package lineage without exposing model
/// bytes, the raw prompt, license bytes, or output.
pub const ContextV1 = struct {
    package_sha256: Digest,
    representation_sha256: Digest,
    input_archive_sha256: Digest,
    tokenizer_manifest: tokenizer.Utf8ByteManifestV1,
    local_plan_sha256: Digest,
};

/// Complete output prefix admitted by the prepared-text progress decoder.
///
/// `canonical_output_u32_le` contains exactly `next_sequence` little-endian
/// u32 token IDs. `context` is the contextual binding admitted with that
/// progress selection, rather than a claim that these roots are fields in the
/// checkpoint header itself.
pub const VerifiedCheckpointOutputV1 = struct {
    context: ContextV1,
    generation: u64,
    terminal: bool,
    request_epoch: u64,
    next_sequence: u64,
    sink_initial_sequence: u64,
    canonical_output_u32_le: []const u8,
    request_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    head_acknowledgement_sha256: Digest,
    result_sink_prefix_sha256: Digest,
    selector_sha256: Digest,
    selected_set_sha256: Digest,
    state_sha256: Digest,
};

/// One caller-decoded selector and its complete immutable ledger.
pub const DecodedSinkSelectionV1 = struct {
    selector: sink_file.DecodedSelectorV1,
    ledger: sink_file.DecodedLedgerV1,
};

pub const SequenceStateV1 = enum(u64) {
    aligned = 1,
    sink_exactly_one_ahead = 2,

    pub fn label(self: SequenceStateV1) []const u8 {
        return switch (self) {
            .aligned => "aligned",
            .sink_exactly_one_ahead => "sink-exactly-one-ahead",
        };
    }
};

pub const VisibilityStateV1 = SequenceStateV1;

/// Exact read-only view returned after reconciliation. `visible_bytes` borrows
/// caller-provided output storage. Each byte is also the corresponding token
/// ID under the retained tokenizer profile.
pub const ViewV1 = struct {
    abi_version: u64 = view_abi,
    sequence_state: SequenceStateV1,
    terminal: bool,
    checkpoint_pending: bool,
    generation: u64,
    request_epoch: u64,
    checkpoint_next_sequence: u64,
    sink_initial_sequence: u64,
    visible_next_sequence: u64,
    acknowledgement_count: usize,
    token_count: usize,
    request_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    head_acknowledgement_sha256: Digest,
    result_sink_prefix_sha256: Digest,
    visible_bytes: []const u8,
    visible_tokens_sha256: Digest,
    visible_bytes_sha256: Digest,
    view_sha256: Digest,
    utf8_valid: bool,
    package_sha256: Digest,
    representation_sha256: Digest,
    input_archive_sha256: Digest,
    tokenizer_domain_sha256: Digest,
    tokenizer_behavior_sha256: Digest,
    tokenizer_config_sha256: Digest,
    local_plan_sha256: Digest,
    checkpoint_selector_sha256: Digest,
    checkpoint_set_sha256: Digest,
    checkpoint_state_sha256: Digest,
    sink_selector_sha256: Digest,
    sink_ledger_sha256: Digest,

    pub fn visibleToken(self: ViewV1, index: usize) Error!u32 {
        if (index >= self.visible_bytes.len)
            return Error.InvalidToken;
        return self.visible_bytes[index];
    }
};

pub const ViewRootInputV1 = struct {
    sequence_state: SequenceStateV1,
    terminal: bool,
    generation: u64,
    request_epoch: u64,
    sink_initial_sequence: u64,
    checkpoint_next_sequence: u64,
    visible_next_sequence: u64,
    acknowledgement_count: usize,
    visible_token_count: usize,
    package_sha256: Digest,
    representation_sha256: Digest,
    input_archive_sha256: Digest,
    tokenizer_domain_sha256: Digest,
    tokenizer_behavior_sha256: Digest,
    tokenizer_config_sha256: Digest,
    local_plan_sha256: Digest,
    request_sha256: Digest,
    checkpoint_selector_sha256: Digest,
    checkpoint_set_sha256: Digest,
    checkpoint_state_sha256: Digest,
    sink_selector_sha256: Digest,
    sink_ledger_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    head_acknowledgement_sha256: Digest,
    result_sink_prefix_sha256: Digest,
    visible_tokens_sha256: Digest,
    visible_bytes_sha256: Digest,
};

pub const CheckpointV1 = VerifiedCheckpointOutputV1;
pub const SinkSelectionV1 = DecodedSinkSelectionV1;

/// Join one caller-verified checkpoint prefix to one decoded sink selection.
/// The destination is not modified on failure and may not overlap either
/// borrowed wire.
pub fn reconcileV1(
    context: ContextV1,
    checkpoint: VerifiedCheckpointOutputV1,
    sink: DecodedSinkSelectionV1,
    visible_storage: []u8,
) Error!ViewV1 {
    try validateContextV1(context);
    if (!std.meta.eql(context, checkpoint.context))
        return Error.InvalidContext;
    try validateCheckpointScalarsV1(checkpoint);
    sink_file.validateSelectedPairV1(
        sink.selector,
        sink.ledger,
    ) catch return Error.InvalidSinkSelection;

    const ledger = sink.ledger;
    const selector = sink.selector;
    if (selector.request_epoch != checkpoint.request_epoch or
        selector.initial_sequence != checkpoint.sink_initial_sequence or
        !digestEqual(selector.request_sha256, checkpoint.request_sha256) or
        !digestEqual(
            selector.sink_implementation_sha256,
            checkpoint.sink_implementation_sha256,
        ) or !digestEqual(
        selector.sink_instance_sha256,
        checkpoint.sink_instance_sha256,
    ))
        return Error.InvalidContext;

    if (selector.initial_sequence > checkpoint.next_sequence or
        selector.next_sequence < checkpoint.next_sequence)
        return Error.InvalidAlignment;
    const maximum_next = std.math.add(
        u64,
        checkpoint.next_sequence,
        1,
    ) catch return Error.InvalidAlignment;
    if (selector.next_sequence > maximum_next)
        return Error.InvalidAlignment;

    const checkpoint_count = std.math.cast(
        usize,
        checkpoint.next_sequence,
    ) orelse return Error.OutputTooLarge;
    const visible_count = std.math.cast(
        usize,
        selector.next_sequence,
    ) orelse return Error.OutputTooLarge;
    if (checkpoint_count > maximum_visible_tokens or
        visible_count > maximum_visible_tokens)
        return Error.OutputTooLarge;
    if (visible_storage.len < visible_count)
        return Error.BufferTooSmall;
    if (slicesOverlap(
        visible_storage[0..visible_count],
        checkpoint.canonical_output_u32_le,
    ) or slicesOverlap(
        visible_storage[0..visible_count],
        ledger.encoded,
    ))
        return Error.UnsafeDestination;

    const checkpoint_head_zero =
        digestIsZero(checkpoint.head_acknowledgement_sha256);
    if (checkpoint_head_zero !=
        digestIsZero(checkpoint.result_sink_prefix_sha256))
        return Error.InvalidAcknowledgement;
    const checkpoint_ack_count_u64 = checkpoint.next_sequence -
        selector.initial_sequence;
    const checkpoint_ack_count = std.math.cast(
        usize,
        checkpoint_ack_count_u64,
    ) orelse return Error.OutputTooLarge;
    if ((checkpoint_ack_count == 0) != checkpoint_head_zero)
        return Error.InvalidAcknowledgement;
    if (checkpoint.terminal and checkpoint_ack_count == 0)
        return Error.InvalidCheckpoint;

    var previous_ack = zero_digest;
    var previous_prefix = zero_digest;
    for (0..ledger.acknowledgement_count) |index| {
        const acknowledgement = ledger.acknowledgement(index) catch
            return Error.InvalidAcknowledgement;
        result_sink.validateAcknowledgementV1(acknowledgement) catch
            return Error.InvalidAcknowledgement;
        const expected_sequence = std.math.add(
            u64,
            selector.initial_sequence,
            @as(u64, @intCast(index)),
        ) catch return Error.InvalidAcknowledgement;
        if (acknowledgement.request_epoch != checkpoint.request_epoch or
            acknowledgement.transaction_sequence != expected_sequence or
            acknowledgement.application_ordinal != index + 1 or
            acknowledgement.application_count != 1 or
            acknowledgement.token_id > std.math.maxInt(u8) or
            !digestEqual(
                acknowledgement.request_sha256,
                checkpoint.request_sha256,
            ) or !digestEqual(
            acknowledgement.sink_implementation_sha256,
            checkpoint.sink_implementation_sha256,
        ) or !digestEqual(
            acknowledgement.sink_instance_sha256,
            checkpoint.sink_instance_sha256,
        ) or !digestEqual(
            acknowledgement.predecessor_acknowledgement_sha256,
            previous_ack,
        ) or !digestEqual(
            acknowledgement.predecessor_sink_prefix_sha256,
            previous_prefix,
        ))
            return Error.InvalidAcknowledgement;
        if (expected_sequence < checkpoint.next_sequence) {
            if (acknowledgement.token_id !=
                checkpointTokenV1(checkpoint, expected_sequence))
                return Error.InvalidAcknowledgement;
        } else if (expected_sequence > checkpoint.next_sequence) {
            return Error.InvalidAlignment;
        }
        previous_ack = acknowledgement.acknowledgement_sha256;
        previous_prefix = acknowledgement.result_sink_prefix_sha256;
    }
    if (!digestEqual(
        previous_ack,
        ledger.last_acknowledgement_sha256,
    ) or !digestEqual(
        previous_prefix,
        ledger.result_sink_prefix_sha256,
    ))
        return Error.InvalidAcknowledgement;

    if (checkpoint_ack_count > 0) {
        if (checkpoint_ack_count > ledger.acknowledgement_count)
            return Error.InvalidAlignment;
        const checkpoint_head = ledger.acknowledgement(
            checkpoint_ack_count - 1,
        ) catch return Error.InvalidAcknowledgement;
        if (!digestEqual(
            checkpoint_head.acknowledgement_sha256,
            checkpoint.head_acknowledgement_sha256,
        ) or !digestEqual(
            checkpoint_head.result_sink_prefix_sha256,
            checkpoint.result_sink_prefix_sha256,
        ))
            return Error.InvalidAcknowledgement;
    }

    const state: SequenceStateV1 =
        if (selector.next_sequence == checkpoint.next_sequence)
            .aligned
        else
            .sink_exactly_one_ahead;
    var pending_token: ?u8 = null;
    switch (state) {
        .aligned => {
            if (!digestEqual(
                ledger.last_acknowledgement_sha256,
                checkpoint.head_acknowledgement_sha256,
            ) or !digestEqual(
                ledger.result_sink_prefix_sha256,
                checkpoint.result_sink_prefix_sha256,
            ))
                return Error.InvalidAcknowledgement;
        },
        .sink_exactly_one_ahead => {
            if (checkpoint.terminal or
                ledger.acknowledgement_count == 0)
                return Error.InvalidAlignment;
            const acknowledgement = ledger.acknowledgement(
                ledger.acknowledgement_count - 1,
            ) catch return Error.InvalidAcknowledgement;
            if (acknowledgement.transaction_sequence !=
                checkpoint.next_sequence or
                !digestEqual(
                    acknowledgement
                        .predecessor_acknowledgement_sha256,
                    checkpoint.head_acknowledgement_sha256,
                ) or !digestEqual(
                acknowledgement.predecessor_sink_prefix_sha256,
                checkpoint.result_sink_prefix_sha256,
            ))
                return Error.InvalidAcknowledgement;
            pending_token = @intCast(acknowledgement.token_id);
        },
    }

    // All token-domain rejection checks precede the first destination write.
    for (0..checkpoint_count) |index| {
        if (checkpointTokenAtIndexV1(checkpoint, index) >
            std.math.maxInt(u8))
            return Error.InvalidToken;
    }

    // All rejection checks now precede the first destination write.
    for (0..checkpoint_count) |index| {
        const token = checkpointTokenAtIndexV1(checkpoint, index);
        visible_storage[index] = @intCast(token);
    }
    if (pending_token) |token|
        visible_storage[checkpoint_count] = token;
    const visible = visible_storage[0..visible_count];

    const token_root = visibleTokensRootV1(visible);
    const byte_root = visibleBytesRootV1(visible);
    const view_root = viewRootV1(.{
        .sequence_state = state,
        .terminal = checkpoint.terminal,
        .generation = checkpoint.generation,
        .request_epoch = checkpoint.request_epoch,
        .sink_initial_sequence = selector.initial_sequence,
        .checkpoint_next_sequence = checkpoint.next_sequence,
        .visible_next_sequence = selector.next_sequence,
        .acknowledgement_count = ledger.acknowledgement_count,
        .visible_token_count = visible.len,
        .package_sha256 = context.package_sha256,
        .representation_sha256 = context.representation_sha256,
        .input_archive_sha256 = context.input_archive_sha256,
        .tokenizer_domain_sha256 = context.tokenizer_manifest.domain_sha256,
        .tokenizer_behavior_sha256 = context.tokenizer_manifest.behavior_sha256,
        .tokenizer_config_sha256 = context.tokenizer_manifest.config_sha256,
        .local_plan_sha256 = context.local_plan_sha256,
        .request_sha256 = checkpoint.request_sha256,
        .checkpoint_selector_sha256 = checkpoint.selector_sha256,
        .checkpoint_set_sha256 = checkpoint.selected_set_sha256,
        .checkpoint_state_sha256 = checkpoint.state_sha256,
        .sink_selector_sha256 = selector.selector_sha256,
        .sink_ledger_sha256 = ledger.ledger_sha256,
        .sink_implementation_sha256 = checkpoint.sink_implementation_sha256,
        .sink_instance_sha256 = checkpoint.sink_instance_sha256,
        .head_acknowledgement_sha256 = ledger.last_acknowledgement_sha256,
        .result_sink_prefix_sha256 = ledger.result_sink_prefix_sha256,
        .visible_tokens_sha256 = token_root,
        .visible_bytes_sha256 = byte_root,
    });
    return .{
        .sequence_state = state,
        .terminal = checkpoint.terminal,
        .checkpoint_pending = state == .sink_exactly_one_ahead,
        .generation = checkpoint.generation,
        .request_epoch = checkpoint.request_epoch,
        .checkpoint_next_sequence = checkpoint.next_sequence,
        .sink_initial_sequence = selector.initial_sequence,
        .visible_next_sequence = selector.next_sequence,
        .acknowledgement_count = ledger.acknowledgement_count,
        .token_count = visible.len,
        .request_sha256 = checkpoint.request_sha256,
        .sink_implementation_sha256 = checkpoint.sink_implementation_sha256,
        .sink_instance_sha256 = checkpoint.sink_instance_sha256,
        .head_acknowledgement_sha256 = ledger.last_acknowledgement_sha256,
        .result_sink_prefix_sha256 = ledger.result_sink_prefix_sha256,
        .visible_bytes = visible,
        .visible_tokens_sha256 = token_root,
        .visible_bytes_sha256 = byte_root,
        .view_sha256 = view_root,
        .utf8_valid = std.unicode.utf8ValidateSlice(visible),
        .package_sha256 = context.package_sha256,
        .representation_sha256 = context.representation_sha256,
        .input_archive_sha256 = context.input_archive_sha256,
        .tokenizer_domain_sha256 = context.tokenizer_manifest.domain_sha256,
        .tokenizer_behavior_sha256 = context.tokenizer_manifest.behavior_sha256,
        .tokenizer_config_sha256 = context.tokenizer_manifest.config_sha256,
        .local_plan_sha256 = context.local_plan_sha256,
        .checkpoint_selector_sha256 = checkpoint.selector_sha256,
        .checkpoint_set_sha256 = checkpoint.selected_set_sha256,
        .checkpoint_state_sha256 = checkpoint.state_sha256,
        .sink_selector_sha256 = selector.selector_sha256,
        .sink_ledger_sha256 = ledger.ledger_sha256,
    };
}

pub fn visibleTokensRootV1(visible_tokens: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(token_domain);
    hashU64(&hash, @as(u64, @intCast(visible_tokens.len)));
    for (visible_tokens) |token| hashU32(&hash, token);
    return finish(&hash);
}

pub fn visibleBytesRootV1(visible_bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes_domain);
    hashU64(&hash, @as(u64, @intCast(visible_bytes.len)));
    hash.update(visible_bytes);
    return finish(&hash);
}

/// Canonical oracle-compatible root over the complete reported durable view.
///
/// The v1 preimage is `view_domain`, followed by these little-endian u64
/// values in order: ABI, sequence state, terminal (0/1), checkpoint
/// generation, request epoch, sink initial sequence, checkpoint next
/// sequence, visible next sequence, acknowledgement count, and visible token
/// count. It then commits these digests in order: package, representation,
/// input archive, tokenizer domain, tokenizer behavior, tokenizer config,
/// local plan, request, checkpoint selector, checkpoint set, checkpoint
/// state, sink selector, sink ledger, sink implementation, sink instance,
/// head acknowledgement, result-sink prefix, visible tokens, and visible
/// bytes. Derived UTF-8 validity, checkpoint-pending, and disclosure policy
/// are deliberately excluded.
///
/// This complete layout replaces the earlier unpublished in-tree draft, so
/// the initial v1 ABI and domain remain unchanged.
pub fn viewRootV1(input: ViewRootInputV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(view_domain);
    hashU64(&hash, view_abi);
    hashU64(&hash, @intFromEnum(input.sequence_state));
    hashU64(&hash, @intFromBool(input.terminal));
    hashU64(&hash, input.generation);
    hashU64(&hash, input.request_epoch);
    hashU64(&hash, input.sink_initial_sequence);
    hashU64(&hash, input.checkpoint_next_sequence);
    hashU64(&hash, input.visible_next_sequence);
    hashU64(
        &hash,
        @as(u64, @intCast(input.acknowledgement_count)),
    );
    hashU64(
        &hash,
        @as(u64, @intCast(input.visible_token_count)),
    );
    hash.update(&input.package_sha256);
    hash.update(&input.representation_sha256);
    hash.update(&input.input_archive_sha256);
    hash.update(&input.tokenizer_domain_sha256);
    hash.update(&input.tokenizer_behavior_sha256);
    hash.update(&input.tokenizer_config_sha256);
    hash.update(&input.local_plan_sha256);
    hash.update(&input.request_sha256);
    hash.update(&input.checkpoint_selector_sha256);
    hash.update(&input.checkpoint_set_sha256);
    hash.update(&input.checkpoint_state_sha256);
    hash.update(&input.sink_selector_sha256);
    hash.update(&input.sink_ledger_sha256);
    hash.update(&input.sink_implementation_sha256);
    hash.update(&input.sink_instance_sha256);
    hash.update(&input.head_acknowledgement_sha256);
    hash.update(&input.result_sink_prefix_sha256);
    hash.update(&input.visible_tokens_sha256);
    hash.update(&input.visible_bytes_sha256);
    return finish(&hash);
}

/// Lowercase hexadecimal rendering. The destination is unchanged on failure.
pub fn encodeVisibleBytesHexV1(
    visible_bytes: []const u8,
    destination: []u8,
) Error![]const u8 {
    const required = std.math.mul(
        usize,
        visible_bytes.len,
        2,
    ) catch return Error.ArithmeticOverflow;
    if (destination.len < required)
        return Error.BufferTooSmall;
    if (slicesOverlap(visible_bytes, destination[0..required]))
        return Error.UnsafeDestination;
    const digits = "0123456789abcdef";
    for (visible_bytes, 0..) |byte, index| {
        destination[index * 2] = digits[byte >> 4];
        destination[index * 2 + 1] = digits[byte & 0x0f];
    }
    return destination[0..required];
}

pub const encodeLowerHexV1 = encodeVisibleBytesHexV1;

/// Deterministic ASCII-only lossless display. Printable ASCII is literal
/// except backslash (`\\`); all other bytes use lowercase `\xhh`.
pub fn escapeVisibleBytesV1(
    visible_bytes: []const u8,
    destination: []u8,
) Error![]const u8 {
    var required: usize = 0;
    for (visible_bytes) |byte| {
        const width: usize = if (byte == '\\')
            2
        else if (byte >= 0x20 and byte <= 0x7e)
            1
        else
            4;
        required = std.math.add(
            usize,
            required,
            width,
        ) catch return Error.ArithmeticOverflow;
    }
    if (destination.len < required)
        return Error.BufferTooSmall;
    if (slicesOverlap(visible_bytes, destination[0..required]))
        return Error.UnsafeDestination;

    const digits = "0123456789abcdef";
    var cursor: usize = 0;
    for (visible_bytes) |byte| {
        if (byte == '\\') {
            destination[cursor] = '\\';
            destination[cursor + 1] = '\\';
            cursor += 2;
        } else if (byte >= 0x20 and byte <= 0x7e) {
            destination[cursor] = byte;
            cursor += 1;
        } else {
            destination[cursor] = '\\';
            destination[cursor + 1] = 'x';
            destination[cursor + 2] = digits[byte >> 4];
            destination[cursor + 3] = digits[byte & 0x0f];
            cursor += 4;
        }
    }
    std.debug.assert(cursor == required);
    return destination[0..required];
}

pub const escapeBytesV1 = escapeVisibleBytesV1;

fn validateContextV1(context: ContextV1) Error!void {
    if (digestIsZero(context.package_sha256) or
        digestIsZero(context.representation_sha256) or
        digestIsZero(context.input_archive_sha256) or
        digestIsZero(context.local_plan_sha256) or
        !tokenizer.utf8ByteManifestValidV1(
            context.tokenizer_manifest,
        ))
        return Error.InvalidContext;
}

fn validateCheckpointScalarsV1(
    checkpoint: VerifiedCheckpointOutputV1,
) Error!void {
    if (checkpoint.generation < 2 or
        checkpoint.request_epoch == 0 or
        checkpoint.next_sequence == 0 or
        checkpoint.canonical_output_u32_le.len == 0 or
        checkpoint.canonical_output_u32_le.len %
            @sizeOf(u32) != 0 or
        checkpoint.canonical_output_u32_le.len /
            @sizeOf(u32) != checkpoint.next_sequence or
        checkpoint.sink_initial_sequence >
            checkpoint.next_sequence or
        digestIsZero(checkpoint.request_sha256) or
        digestIsZero(checkpoint.sink_implementation_sha256) or
        digestIsZero(checkpoint.sink_instance_sha256) or
        digestIsZero(checkpoint.selector_sha256) or
        digestIsZero(checkpoint.selected_set_sha256) or
        digestIsZero(checkpoint.state_sha256))
        return Error.InvalidCheckpoint;
    if (checkpoint.next_sequence > maximum_visible_tokens)
        return Error.OutputTooLarge;
}

fn checkpointTokenV1(
    checkpoint: VerifiedCheckpointOutputV1,
    sequence: u64,
) u32 {
    return checkpointTokenAtIndexV1(
        checkpoint,
        @intCast(sequence),
    );
}

fn checkpointTokenAtIndexV1(
    checkpoint: VerifiedCheckpointOutputV1,
    index: usize,
) u32 {
    const offset = index * @sizeOf(u32);
    return std.mem.readInt(
        u32,
        checkpoint.canonical_output_u32_le[offset..][0..4],
        .little,
    );
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn digestIsZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, @intCast(value), .little);
    hash.update(&encoded);
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

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0)
        return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(
        usize,
        left_start,
        left.len,
    ) catch return true;
    const right_end = std.math.add(
        usize,
        right_start,
        right.len,
    ) catch return true;
    return left_start < right_end and right_start < left_end;
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
) result_sink.DeliveryInputV1 {
    var label: [96]u8 = undefined;
    return .{
        .request_sha256 = request_sha256,
        .request_epoch = request_epoch,
        .transaction_sequence = sequence,
        .token_id = token_id,
        .proposal_sha256 = testDigest(std.fmt.bufPrint(
            &label,
            "proposal:{d}:{d}",
            .{ sequence, token_id },
        ) catch unreachable),
        .transition_sha256 = testDigest(std.fmt.bufPrint(
            &label,
            "transition:{d}:{d}",
            .{ sequence, token_id },
        ) catch unreachable),
        .commit_receipt_sha256 = testDigest(std.fmt.bufPrint(
            &label,
            "receipt:{d}:{d}",
            .{ sequence, token_id },
        ) catch unreachable),
    };
}

fn testContext() ContextV1 {
    return .{
        .package_sha256 = testDigest("package"),
        .representation_sha256 = testDigest("representation"),
        .input_archive_sha256 = testDigest("input archive"),
        .tokenizer_manifest = tokenizer.makeUtf8ByteManifestV1(
            256,
            1024,
        ) catch unreachable,
        .local_plan_sha256 = testDigest("local plan"),
    };
}

fn encodeTestTokens(
    tokens: []const u32,
    storage: []u8,
) []const u8 {
    std.debug.assert(storage.len >= tokens.len * @sizeOf(u32));
    for (tokens, 0..) |token, index|
        std.mem.writeInt(
            u32,
            storage[index * 4 ..][0..4],
            token,
            .little,
        );
    return storage[0 .. tokens.len * @sizeOf(u32)];
}

fn testSinkSelection(
    initial_sequence: u64,
    tokens: []const u32,
    ledger_storage: []u8,
) !DecodedSinkSelectionV1 {
    const request = testDigest("request");
    const implementation = testDigest("sink implementation");
    const instance = testDigest("sink instance");
    var semantic = try result_sink.ResultSinkV1(8).init(
        request,
        77,
        initial_sequence,
        implementation,
        instance,
    );
    for (tokens, 0..) |token, index| {
        _ = try semantic.apply(testInput(
            request,
            77,
            initial_sequence + index,
            token,
        ));
    }
    const prepared = try sink_file.encodeLedgerV1(
        request,
        77,
        initial_sequence,
        implementation,
        instance,
        semantic.acknowledgementSlice(),
        ledger_storage,
    );
    const ledger = try sink_file.decodeLedgerV1(prepared.bytes);
    return .{
        .selector = .{
            .generation = @as(u64, @intCast(tokens.len)) + 1,
            .acknowledgement_count = tokens.len,
            .initial_sequence = initial_sequence,
            .next_sequence = initial_sequence + tokens.len,
            .request_epoch = 77,
            .ledger_bytes = ledger.encoded.len,
            .request_sha256 = request,
            .sink_implementation_sha256 = implementation,
            .sink_instance_sha256 = instance,
            .previous_selector_sha256 = if (tokens.len == 0)
                zero_digest
            else
                testDigest("previous sink selector"),
            .ledger_sha256 = ledger.ledger_sha256,
            .selector_sha256 = testDigest("sink selector"),
        },
        .ledger = ledger,
    };
}

fn testCheckpoint(
    context: ContextV1,
    output: []const u8,
    next_sequence: u64,
    initial_sequence: u64,
    head_ack: Digest,
    head_prefix: Digest,
    terminal: bool,
) VerifiedCheckpointOutputV1 {
    return .{
        .context = context,
        .generation = 3,
        .terminal = terminal,
        .request_epoch = 77,
        .next_sequence = next_sequence,
        .sink_initial_sequence = initial_sequence,
        .canonical_output_u32_le = output,
        .request_sha256 = testDigest("request"),
        .sink_implementation_sha256 = testDigest("sink implementation"),
        .sink_instance_sha256 = testDigest("sink instance"),
        .head_acknowledgement_sha256 = head_ack,
        .result_sink_prefix_sha256 = head_prefix,
        .selector_sha256 = testDigest("checkpoint selector"),
        .selected_set_sha256 = testDigest("checkpoint set"),
        .state_sha256 = testDigest("checkpoint state"),
    };
}

fn testViewRootInput() ViewRootInputV1 {
    const bytes = "Ice!";
    return .{
        .sequence_state = .sink_exactly_one_ahead,
        .terminal = false,
        .generation = 3,
        .request_epoch = 0x5231_4b42_3300_0001,
        .sink_initial_sequence = 1,
        .checkpoint_next_sequence = 3,
        .visible_next_sequence = 4,
        .acknowledgement_count = 3,
        .visible_token_count = 4,
        .package_sha256 = testDigest("R1k-b3 package"),
        .representation_sha256 = testDigest("R1k-b3 representation"),
        .input_archive_sha256 = testDigest("R1k-b3 input archive"),
        .tokenizer_domain_sha256 = testDigest("R1k-b3 tokenizer domain"),
        .tokenizer_behavior_sha256 = testDigest("R1k-b3 tokenizer behavior"),
        .tokenizer_config_sha256 = testDigest("R1k-b3 tokenizer config"),
        .local_plan_sha256 = testDigest("R1k-b3 local plan"),
        .request_sha256 = testDigest("R1k-b3 request"),
        .checkpoint_selector_sha256 = testDigest("R1k-b3 checkpoint selector"),
        .checkpoint_set_sha256 = testDigest("R1k-b3 checkpoint set"),
        .checkpoint_state_sha256 = testDigest("R1k-b3 checkpoint state"),
        .sink_selector_sha256 = testDigest("R1k-b3 sink selector"),
        .sink_ledger_sha256 = testDigest("R1k-b3 sink ledger"),
        .sink_implementation_sha256 = testDigest("R1k-b3 sink implementation"),
        .sink_instance_sha256 = testDigest("R1k-b3 sink instance"),
        .head_acknowledgement_sha256 = testDigest("acknowledgement:3:33:2"),
        .result_sink_prefix_sha256 = testDigest("sink-prefix:3:33:2"),
        .visible_tokens_sha256 = visibleTokensRootV1(bytes),
        .visible_bytes_sha256 = visibleBytesRootV1(bytes),
    };
}

test "aligned and one-ahead views reconcile exact byte tokens" {
    const context = testContext();
    var ledger_storage: [
        sink_file.ledger_header_bytes +
            3 * result_sink.acknowledgement_bytes +
            sink_file.ledger_footer_bytes
    ]u8 = undefined;
    const aligned_sink = try testSinkSelection(
        1,
        &.{ 99, 101 },
        &ledger_storage,
    );
    var token_storage: [12]u8 = undefined;
    const output = encodeTestTokens(
        &.{ 73, 99, 101 },
        &token_storage,
    );
    const aligned_checkpoint = testCheckpoint(
        context,
        output,
        3,
        1,
        aligned_sink.ledger.last_acknowledgement_sha256,
        aligned_sink.ledger.result_sink_prefix_sha256,
        true,
    );
    var visible_storage: [8]u8 = undefined;
    const aligned = try reconcileV1(
        context,
        aligned_checkpoint,
        aligned_sink,
        &visible_storage,
    );
    try std.testing.expectEqual(
        SequenceStateV1.aligned,
        aligned.sequence_state,
    );
    try std.testing.expectEqualStrings("Ice", aligned.visible_bytes);
    try std.testing.expect(aligned.terminal);
    try std.testing.expect(aligned.utf8_valid);

    const one_ahead_sink = try testSinkSelection(
        1,
        &.{ 99, 101 },
        &ledger_storage,
    );
    const first_ack = try one_ahead_sink.ledger.acknowledgement(0);
    const one_ahead_checkpoint = testCheckpoint(
        context,
        output[0..8],
        2,
        1,
        first_ack.acknowledgement_sha256,
        first_ack.result_sink_prefix_sha256,
        false,
    );
    const one_ahead = try reconcileV1(
        context,
        one_ahead_checkpoint,
        one_ahead_sink,
        &visible_storage,
    );
    try std.testing.expectEqual(
        SequenceStateV1.sink_exactly_one_ahead,
        one_ahead.sequence_state,
    );
    try std.testing.expectEqualStrings("Ice", one_ahead.visible_bytes);
    try std.testing.expect(one_ahead.checkpoint_pending);
}

test "reconciliation rejects rollback gaps mismatches and terminal pending" {
    const context = testContext();
    var ledger_storage: [
        sink_file.ledger_header_bytes +
            3 * result_sink.acknowledgement_bytes +
            sink_file.ledger_footer_bytes
    ]u8 = undefined;
    const sink = try testSinkSelection(
        1,
        &.{ 99, 101 },
        &ledger_storage,
    );
    const first_ack = try sink.ledger.acknowledgement(0);
    var token_storage: [16]u8 = undefined;
    const output = encodeTestTokens(
        &.{ 73, 99, 101, 33 },
        &token_storage,
    );
    var visible_storage: [8]u8 = undefined;

    try std.testing.expectError(
        Error.InvalidAlignment,
        reconcileV1(
            context,
            testCheckpoint(
                context,
                output,
                4,
                1,
                sink.ledger.last_acknowledgement_sha256,
                sink.ledger.result_sink_prefix_sha256,
                false,
            ),
            sink,
            &visible_storage,
        ),
    );
    try std.testing.expectError(
        Error.InvalidAlignment,
        reconcileV1(
            context,
            testCheckpoint(
                context,
                output[0..4],
                1,
                1,
                zero_digest,
                zero_digest,
                false,
            ),
            sink,
            &visible_storage,
        ),
    );
    try std.testing.expectError(
        Error.InvalidAlignment,
        reconcileV1(
            context,
            testCheckpoint(
                context,
                output[0..8],
                2,
                1,
                first_ack.acknowledgement_sha256,
                first_ack.result_sink_prefix_sha256,
                true,
            ),
            sink,
            &visible_storage,
        ),
    );
    var mismatched = testCheckpoint(
        context,
        output[0..8],
        2,
        1,
        first_ack.acknowledgement_sha256,
        first_ack.result_sink_prefix_sha256,
        false,
    );
    var changed_output: [8]u8 = undefined;
    mismatched.canonical_output_u32_le = encodeTestTokens(
        &.{ 73, 100 },
        &changed_output,
    );
    try std.testing.expectError(
        Error.InvalidAcknowledgement,
        reconcileV1(
            context,
            mismatched,
            sink,
            &visible_storage,
        ),
    );
}

test "byte profile rejects non-byte tokens and preserves invalid UTF-8" {
    const context = testContext();
    var empty_ledger_storage: [
        sink_file.ledger_header_bytes + sink_file.ledger_footer_bytes
    ]u8 = undefined;
    const empty_sink = try testSinkSelection(
        1,
        &.{},
        &empty_ledger_storage,
    );
    var token_storage: [8]u8 = undefined;
    const invalid_token = encodeTestTokens(
        &.{300},
        &token_storage,
    );
    var visible_storage: [8]u8 = [_]u8{0xaa} ** 8;
    try std.testing.expectError(
        Error.InvalidToken,
        reconcileV1(
            context,
            testCheckpoint(
                context,
                invalid_token,
                1,
                1,
                zero_digest,
                zero_digest,
                false,
            ),
            empty_sink,
            &visible_storage,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0xaa} ** 8),
        &visible_storage,
    );

    var invalid_utf8_ledger_storage: [
        sink_file.ledger_header_bytes +
            result_sink.acknowledgement_bytes +
            sink_file.ledger_footer_bytes
    ]u8 = undefined;
    const invalid_utf8_sink = try testSinkSelection(
        1,
        &.{0x9c},
        &invalid_utf8_ledger_storage,
    );
    const acknowledgement =
        try invalid_utf8_sink.ledger.acknowledgement(0);
    const invalid_utf8_output = encodeTestTokens(
        &.{ 0x27, 0x9c },
        &token_storage,
    );
    const view = try reconcileV1(
        context,
        testCheckpoint(
            context,
            invalid_utf8_output,
            2,
            1,
            acknowledgement.acknowledgement_sha256,
            acknowledgement.result_sink_prefix_sha256,
            false,
        ),
        invalid_utf8_sink,
        &visible_storage,
    );
    try std.testing.expect(!view.utf8_valid);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x27, 0x9c },
        view.visible_bytes,
    );
}

test "roots and lossless renderers match independent oracle goldens" {
    const bytes = "Ice!";
    var expected_tokens: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_tokens,
        "73536c376a840bf42dba5005fb6f652e" ++
            "9963ba141013c3020882c22ce2ea8844",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_tokens,
        &visibleTokensRootV1(bytes),
    );
    var expected_bytes: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_bytes,
        "b932c4c466ecabd13dec804da071e2fe" ++
            "2775b7b38a16dc0dba754eb0b96d274d",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_bytes,
        &visibleBytesRootV1(bytes),
    );

    const root = viewRootV1(testViewRootInput());
    var expected_view: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_view,
        "1bc766c0e45628814d661993f61602b4" ++
            "66c0b91c389f84985f733d843d079567",
    );
    try std.testing.expectEqualSlices(u8, &expected_view, &root);

    const raw = [_]u8{ 'A', '\\', '"', 0, 0x9c };
    var escaped_storage: [32]u8 = [_]u8{0xaa} ** 32;
    const escaped = try escapeVisibleBytesV1(
        &raw,
        &escaped_storage,
    );
    try std.testing.expectEqualStrings(
        "A\\\\\"\\x00\\x9c",
        escaped,
    );
    var hex_storage: [16]u8 = undefined;
    try std.testing.expectEqualStrings(
        "415c22009c",
        try encodeVisibleBytesHexV1(&raw, &hex_storage),
    );
    var too_small: [3]u8 = [_]u8{0xbb} ** 3;
    try std.testing.expectError(
        Error.BufferTooSmall,
        escapeVisibleBytesV1(&raw, &too_small),
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0xbb} ** 3),
        &too_small,
    );
}

test "full view root commits terminal context and selected roots" {
    const input = testViewRootInput();
    const baseline = viewRootV1(input);

    var terminal = input;
    terminal.terminal = true;
    try std.testing.expect(!digestEqual(
        baseline,
        viewRootV1(terminal),
    ));

    var context = input;
    context.package_sha256[0] ^= 1;
    try std.testing.expect(!digestEqual(
        baseline,
        viewRootV1(context),
    ));

    var checkpoint = input;
    checkpoint.checkpoint_selector_sha256[0] ^= 1;
    try std.testing.expect(!digestEqual(
        baseline,
        viewRootV1(checkpoint),
    ));

    var sink = input;
    sink.sink_selector_sha256[0] ^= 1;
    try std.testing.expect(!digestEqual(
        baseline,
        viewRootV1(sink),
    ));
}
