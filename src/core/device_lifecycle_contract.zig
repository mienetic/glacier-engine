//! Portable device-lifecycle observation and transition evidence.
//!
//! These pointer-free values bind one source-specific observation to an exact
//! present inventory entry and the canonical inventory that contained it.
//! They do not grant allocation, dispatch, resource-release, device-reset, or
//! migration authority. A caller that consumes an observation must advance
//! its external source cursor. The cursor binds one source instance and its
//! last consumed sequence, so neither an older event nor a fresh source
//! generation can be accepted implicitly.

const std = @import("std");
const device = @import("device_capability_contract.zig");

pub const Digest = device.Digest;
pub const zero_digest = device.zero_digest;

pub const observation_abi: u64 = 0x4744_4c4f_0000_0001;
pub const transition_receipt_abi: u64 = 0x4744_4c54_0000_0001;

pub const command_buffer_status_error: u64 = 5;
pub const command_buffer_error_domain: u64 = 1;
pub const command_buffer_device_removed_error: u64 = 11;

const observation_domain =
    "glacier-device-lifecycle-observation-v1\x00";
const transition_receipt_domain =
    "glacier-device-lifecycle-transition-receipt-v1\x00";

pub const ObservationSourceV1 = enum(u64) {
    initial_membership = 1,
    added_notification = 2,
    inventory_absent = 3,
    removal_requested_notification = 4,
    removed_notification = 5,
    command_buffer_device_removed = 6,
    test_injected = 7,
    _,
};

pub const EvidenceClassV1 = enum(u64) {
    native = 1,
    synthetic = 2,
    _,
};

pub const Error = device.Error || error{
    InvalidObservation,
    StaleObservation,
    SourceInstanceChanged,
    InvalidTransitionReceipt,
};

/// External replay state for one observation producer. A source-generation
/// change requires the caller to install a new instance root explicitly.
pub const SourceCursorV1 = struct {
    source_instance_sha256: Digest = zero_digest,
    last_sequence: u64 = 0,
};

/// One source-specific lifecycle fact about an exact previously present
/// inventory member. `evidence_sha256` binds the native snapshot/notification
/// or the explicit test-injection plan retained by the producer.
pub const ObservationV1 = struct {
    abi_version: u64 = observation_abi,
    source: ObservationSourceV1 = .initial_membership,
    evidence_class: EvidenceClassV1 = .native,
    observed_state: device.InventoryStateV1 = .present,
    source_sequence: u64 = 0,
    native_command_status: u64 = 0,
    native_error_domain_kind: u64 = 0,
    native_error_code_bits: u64 = 0,
    prior_discovery_epoch: u64 = 0,
    prior_policy_rank: u64 = 0,
    prior_inventory_count: u64 = 0,
    source_instance_sha256: Digest = zero_digest,
    prior_inventory_sha256: Digest = zero_digest,
    prior_entry_sha256: Digest = zero_digest,
    capability_sha256: Digest = zero_digest,
    evidence_sha256: Digest = zero_digest,
    observation_sha256: Digest = zero_digest,
};

/// Immutable evidence that one exact present entry was replaced by a
/// non-present successor in a strictly newer discovery epoch.
pub const TransitionReceiptV1 = struct {
    abi_version: u64 = transition_receipt_abi,
    source: ObservationSourceV1 = .inventory_absent,
    evidence_class: EvidenceClassV1 = .native,
    prior_state: device.InventoryStateV1 = .present,
    successor_state: device.InventoryStateV1 = .unavailable,
    source_sequence: u64 = 0,
    prior_inventory_count: u64 = 0,
    prior_discovery_epoch: u64 = 0,
    successor_discovery_epoch: u64 = 0,
    policy_rank: u64 = 0,
    prior_inventory_sha256: Digest = zero_digest,
    prior_entry_sha256: Digest = zero_digest,
    capability_sha256: Digest = zero_digest,
    observation_sha256: Digest = zero_digest,
    successor_entry_sha256: Digest = zero_digest,
    receipt_sha256: Digest = zero_digest,
};

comptime {
    if (@sizeOf(SourceCursorV1) != 40)
        @compileError("SourceCursorV1 layout changed");
    if (@sizeOf(ObservationV1) != 280)
        @compileError("ObservationV1 layout changed");
    if (@sizeOf(TransitionReceiptV1) != 272)
        @compileError("TransitionReceiptV1 layout changed");
}

const SourceSemanticsV1 = struct {
    evidence_class: EvidenceClassV1,
    observed_state: device.InventoryStateV1,
    requires_device_removed_command_error: bool,
};

pub fn makeObservationV1(
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    source_instance_sha256: Digest,
    source_sequence: u64,
    source: ObservationSourceV1,
    evidence_sha256: Digest,
    native_command_status: u64,
    native_error_domain_kind: u64,
    native_error_code_bits: u64,
) Error!ObservationV1 {
    const semantics = sourceSemanticsV1(source) orelse
        return Error.InvalidObservation;
    var result: ObservationV1 = .{
        .source = source,
        .evidence_class = semantics.evidence_class,
        .observed_state = semantics.observed_state,
        .source_sequence = source_sequence,
        .native_command_status = native_command_status,
        .native_error_domain_kind = native_error_domain_kind,
        .native_error_code_bits = native_error_code_bits,
        .prior_discovery_epoch = prior_entry.discovery_epoch,
        .prior_policy_rank = prior_entry.policy_rank,
        .source_instance_sha256 = source_instance_sha256,
        .prior_inventory_count = std.math.cast(
            u64,
            prior_inventory.len,
        ) orelse return Error.InvalidObservation,
        .prior_inventory_sha256 = device.inventoryRootV1(
            prior_inventory,
        ) catch return Error.InvalidObservation,
        .prior_entry_sha256 = prior_entry.entry_sha256,
        .capability_sha256 = prior_entry.capability.capability_sha256,
        .evidence_sha256 = evidence_sha256,
    };
    try validateObservationShapeV1(
        result,
        prior_entry,
        prior_inventory,
    );
    result.observation_sha256 = observationRootV1(result);
    const initial_cursor: SourceCursorV1 = .{
        .source_instance_sha256 = source_instance_sha256,
        .last_sequence = source_sequence - 1,
    };
    try validateObservationV1(
        result,
        prior_entry,
        prior_inventory,
        initial_cursor,
    );
    return result;
}

/// Validate an observation against the caller's last consumed source cursor.
/// Once accepted, the caller must advance the cursor with
/// `validateAndAdvanceObservationV1` before accepting another observation or
/// transition.
pub fn validateObservationV1(
    value: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    source_cursor: SourceCursorV1,
) Error!void {
    if (device.digestIsZero(
        source_cursor.source_instance_sha256,
    ) or
        !device.digestEqual(
            value.source_instance_sha256,
            source_cursor.source_instance_sha256,
        ))
        return Error.SourceInstanceChanged;
    if (value.source_sequence <= source_cursor.last_sequence)
        return Error.StaleObservation;
    try validateObservationShapeV1(
        value,
        prior_entry,
        prior_inventory,
    );
    if (device.digestIsZero(value.observation_sha256) or
        !device.digestEqual(
            value.observation_sha256,
            observationRootV1(value),
        ))
        return Error.InvalidObservation;
}

/// Validate and return the cursor state the caller must retain after
/// consuming this observation. Reusing the returned cursor with the same
/// observation rejects it as stale.
pub fn validateAndAdvanceObservationV1(
    value: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    source_cursor: SourceCursorV1,
) Error!SourceCursorV1 {
    try validateObservationV1(
        value,
        prior_entry,
        prior_inventory,
        source_cursor,
    );
    return .{
        .source_instance_sha256 = value.source_instance_sha256,
        .last_sequence = value.source_sequence,
    };
}

fn validateObservationShapeV1(
    value: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
) Error!void {
    device.validateInventoryEntryV1(prior_entry) catch
        return Error.InvalidObservation;
    if (prior_entry.state != .present or
        prior_entry.capability.feature_bits &
            device.FeatureBitsV1.device_loss_signal == 0 or
        value.abi_version != observation_abi or
        value.source_sequence == 0 or
        device.digestIsZero(value.source_instance_sha256) or
        device.digestIsZero(value.evidence_sha256))
        return Error.InvalidObservation;

    const semantics = sourceSemanticsV1(value.source) orelse
        return Error.InvalidObservation;
    if (value.evidence_class != semantics.evidence_class or
        value.observed_state != semantics.observed_state or
        !nativeCommandFieldsValidV1(value, semantics))
        return Error.InvalidObservation;

    const inventory_sha256 = device.inventoryRootV1(
        prior_inventory,
    ) catch return Error.InvalidObservation;
    const inventory_count = std.math.cast(
        u64,
        prior_inventory.len,
    ) orelse return Error.InvalidObservation;
    if (!inventoryContainsExactEntryV1(
        prior_inventory,
        prior_entry,
    ) or
        value.prior_discovery_epoch !=
            prior_entry.discovery_epoch or
        value.prior_policy_rank != prior_entry.policy_rank or
        value.prior_inventory_count != inventory_count or
        !device.digestEqual(
            value.prior_inventory_sha256,
            inventory_sha256,
        ) or
        !device.digestEqual(
            value.prior_entry_sha256,
            prior_entry.entry_sha256,
        ) or
        !device.digestEqual(
            value.capability_sha256,
            prior_entry.capability.capability_sha256,
        ))
        return Error.InvalidObservation;
}

fn nativeCommandFieldsValidV1(
    value: ObservationV1,
    semantics: SourceSemanticsV1,
) bool {
    if (semantics.requires_device_removed_command_error) {
        return value.native_command_status ==
            command_buffer_status_error and
            value.native_error_domain_kind ==
                command_buffer_error_domain and
            value.native_error_code_bits ==
                command_buffer_device_removed_error;
    }
    // Synthetic evidence must never carry fields that could be mistaken for
    // a native command-buffer observation. Notification and inventory sources
    // likewise keep their independent evidence projections canonical.
    return value.native_command_status == 0 and
        value.native_error_domain_kind == 0 and
        value.native_error_code_bits == 0;
}

fn sourceSemanticsV1(
    source: ObservationSourceV1,
) ?SourceSemanticsV1 {
    return switch (source) {
        .initial_membership, .added_notification => .{
            .evidence_class = .native,
            .observed_state = .present,
            .requires_device_removed_command_error = false,
        },
        .inventory_absent,
        .removal_requested_notification,
        => .{
            .evidence_class = .native,
            .observed_state = .unavailable,
            .requires_device_removed_command_error = false,
        },
        .removed_notification => .{
            .evidence_class = .native,
            .observed_state = .lost,
            .requires_device_removed_command_error = false,
        },
        .command_buffer_device_removed => .{
            .evidence_class = .native,
            .observed_state = .lost,
            .requires_device_removed_command_error = true,
        },
        .test_injected => .{
            .evidence_class = .synthetic,
            .observed_state = .lost,
            .requires_device_removed_command_error = false,
        },
        _ => null,
    };
}

pub fn observationRootV1(value: ObservationV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(observation_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.source));
    hashU64(&hash, @intFromEnum(value.evidence_class));
    hashU64(&hash, @intFromEnum(value.observed_state));
    hashU64(&hash, value.source_sequence);
    hashU64(&hash, value.native_command_status);
    hashU64(&hash, value.native_error_domain_kind);
    hashU64(&hash, value.native_error_code_bits);
    hashU64(&hash, value.prior_discovery_epoch);
    hashU64(&hash, value.prior_policy_rank);
    hashU64(&hash, value.prior_inventory_count);
    hash.update(&value.source_instance_sha256);
    hash.update(&value.prior_inventory_sha256);
    hash.update(&value.prior_entry_sha256);
    hash.update(&value.capability_sha256);
    hash.update(&value.evidence_sha256);
    return finish(&hash);
}

/// Derive the only successor entry authorized by one observation. Present
/// observations are baseline/addition evidence and cannot create a lifecycle
/// transition receipt.
pub fn makeSuccessorEntryV1(
    observation: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    source_cursor: SourceCursorV1,
    successor_discovery_epoch: u64,
) Error!device.DeviceInventoryEntryV1 {
    try validateObservationV1(
        observation,
        prior_entry,
        prior_inventory,
        source_cursor,
    );
    if (!transitionStateValidV1(observation.observed_state) or
        successor_discovery_epoch <= prior_entry.discovery_epoch)
        return Error.InvalidTransitionReceipt;
    return device.sealInventoryEntryV1(.{
        .discovery_epoch = successor_discovery_epoch,
        .policy_rank = prior_entry.policy_rank,
        .state = observation.observed_state,
        .capability = prior_entry.capability,
    }) catch return Error.InvalidTransitionReceipt;
}

pub fn makeTransitionReceiptV1(
    observation: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    source_cursor: SourceCursorV1,
) Error!TransitionReceiptV1 {
    try validateTransitionInputsV1(
        observation,
        prior_entry,
        prior_inventory,
        successor_entry,
        source_cursor,
    );
    var result: TransitionReceiptV1 = .{
        .source = observation.source,
        .evidence_class = observation.evidence_class,
        .prior_state = prior_entry.state,
        .successor_state = successor_entry.state,
        .source_sequence = observation.source_sequence,
        .prior_inventory_count = observation.prior_inventory_count,
        .prior_discovery_epoch = prior_entry.discovery_epoch,
        .successor_discovery_epoch = successor_entry.discovery_epoch,
        .policy_rank = prior_entry.policy_rank,
        .prior_inventory_sha256 = observation.prior_inventory_sha256,
        .prior_entry_sha256 = prior_entry.entry_sha256,
        .capability_sha256 = prior_entry.capability.capability_sha256,
        .observation_sha256 = observation.observation_sha256,
        .successor_entry_sha256 = successor_entry.entry_sha256,
    };
    result.receipt_sha256 = transitionReceiptRootV1(result);
    try validateTransitionReceiptV1(
        result,
        observation,
        prior_entry,
        prior_inventory,
        successor_entry,
        source_cursor,
    );
    return result;
}

/// Replays every nested binding and recomputes the prior inventory root. The
/// source cursor is deliberately external so a previously consumed,
/// otherwise self-consistent receipt is rejected as stale. A new source
/// instance also requires an explicit cursor reset.
pub fn validateTransitionReceiptV1(
    value: TransitionReceiptV1,
    observation: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    source_cursor: SourceCursorV1,
) Error!void {
    try validateTransitionInputsV1(
        observation,
        prior_entry,
        prior_inventory,
        successor_entry,
        source_cursor,
    );
    if (value.abi_version != transition_receipt_abi or
        value.source != observation.source or
        value.evidence_class != observation.evidence_class or
        value.prior_state != .present or
        value.successor_state != successor_entry.state or
        value.source_sequence !=
            observation.source_sequence or
        value.prior_inventory_count !=
            observation.prior_inventory_count or
        value.prior_discovery_epoch !=
            prior_entry.discovery_epoch or
        value.successor_discovery_epoch !=
            successor_entry.discovery_epoch or
        value.policy_rank != prior_entry.policy_rank or
        !device.digestEqual(
            value.prior_inventory_sha256,
            observation.prior_inventory_sha256,
        ) or
        !device.digestEqual(
            value.prior_entry_sha256,
            prior_entry.entry_sha256,
        ) or
        !device.digestEqual(
            value.capability_sha256,
            prior_entry.capability.capability_sha256,
        ) or
        !device.digestEqual(
            value.observation_sha256,
            observation.observation_sha256,
        ) or
        !device.digestEqual(
            value.successor_entry_sha256,
            successor_entry.entry_sha256,
        ) or
        device.digestIsZero(value.receipt_sha256) or
        !device.digestEqual(
            value.receipt_sha256,
            transitionReceiptRootV1(value),
        ))
        return Error.InvalidTransitionReceipt;
}

fn validateTransitionInputsV1(
    observation: ObservationV1,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    source_cursor: SourceCursorV1,
) Error!void {
    try validateObservationV1(
        observation,
        prior_entry,
        prior_inventory,
        source_cursor,
    );
    device.validateInventoryEntryV1(successor_entry) catch
        return Error.InvalidTransitionReceipt;
    if (prior_entry.state != .present or
        !transitionStateValidV1(successor_entry.state) or
        successor_entry.state != observation.observed_state or
        successor_entry.discovery_epoch <=
            prior_entry.discovery_epoch or
        successor_entry.policy_rank != prior_entry.policy_rank or
        !std.meta.eql(
            successor_entry.capability,
            prior_entry.capability,
        ))
        return Error.InvalidTransitionReceipt;
}

fn transitionStateValidV1(
    state: device.InventoryStateV1,
) bool {
    return state == .unavailable or state == .lost;
}

pub fn transitionReceiptRootV1(
    value: TransitionReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(transition_receipt_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.source));
    hashU64(&hash, @intFromEnum(value.evidence_class));
    hashU64(&hash, @intFromEnum(value.prior_state));
    hashU64(&hash, @intFromEnum(value.successor_state));
    hashU64(&hash, value.source_sequence);
    hashU64(&hash, value.prior_inventory_count);
    hashU64(&hash, value.prior_discovery_epoch);
    hashU64(&hash, value.successor_discovery_epoch);
    hashU64(&hash, value.policy_rank);
    hash.update(&value.prior_inventory_sha256);
    hash.update(&value.prior_entry_sha256);
    hash.update(&value.capability_sha256);
    hash.update(&value.observation_sha256);
    hash.update(&value.successor_entry_sha256);
    return finish(&hash);
}

fn inventoryContainsExactEntryV1(
    inventory: []const device.DeviceInventoryEntryV1,
    expected: device.DeviceInventoryEntryV1,
) bool {
    for (inventory) |entry| {
        if (device.digestEqual(
            entry.entry_sha256,
            expected.entry_sha256,
        ))
            return std.meta.eql(entry, expected);
    }
    return false;
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn portableTypeHasPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| portableTypeHasPointer(info.child),
        .optional => |info| portableTypeHasPointer(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (portableTypeHasPointer(field.type))
                    break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn testCapability(
    name: []const u8,
) !device.DeviceCapabilityV1 {
    const profile =
        device.OperationProfileBitsV1.matvec_int4_f32_bounded;
    return device.sealCapabilityV1(.{
        .backend_kind = .metal,
        .device_class = .accelerator,
        .operation_profile_bits = profile,
        .operator_bits = device.profileOperatorBitsV1(profile),
        .element_type_bits = device.profileElementTypeBitsV1(profile),
        .numerical_policy_bits = device.profileNumericalPolicyBitsV1(profile),
        .feature_bits = device.FeatureBitsV1.allocation |
            device.FeatureBitsV1.dispatch |
            device.FeatureBitsV1.completion_fence |
            device.FeatureBitsV1.device_loss_signal,
        .max_single_allocation_bytes = 1 << 20,
        .max_total_device_bytes = 8 << 20,
        .max_queue_slots = 1,
        .backend_sha256 = device.digestV1(
            "lifecycle test backend",
        ),
        .device_sha256 = device.digestV1(name),
        .driver_sha256 = device.digestV1(
            "lifecycle test driver",
        ),
        .placement_sha256 = device.digestV1(
            "lifecycle test placement",
        ),
    });
}

fn testEntry(
    capability: device.DeviceCapabilityV1,
    epoch: u64,
    rank: u64,
    state: device.InventoryStateV1,
) !device.DeviceInventoryEntryV1 {
    return device.sealInventoryEntryV1(.{
        .discovery_epoch = epoch,
        .policy_rank = rank,
        .state = state,
        .capability = capability,
    });
}

fn rehashObservation(
    value: *ObservationV1,
) void {
    value.observation_sha256 = observationRootV1(value.*);
}

fn rehashReceipt(
    value: *TransitionReceiptV1,
) void {
    value.receipt_sha256 = transitionReceiptRootV1(value.*);
}

fn testSourceInstance() Digest {
    return device.digestV1("lifecycle test source instance");
}

fn testCursorBefore(sequence: u64) SourceCursorV1 {
    return .{
        .source_instance_sha256 = testSourceInstance(),
        .last_sequence = sequence - 1,
    };
}

fn testCursorAt(sequence: u64) SourceCursorV1 {
    return .{
        .source_instance_sha256 = testSourceInstance(),
        .last_sequence = sequence,
    };
}

fn makeTestObservationV1(
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    source_sequence: u64,
    source: ObservationSourceV1,
    evidence_sha256: Digest,
    native_command_status: u64,
    native_error_domain_kind: u64,
    native_error_code_bits: u64,
) Error!ObservationV1 {
    return makeObservationV1(
        prior_entry,
        prior_inventory,
        testSourceInstance(),
        source_sequence,
        source,
        evidence_sha256,
        native_command_status,
        native_error_domain_kind,
        native_error_code_bits,
    );
}

fn expectDigestHex(
    expected: []const u8,
    actual: Digest,
) !void {
    const encoded = std.fmt.bytesToHex(actual, .lower);
    try std.testing.expectEqualStrings(expected, &encoded);
}

test "portable lifecycle evidence contains no pointers" {
    try std.testing.expect(!portableTypeHasPointer(SourceCursorV1));
    try std.testing.expect(!portableTypeHasPointer(ObservationV1));
    try std.testing.expect(!portableTypeHasPointer(
        TransitionReceiptV1,
    ));
}

test "lifecycle observation and transition literal roots stay stable" {
    const profile =
        device.OperationProfileBitsV1.matvec_int4_f32_bounded;
    const capability = try device.sealCapabilityV1(.{
        .backend_kind = .metal,
        .device_class = .accelerator,
        .operation_profile_bits = profile,
        .operator_bits = device.profileOperatorBitsV1(profile),
        .element_type_bits = device.profileElementTypeBitsV1(profile),
        .numerical_policy_bits = device.profileNumericalPolicyBitsV1(profile),
        .feature_bits = device.FeatureBitsV1.allocation |
            device.FeatureBitsV1.dispatch |
            device.FeatureBitsV1.completion_fence |
            device.FeatureBitsV1.device_loss_signal,
        .max_single_allocation_bytes = 1 << 20,
        .max_total_device_bytes = 8 << 20,
        .max_queue_slots = 1,
        .backend_sha256 = device.digestV1("lifecycle golden backend"),
        .device_sha256 = device.digestV1("lifecycle golden gpu"),
        .driver_sha256 = device.digestV1("lifecycle golden driver"),
        .placement_sha256 = device.digestV1("lifecycle golden placement"),
    });
    const prior = try testEntry(capability, 41, 7, .present);
    const inventory = [_]device.DeviceInventoryEntryV1{prior};
    const evidence = device.digestV1(
        "lifecycle golden native command-buffer evidence",
    );
    const observation = try makeTestObservationV1(
        prior,
        &inventory,
        19,
        .command_buffer_device_removed,
        evidence,
        command_buffer_status_error,
        command_buffer_error_domain,
        command_buffer_device_removed_error,
    );
    const successor = try makeSuccessorEntryV1(
        observation,
        prior,
        &inventory,
        testCursorBefore(19),
        42,
    );
    const transition = try makeTransitionReceiptV1(
        observation,
        prior,
        &inventory,
        successor,
        testCursorBefore(19),
    );

    try expectDigestHex(
        "4f14741a5fbef054bb35be4de81d46e247b7b795494c408d7df90f26f0ab62a3",
        capability.capability_sha256,
    );
    try expectDigestHex(
        "6270f4ae8759ed3dc8f07e50f4eacc76334406151b3cb8789cdcb3a4d5c12fbc",
        prior.entry_sha256,
    );
    try expectDigestHex(
        "1c223532c22b496f0a2f69e723043cffe8775f434b42fb4584f5b7cc4ab4ee2c",
        observation.prior_inventory_sha256,
    );
    try expectDigestHex(
        "ce333d050406912e0ed41107d15dd3a8faeb314d3f7ffdb72eedc9796e2f383c",
        evidence,
    );
    try expectDigestHex(
        "52866097cde887ee870f95642bc47b34f4e7fe0e50bb4252638ccbe959639132",
        observation.source_instance_sha256,
    );
    try expectDigestHex(
        "1c23285a0322059473e15b909ba82fbf3ffbfc03d4a206ad0f527170ccf98215",
        observation.observation_sha256,
    );
    try expectDigestHex(
        "69e7e35692c43ec011939c250fa78efd743c2e2d73862ea64ffef690de78e6b8",
        successor.entry_sha256,
    );
    try expectDigestHex(
        "1636f05f5ae4953bb629a876bc92de4cfe2fc7d01219868e1819d7ebd04523ab",
        transition.receipt_sha256,
    );
}

test "observation sources map to canonical states and evidence classes" {
    const capability = try testCapability("lifecycle source gpu");
    const prior = try testEntry(capability, 41, 7, .present);
    const inventory = [_]device.DeviceInventoryEntryV1{prior};
    const evidence = device.digestV1("source evidence");
    const cases = [_]struct {
        source: ObservationSourceV1,
        state: device.InventoryStateV1,
        class: EvidenceClassV1,
        status: u64 = 0,
        domain: u64 = 0,
        code: u64 = 0,
    }{
        .{
            .source = .initial_membership,
            .state = .present,
            .class = .native,
        },
        .{
            .source = .added_notification,
            .state = .present,
            .class = .native,
        },
        .{
            .source = .inventory_absent,
            .state = .unavailable,
            .class = .native,
        },
        .{
            .source = .removal_requested_notification,
            .state = .unavailable,
            .class = .native,
        },
        .{
            .source = .removed_notification,
            .state = .lost,
            .class = .native,
        },
        .{
            .source = .command_buffer_device_removed,
            .state = .lost,
            .class = .native,
            .status = command_buffer_status_error,
            .domain = command_buffer_error_domain,
            .code = command_buffer_device_removed_error,
        },
        .{
            .source = .test_injected,
            .state = .lost,
            .class = .synthetic,
        },
    };

    for (cases, 0..) |case, index| {
        const sequence: u64 = @intCast(index + 1);
        const observation = try makeTestObservationV1(
            prior,
            &inventory,
            sequence,
            case.source,
            evidence,
            case.status,
            case.domain,
            case.code,
        );
        try std.testing.expectEqual(
            case.state,
            observation.observed_state,
        );
        try std.testing.expectEqual(
            case.class,
            observation.evidence_class,
        );
        try validateObservationV1(
            observation,
            prior,
            &inventory,
            testCursorBefore(sequence),
        );
    }

    const native_removed = try makeTestObservationV1(
        prior,
        &inventory,
        20,
        .removed_notification,
        evidence,
        0,
        0,
        0,
    );
    const synthetic = try makeTestObservationV1(
        prior,
        &inventory,
        20,
        .test_injected,
        evidence,
        0,
        0,
        0,
    );
    try std.testing.expect(!device.digestEqual(
        native_removed.observation_sha256,
        synthetic.observation_sha256,
    ));
}

test "command-buffer device removal requires exact native fields" {
    const capability = try testCapability("exact command gpu");
    const prior = try testEntry(capability, 8, 2, .present);
    const inventory = [_]device.DeviceInventoryEntryV1{prior};
    const evidence = device.digestV1("exact command evidence");

    const exact = try makeTestObservationV1(
        prior,
        &inventory,
        9,
        .command_buffer_device_removed,
        evidence,
        command_buffer_status_error,
        command_buffer_error_domain,
        command_buffer_device_removed_error,
    );
    try validateObservationV1(
        exact,
        prior,
        &inventory,
        testCursorBefore(9),
    );

    const fields = [_][3]u64{
        .{ 4, command_buffer_error_domain, 11 },
        .{ command_buffer_status_error, 2, 11 },
        .{ command_buffer_status_error, command_buffer_error_domain, 1 },
        .{ command_buffer_status_error, command_buffer_error_domain, 0 },
    };
    for (fields) |field| {
        try std.testing.expectError(
            Error.InvalidObservation,
            makeTestObservationV1(
                prior,
                &inventory,
                9,
                .command_buffer_device_removed,
                evidence,
                field[0],
                field[1],
                field[2],
            ),
        );
    }

    try std.testing.expectError(
        Error.InvalidObservation,
        makeTestObservationV1(
            prior,
            &inventory,
            10,
            .removed_notification,
            evidence,
            command_buffer_status_error,
            command_buffer_error_domain,
            command_buffer_device_removed_error,
        ),
    );
    try std.testing.expectError(
        Error.InvalidObservation,
        makeTestObservationV1(
            prior,
            &inventory,
            10,
            .test_injected,
            evidence,
            command_buffer_status_error,
            command_buffer_error_domain,
            command_buffer_device_removed_error,
        ),
    );
}

test "observation validation rejects mutation replay and substitution" {
    const capability = try testCapability("observation primary gpu");
    const sibling_capability =
        try testCapability("observation sibling gpu");
    const foreign_capability =
        try testCapability("observation foreign gpu");
    const prior = try testEntry(capability, 10, 3, .present);
    const sibling =
        try testEntry(sibling_capability, 11, 4, .present);
    const foreign =
        try testEntry(foreign_capability, 10, 3, .present);
    const inventory =
        [_]device.DeviceInventoryEntryV1{ prior, sibling };
    const evidence = device.digestV1("observation mutation evidence");
    const observation = try makeTestObservationV1(
        prior,
        &inventory,
        23,
        .removal_requested_notification,
        evidence,
        0,
        0,
        0,
    );

    try std.testing.expectError(
        Error.StaleObservation,
        validateObservationV1(
            observation,
            prior,
            &inventory,
            testCursorAt(23),
        ),
    );

    var mutated = observation;
    mutated.evidence_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(
            mutated,
            prior,
            &inventory,
            testCursorBefore(23),
        ),
    );

    var rehashed_class = observation;
    rehashed_class.evidence_class = .synthetic;
    rehashObservation(&rehashed_class);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(
            rehashed_class,
            prior,
            &inventory,
            testCursorBefore(23),
        ),
    );

    var rehashed_state = observation;
    rehashed_state.observed_state = .lost;
    rehashObservation(&rehashed_state);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(
            rehashed_state,
            prior,
            &inventory,
            testCursorBefore(23),
        ),
    );

    var unknown_source = observation;
    unknown_source.source = @enumFromInt(99);
    rehashObservation(&unknown_source);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(
            unknown_source,
            prior,
            &inventory,
            testCursorBefore(23),
        ),
    );

    const substituted_inventory =
        [_]device.DeviceInventoryEntryV1{ prior, foreign };
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(
            observation,
            prior,
            &substituted_inventory,
            testCursorBefore(23),
        ),
    );
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(
            observation,
            foreign,
            &inventory,
            testCursorBefore(23),
        ),
    );

    var foreign_cursor = testCursorBefore(23);
    foreign_cursor.source_instance_sha256 =
        device.digestV1("foreign lifecycle source instance");
    try std.testing.expectError(
        Error.SourceInstanceChanged,
        validateObservationV1(
            observation,
            prior,
            &inventory,
            foreign_cursor,
        ),
    );
    const consumed = try validateAndAdvanceObservationV1(
        observation,
        prior,
        &inventory,
        testCursorBefore(23),
    );
    try std.testing.expectError(
        Error.StaleObservation,
        validateObservationV1(
            observation,
            prior,
            &inventory,
            consumed,
        ),
    );

    const lost_prior = try testEntry(capability, 10, 3, .lost);
    const lost_inventory =
        [_]device.DeviceInventoryEntryV1{lost_prior};
    try std.testing.expectError(
        Error.InvalidObservation,
        makeTestObservationV1(
            lost_prior,
            &lost_inventory,
            1,
            .initial_membership,
            evidence,
            0,
            0,
            0,
        ),
    );
    var no_signal_input = capability;
    no_signal_input.feature_bits &=
        ~device.FeatureBitsV1.device_loss_signal;
    no_signal_input.capability_sha256 = zero_digest;
    const no_signal_capability =
        try device.sealCapabilityV1(no_signal_input);
    const no_signal_prior =
        try testEntry(no_signal_capability, 10, 3, .present);
    const no_signal_inventory =
        [_]device.DeviceInventoryEntryV1{no_signal_prior};
    try std.testing.expectError(
        Error.InvalidObservation,
        makeTestObservationV1(
            no_signal_prior,
            &no_signal_inventory,
            1,
            .inventory_absent,
            evidence,
            0,
            0,
            0,
        ),
    );
    try std.testing.expectError(
        Error.InvalidObservation,
        makeTestObservationV1(
            prior,
            &inventory,
            10,
            .removed_notification,
            zero_digest,
            0,
            0,
            0,
        ),
    );
}

test "source cursor accepts gaps and rejects consumed positions" {
    const capability = try testCapability("cursor gap gpu");
    const prior = try testEntry(capability, 10, 3, .present);
    const inventory = [_]device.DeviceInventoryEntryV1{prior};
    const evidence = device.digestV1("cursor gap evidence");
    const first = try makeTestObservationV1(
        prior,
        &inventory,
        1,
        .initial_membership,
        evidence,
        0,
        0,
        0,
    );
    const initial_cursor: SourceCursorV1 = .{
        .source_instance_sha256 = testSourceInstance(),
    };
    const after_first = try validateAndAdvanceObservationV1(
        first,
        prior,
        &inventory,
        initial_cursor,
    );
    try std.testing.expectEqual(@as(u64, 1), after_first.last_sequence);

    const after_gap = try makeTestObservationV1(
        prior,
        &inventory,
        4,
        .added_notification,
        device.digestV1("cursor gap later evidence"),
        0,
        0,
        0,
    );
    const advanced = try validateAndAdvanceObservationV1(
        after_gap,
        prior,
        &inventory,
        after_first,
    );
    try std.testing.expectEqual(@as(u64, 4), advanced.last_sequence);
    try std.testing.expectError(
        Error.StaleObservation,
        validateObservationV1(
            after_gap,
            prior,
            &inventory,
            advanced,
        ),
    );
}

test "transitions preserve identity and map only to newer non-present entries" {
    const capability = try testCapability("transition gpu");
    const prior = try testEntry(capability, 100, 12, .present);
    const inventory = [_]device.DeviceInventoryEntryV1{prior};

    const unavailable_observation = try makeTestObservationV1(
        prior,
        &inventory,
        31,
        .inventory_absent,
        device.digestV1("inventory snapshot without transition gpu"),
        0,
        0,
        0,
    );
    const unavailable = try makeSuccessorEntryV1(
        unavailable_observation,
        prior,
        &inventory,
        testCursorBefore(31),
        105,
    );
    const unavailable_receipt = try makeTransitionReceiptV1(
        unavailable_observation,
        prior,
        &inventory,
        unavailable,
        testCursorBefore(31),
    );
    try std.testing.expectEqual(
        device.InventoryStateV1.unavailable,
        unavailable.state,
    );
    try std.testing.expectEqual(prior.policy_rank, unavailable.policy_rank);
    try std.testing.expectEqualDeep(
        prior.capability,
        unavailable.capability,
    );
    try validateTransitionReceiptV1(
        unavailable_receipt,
        unavailable_observation,
        prior,
        &inventory,
        unavailable,
        testCursorBefore(31),
    );

    const lost_observation = try makeTestObservationV1(
        prior,
        &inventory,
        32,
        .removed_notification,
        device.digestV1("native removed notification"),
        0,
        0,
        0,
    );
    const lost = try makeSuccessorEntryV1(
        lost_observation,
        prior,
        &inventory,
        testCursorBefore(32),
        106,
    );
    const lost_receipt = try makeTransitionReceiptV1(
        lost_observation,
        prior,
        &inventory,
        lost,
        testCursorBefore(32),
    );
    try std.testing.expectEqual(
        device.InventoryStateV1.lost,
        lost.state,
    );
    try validateTransitionReceiptV1(
        lost_receipt,
        lost_observation,
        prior,
        &inventory,
        lost,
        testCursorBefore(32),
    );

    const synthetic_observation = try makeTestObservationV1(
        prior,
        &inventory,
        34,
        .test_injected,
        device.digestV1("explicit synthetic loss plan"),
        0,
        0,
        0,
    );
    const synthetic_lost = try makeSuccessorEntryV1(
        synthetic_observation,
        prior,
        &inventory,
        testCursorBefore(34),
        106,
    );
    const synthetic_receipt = try makeTransitionReceiptV1(
        synthetic_observation,
        prior,
        &inventory,
        synthetic_lost,
        testCursorBefore(34),
    );
    try std.testing.expectEqual(
        EvidenceClassV1.synthetic,
        synthetic_receipt.evidence_class,
    );
    try std.testing.expect(!device.digestEqual(
        lost_receipt.receipt_sha256,
        synthetic_receipt.receipt_sha256,
    ));

    const present_observation = try makeTestObservationV1(
        prior,
        &inventory,
        33,
        .initial_membership,
        device.digestV1("initial membership evidence"),
        0,
        0,
        0,
    );
    try std.testing.expectError(
        Error.InvalidTransitionReceipt,
        makeSuccessorEntryV1(
            present_observation,
            prior,
            &inventory,
            testCursorBefore(33),
            107,
        ),
    );
    try std.testing.expectError(
        Error.InvalidTransitionReceipt,
        makeSuccessorEntryV1(
            lost_observation,
            prior,
            &inventory,
            testCursorBefore(32),
            prior.discovery_epoch,
        ),
    );
}

test "transition validation rejects replay mutation and every substitution" {
    const capability = try testCapability("receipt primary gpu");
    const sibling_capability =
        try testCapability("receipt sibling gpu");
    const foreign_capability =
        try testCapability("receipt foreign gpu");
    const prior = try testEntry(capability, 70, 9, .present);
    const sibling =
        try testEntry(sibling_capability, 71, 1, .present);
    const foreign =
        try testEntry(foreign_capability, 70, 9, .present);
    const inventory =
        [_]device.DeviceInventoryEntryV1{ prior, sibling };
    const observation = try makeTestObservationV1(
        prior,
        &inventory,
        44,
        .removed_notification,
        device.digestV1("receipt native removal evidence"),
        0,
        0,
        0,
    );
    const successor = try makeSuccessorEntryV1(
        observation,
        prior,
        &inventory,
        testCursorBefore(44),
        80,
    );
    const receipt = try makeTransitionReceiptV1(
        observation,
        prior,
        &inventory,
        successor,
        testCursorBefore(44),
    );

    try std.testing.expectError(
        Error.StaleObservation,
        validateTransitionReceiptV1(
            receipt,
            observation,
            prior,
            &inventory,
            successor,
            testCursorAt(44),
        ),
    );

    var mutated = receipt;
    mutated.successor_discovery_epoch += 1;
    try std.testing.expectError(
        Error.InvalidTransitionReceipt,
        validateTransitionReceiptV1(
            mutated,
            observation,
            prior,
            &inventory,
            successor,
            testCursorBefore(44),
        ),
    );

    var rehashed_source = receipt;
    rehashed_source.source = .test_injected;
    rehashed_source.evidence_class = .synthetic;
    rehashReceipt(&rehashed_source);
    try std.testing.expectError(
        Error.InvalidTransitionReceipt,
        validateTransitionReceiptV1(
            rehashed_source,
            observation,
            prior,
            &inventory,
            successor,
            testCursorBefore(44),
        ),
    );

    const alternate_successor = try testEntry(
        capability,
        81,
        prior.policy_rank,
        .lost,
    );
    try std.testing.expectError(
        Error.InvalidTransitionReceipt,
        validateTransitionReceiptV1(
            receipt,
            observation,
            prior,
            &inventory,
            alternate_successor,
            testCursorBefore(44),
        ),
    );

    const wrong_state = try testEntry(
        capability,
        80,
        prior.policy_rank,
        .unavailable,
    );
    try std.testing.expectError(
        Error.InvalidTransitionReceipt,
        makeTransitionReceiptV1(
            observation,
            prior,
            &inventory,
            wrong_state,
            testCursorBefore(44),
        ),
    );

    const wrong_rank = try testEntry(
        capability,
        80,
        prior.policy_rank + 1,
        .lost,
    );
    try std.testing.expectError(
        Error.InvalidTransitionReceipt,
        makeTransitionReceiptV1(
            observation,
            prior,
            &inventory,
            wrong_rank,
            testCursorBefore(44),
        ),
    );

    const wrong_capability = try testEntry(
        foreign_capability,
        80,
        prior.policy_rank,
        .lost,
    );
    try std.testing.expectError(
        Error.InvalidTransitionReceipt,
        makeTransitionReceiptV1(
            observation,
            prior,
            &inventory,
            wrong_capability,
            testCursorBefore(44),
        ),
    );

    const substituted_inventory =
        [_]device.DeviceInventoryEntryV1{ prior, foreign };
    try std.testing.expectError(
        Error.InvalidObservation,
        validateTransitionReceiptV1(
            receipt,
            observation,
            prior,
            &substituted_inventory,
            successor,
            testCursorBefore(44),
        ),
    );

    const substituted_observation = try makeTestObservationV1(
        prior,
        &inventory,
        44,
        .test_injected,
        device.digestV1("foreign synthetic loss"),
        0,
        0,
        0,
    );
    try std.testing.expectError(
        Error.InvalidTransitionReceipt,
        validateTransitionReceiptV1(
            receipt,
            substituted_observation,
            prior,
            &inventory,
            successor,
            testCursorBefore(44),
        ),
    );
}

test "lost successor is excluded and requires a fresh alternate selection" {
    const primary_capability =
        try testCapability("selection primary gpu");
    const alternate_capability =
        try testCapability("selection alternate gpu");
    const primary =
        try testEntry(primary_capability, 90, 0, .present);
    const alternate =
        try testEntry(alternate_capability, 90, 1, .present);
    const prior_inventory =
        [_]device.DeviceInventoryEntryV1{ primary, alternate };
    const profile =
        device.OperationProfileBitsV1.matvec_int4_f32_bounded;
    const requirement = try device.sealRequirementV1(.{
        .plan_sha256 = device.digestV1(
            "lifecycle alternate-selection plan",
        ),
        .required_device_class = .accelerator,
        .required_operation_profile_bits = profile,
        .required_operator_bits = device.profileOperatorBitsV1(profile),
        .required_element_type_bits = device.profileElementTypeBitsV1(profile),
        .required_numerical_policy_bits = device.profileNumericalPolicyBitsV1(profile),
        .required_feature_bits = device.FeatureBitsV1.device_loss_signal,
        .largest_single_allocation_bytes = 4096,
        .total_device_bytes = 8192,
        .queue_slots = 1,
        .fallback_policy = .forbidden,
    });
    const original = try device.selectDeviceV1(
        requirement,
        &prior_inventory,
    );
    try std.testing.expect(device.digestEqual(
        original.receipt.selected_entry_sha256,
        primary.entry_sha256,
    ));

    const observation = try makeTestObservationV1(
        primary,
        &prior_inventory,
        71,
        .removed_notification,
        device.digestV1("native primary removal evidence"),
        0,
        0,
        0,
    );
    const lost = try makeSuccessorEntryV1(
        observation,
        primary,
        &prior_inventory,
        testCursorBefore(71),
        91,
    );
    const receipt = try makeTransitionReceiptV1(
        observation,
        primary,
        &prior_inventory,
        lost,
        testCursorBefore(71),
    );
    try validateTransitionReceiptV1(
        receipt,
        observation,
        primary,
        &prior_inventory,
        lost,
        testCursorBefore(71),
    );

    const refreshed_inventory =
        [_]device.DeviceInventoryEntryV1{ lost, alternate };
    const fresh = try device.selectDeviceV1(
        requirement,
        &refreshed_inventory,
    );
    try std.testing.expect(device.digestEqual(
        fresh.receipt.selected_entry_sha256,
        alternate.entry_sha256,
    ));
    try std.testing.expect(!device.digestEqual(
        original.receipt.inventory_sha256,
        fresh.receipt.inventory_sha256,
    ));
    try std.testing.expectError(
        device.Error.InvalidSelectionReceipt,
        device.validateSelectionReceiptV1(
            original.receipt,
            requirement,
            &refreshed_inventory,
        ),
    );
}
