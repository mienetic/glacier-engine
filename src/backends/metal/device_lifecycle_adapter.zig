//! Metal evidence adapter for the portable device-lifecycle contract.
//!
//! A live backend is the authority for the native source coordinate. Callers
//! cannot choose an observation sequence: the adapter derives a source
//! instance from the retained device identity and observer generation, uses
//! the native event sequence, and atomically consumes that exact snapshot.
//! The resulting hashes provide composition and integrity binding; they are
//! not device attestation or proof that a physical removal was reproduced.

const std = @import("std");
const core = @import("core");
const metal = @import("backend.zig");
const native = @import("native_observer.zig");

pub const lifecycle = core.device_lifecycle_contract;
pub const device = core.device_capability_contract;
pub const Digest = lifecycle.Digest;

pub const Error = lifecycle.Error || metal.MetalError || error{
    InvalidDevice,
};

pub const ClaimedObservationV1 = struct {
    observation: lifecycle.ObservationV1,
    advanced_cursor: lifecycle.SourceCursorV1,
};

const lifecycle_snapshot_evidence_domain =
    "glacier-metal-device-lifecycle-snapshot-evidence-v1\x00";
const lifecycle_source_instance_domain =
    "glacier-metal-device-lifecycle-source-instance-v1\x00";

/// Hash every validated native snapshot field using canonical little-endian
/// projections. Native padding and process pointers never enter the root.
pub fn metalDeviceLifecycleSnapshotEvidenceRootV1(
    snapshot: metal.MetalDeviceLifecycleSnapshot,
) Error!Digest {
    try metal.validateMetalDeviceLifecycleSnapshot(snapshot);
    return lifecycleSnapshotEvidenceRootUncheckedV1(snapshot);
}

/// Bind one observer generation to the immutable identity and placement of
/// the exact device captured while the backend was accepting work.
pub fn metalDeviceLifecycleSourceInstanceRootV1(
    info: metal.MetalDeviceInfo,
    source_identity: metal.MetalDeviceLifecycleSourceIdentity,
    snapshot: metal.MetalDeviceLifecycleSnapshot,
) Error!Digest {
    if (!validMetalDeviceInfo(info))
        return Error.InvalidDevice;
    try metal.validateMetalDeviceLifecycleSourceIdentity(
        source_identity,
    );
    try metal.validateMetalDeviceLifecycleSnapshot(snapshot);
    if (snapshot.registry_id != info.registry_id or
        source_identity.registry_id != snapshot.registry_id or
        source_identity.observer_generation !=
            snapshot.observer_generation)
        return Error.InvalidDevice;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(lifecycle_source_instance_domain);
    hashU64(&hash, snapshot.registry_id);
    hashU64(&hash, snapshot.observer_generation);
    for (source_identity.context_nonce) |word|
        hashU64(&hash, word);
    hash.update(&native.deviceIdentityV1(info));
    hash.update(&native.placementIdentityV1(info));
    return finish(&hash);
}

/// Adopt and consume a freshly installed Metal lifecycle source. Adoption is
/// allowed only for exact initial membership at native sequence one. It does
/// not authorize reset, recovery, migration, or quarantine clearing.
pub fn observeInitialLifecycleV1(
    backend: *metal.MetalBackend,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
) Error!ClaimedObservationV1 {
    const info = backend.initialDeviceInfo();
    const source_identity =
        backend.initialDeviceLifecycleSourceIdentity();
    const snapshot = try backend.deviceLifecycleSnapshot();
    const cursor = try initialSourceCursorV1(
        info,
        source_identity,
        snapshot,
    );
    return claimSnapshotV1(
        backend,
        info,
        source_identity,
        snapshot,
        prior_entry,
        prior_inventory,
        cursor,
    );
}

/// Consume the exact current native source coordinate against the caller's
/// pre-consumption cursor. Sequence gaps are valid for this level-triggered
/// source, but replay and observer-generation changes fail closed.
pub fn observeCurrentLifecycleV1(
    backend: *metal.MetalBackend,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    source_cursor: lifecycle.SourceCursorV1,
) Error!ClaimedObservationV1 {
    const info = backend.initialDeviceInfo();
    const source_identity =
        backend.initialDeviceLifecycleSourceIdentity();
    const snapshot = try backend.deviceLifecycleSnapshot();
    return claimSnapshotV1(
        backend,
        info,
        source_identity,
        snapshot,
        prior_entry,
        prior_inventory,
        source_cursor,
    );
}

fn claimSnapshotV1(
    backend: *metal.MetalBackend,
    info: metal.MetalDeviceInfo,
    source_identity: metal.MetalDeviceLifecycleSourceIdentity,
    snapshot: metal.MetalDeviceLifecycleSnapshot,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    source_cursor: lifecycle.SourceCursorV1,
) Error!ClaimedObservationV1 {
    const claim = try projectLifecycleSnapshotV1(
        info,
        source_identity,
        snapshot,
        prior_entry,
        prior_inventory,
        source_cursor,
    );
    const consumed_sequence =
        backend.consumeDeviceLifecycleSnapshot(snapshot) catch |err|
            switch (err) {
                error.StaleLifecycleSnapshot => return error.StaleObservation,
                error.LifecycleGenerationMismatch => return error.SourceInstanceChanged,
                else => return err,
            };
    if (consumed_sequence != snapshot.event_sequence)
        return Error.InvalidObservation;
    return claim;
}

fn projectLifecycleSnapshotV1(
    info: metal.MetalDeviceInfo,
    source_identity: metal.MetalDeviceLifecycleSourceIdentity,
    snapshot: metal.MetalDeviceLifecycleSnapshot,
    prior_entry: device.DeviceInventoryEntryV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    source_cursor: lifecycle.SourceCursorV1,
) Error!ClaimedObservationV1 {
    try validatePriorMetalBindingV1(info, prior_entry);
    try metal.validateMetalDeviceLifecycleSnapshot(snapshot);
    if (snapshot.registry_id != info.registry_id)
        return Error.InvalidDevice;

    const source_instance_sha256 =
        try metalDeviceLifecycleSourceInstanceRootV1(
            info,
            source_identity,
            snapshot,
        );
    const projection = try projectNativeSourceV1(snapshot);
    const evidence_sha256 =
        try metalDeviceLifecycleSnapshotEvidenceRootV1(snapshot);
    const observation = try lifecycle.makeObservationV1(
        prior_entry,
        prior_inventory,
        source_instance_sha256,
        snapshot.event_sequence,
        projection.source,
        evidence_sha256,
        projection.command_status,
        projection.error_domain_kind,
        projection.error_code_bits,
    );
    return .{
        .observation = observation,
        .advanced_cursor = try lifecycle.validateAndAdvanceObservationV1(
            observation,
            prior_entry,
            prior_inventory,
            source_cursor,
        ),
    };
}

fn initialSourceCursorV1(
    info: metal.MetalDeviceInfo,
    source_identity: metal.MetalDeviceLifecycleSourceIdentity,
    snapshot: metal.MetalDeviceLifecycleSnapshot,
) Error!lifecycle.SourceCursorV1 {
    try metal.validateMetalDeviceLifecycleSnapshot(snapshot);
    if (snapshot.event_sequence != 1 or
        snapshot.event_kind != .initial_membership or
        snapshot.source_bits !=
            metal.MetalDeviceLifecycleSourceBits.initial_membership)
        return Error.InvalidObservation;
    return .{
        .source_instance_sha256 = try metalDeviceLifecycleSourceInstanceRootV1(
            info,
            source_identity,
            snapshot,
        ),
        .last_sequence = 0,
    };
}

const NativeObservationProjectionV1 = struct {
    source: lifecycle.ObservationSourceV1,
    command_status: u64 = 0,
    error_domain_kind: u64 = 0,
    error_code_bits: u64 = 0,
};

fn projectNativeSourceV1(
    snapshot: metal.MetalDeviceLifecycleSnapshot,
) Error!NativeObservationProjectionV1 {
    return switch (try metal.effectiveMetalDeviceLifecycleEventKind(snapshot)) {
        .initial_membership => .{
            .source = .initial_membership,
        },
        .added => .{
            .source = .added_notification,
        },
        .removal_requested => .{
            .source = .removal_requested_notification,
        },
        .removed => .{
            .source = .removed_notification,
        },
        .command_buffer_removed => .{
            .source = .command_buffer_device_removed,
            .command_status = metal.error_command_buffer_status,
            .error_domain_kind = @intFromEnum(
                metal.MetalCommandErrorDomainKind.command_buffer,
            ),
            .error_code_bits = @bitCast(
                metal.device_removed_command_buffer_error,
            ),
        },
        _ => Error.InvalidObservation,
    };
}

fn validatePriorMetalBindingV1(
    info: metal.MetalDeviceInfo,
    prior_entry: device.DeviceInventoryEntryV1,
) Error!void {
    if (!validMetalDeviceInfo(info))
        return Error.InvalidDevice;
    device.validateInventoryEntryV1(prior_entry) catch
        return Error.InvalidDevice;
    const capability = prior_entry.capability;
    if (prior_entry.state != .present or
        capability.backend_kind != .metal or
        capability.device_class != .accelerator or
        capability.feature_bits &
            device.FeatureBitsV1.device_loss_signal == 0 or
        !device.digestEqual(
            capability.device_sha256,
            native.deviceIdentityV1(info),
        ) or
        !device.digestEqual(
            capability.placement_sha256,
            native.placementIdentityV1(info),
        ))
        return Error.InvalidDevice;
}

fn validMetalDeviceInfo(info: metal.MetalDeviceInfo) bool {
    return info.abi_version == metal.device_info_abi and
        info.registry_id != 0 and
        info.max_threads_x != 0 and
        info.max_threads_y != 0 and
        info.max_threads_z != 0 and
        info.low_power <= 1 and
        info.headless <= 1 and
        info.removable <= 1 and
        info.unified_memory <= 1;
}

fn lifecycleSnapshotEvidenceRootUncheckedV1(
    snapshot: metal.MetalDeviceLifecycleSnapshot,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(lifecycle_snapshot_evidence_domain);
    hashU64(&hash, snapshot.abi_version);
    hashU64(&hash, snapshot.registry_id);
    hashU64(&hash, snapshot.observer_generation);
    hashU64(&hash, snapshot.event_sequence);
    hashU64(&hash, @intFromEnum(snapshot.event_kind));
    hashU64(&hash, snapshot.present);
    hashU64(&hash, snapshot.removal_requested);
    hashU64(&hash, snapshot.removed);
    hashU64(&hash, snapshot.observer_active);
    hashU64(&hash, snapshot.initial_membership);
    hashU64(&hash, snapshot.observer_fault);
    hashU64(&hash, snapshot.source_bits);
    return finish(&hash);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn testMetalDeviceInfo() metal.MetalDeviceInfo {
    return .{
        .abi_version = metal.device_info_abi,
        .registry_id = 0x1122_3344_5566_7788,
        .current_allocated_size = 48_000,
        .recommended_max_working_set_size = 8 << 30,
        .location = 1,
        .location_number = 2,
        .max_threads_x = 1024,
        .max_threads_y = 1024,
        .max_threads_z = 64,
        .low_power = 1,
        .headless = 0,
        .removable = 0,
        .unified_memory = 1,
    };
}

fn testCapabilityV1(
    info: metal.MetalDeviceInfo,
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
        .max_single_allocation_bytes = 1 << 30,
        .max_total_device_bytes = 8 << 30,
        .max_queue_slots = 1,
        .backend_sha256 = device.digestV1(
            "Metal lifecycle adapter test backend",
        ),
        .device_sha256 = native.deviceIdentityV1(info),
        .driver_sha256 = device.zero_digest,
        .placement_sha256 = native.placementIdentityV1(info),
    });
}

fn testInventoryEntryV1(
    capability: device.DeviceCapabilityV1,
) !device.DeviceInventoryEntryV1 {
    return device.sealInventoryEntryV1(.{
        .discovery_epoch = 17,
        .policy_rank = 3,
        .state = .present,
        .capability = capability,
    });
}

fn testLifecycleSnapshot(
    event_kind: metal.MetalDeviceLifecycleEventKind,
) metal.MetalDeviceLifecycleSnapshot {
    const source_bit: u32 = switch (event_kind) {
        .initial_membership => metal.MetalDeviceLifecycleSourceBits.initial_membership,
        .added => metal.MetalDeviceLifecycleSourceBits.added,
        .removal_requested => metal.MetalDeviceLifecycleSourceBits.removal_requested,
        .removed => metal.MetalDeviceLifecycleSourceBits.removed,
        .command_buffer_removed => metal.MetalDeviceLifecycleSourceBits.command_buffer_removed,
        _ => 0,
    };
    var result: metal.MetalDeviceLifecycleSnapshot = .{
        .registry_id = testMetalDeviceInfo().registry_id,
        .observer_generation = 9,
        .event_sequence = @intFromEnum(event_kind),
        .event_kind = event_kind,
        .observer_active = 1,
        .initial_membership = 1,
        .source_bits = metal.MetalDeviceLifecycleSourceBits.initial_membership |
            source_bit,
    };
    switch (event_kind) {
        .initial_membership, .added => result.present = 1,
        .removal_requested => result.removal_requested = 1,
        .removed, .command_buffer_removed => {
            result.removal_requested = 1;
            result.removed = 1;
        },
        _ => {},
    }
    return result;
}

fn testSourceIdentity(
    snapshot: metal.MetalDeviceLifecycleSnapshot,
) metal.MetalDeviceLifecycleSourceIdentity {
    return .{
        .registry_id = snapshot.registry_id,
        .observer_generation = snapshot.observer_generation,
        .context_nonce = .{
            0x0102_0304_0506_0708,
            0x1112_1314_1516_1718,
            0x2122_2324_2526_2728,
            0x3132_3334_3536_3738,
        },
    };
}

fn cursorBeforeSnapshot(
    info: metal.MetalDeviceInfo,
    snapshot: metal.MetalDeviceLifecycleSnapshot,
) !lifecycle.SourceCursorV1 {
    return .{
        .source_instance_sha256 = try metalDeviceLifecycleSourceInstanceRootV1(
            info,
            testSourceIdentity(snapshot),
            snapshot,
        ),
        .last_sequence = snapshot.event_sequence - 1,
    };
}

fn expectDigestChanged(
    baseline: Digest,
    mutated: Digest,
) !void {
    try std.testing.expect(!device.digestEqual(
        baseline,
        mutated,
    ));
}

test "Metal lifecycle snapshot evidence binds every field" {
    const snapshot = testLifecycleSnapshot(.initial_membership);
    const baseline =
        try metalDeviceLifecycleSnapshotEvidenceRootV1(snapshot);

    var mutated = snapshot;
    mutated.abi_version +%= 1;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.registry_id +%= 1;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.observer_generation +%= 1;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.event_sequence +%= 1;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.event_kind = .added;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.present = 0;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.removal_requested = 1;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.removed = 1;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.observer_active = 0;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.initial_membership = 0;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.observer_fault = 1;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    mutated = snapshot;
    mutated.source_bits = 0;
    try expectDigestChanged(
        baseline,
        lifecycleSnapshotEvidenceRootUncheckedV1(mutated),
    );
    try std.testing.expectError(
        metal.MetalError.InvalidObservation,
        metalDeviceLifecycleSnapshotEvidenceRootV1(mutated),
    );
}

test "Metal lifecycle source instance binds stable device and generation" {
    const info = testMetalDeviceInfo();
    const snapshot = testLifecycleSnapshot(.initial_membership);
    const source_identity = testSourceIdentity(snapshot);
    const baseline = try metalDeviceLifecycleSourceInstanceRootV1(
        info,
        source_identity,
        snapshot,
    );

    var dynamic_info = info;
    dynamic_info.current_allocated_size +%= 4096;
    try std.testing.expectEqualSlices(
        u8,
        &baseline,
        &(try metalDeviceLifecycleSourceInstanceRootV1(
            dynamic_info,
            source_identity,
            snapshot,
        )),
    );

    var changed_identity = source_identity;
    changed_identity.context_nonce[2] +%= 1;
    try expectDigestChanged(
        baseline,
        try metalDeviceLifecycleSourceInstanceRootV1(
            info,
            changed_identity,
            snapshot,
        ),
    );

    var changed_info = info;
    changed_info.max_threads_x +%= 1;
    try expectDigestChanged(
        baseline,
        try metalDeviceLifecycleSourceInstanceRootV1(
            changed_info,
            source_identity,
            snapshot,
        ),
    );
    changed_info = info;
    changed_info.location_number +%= 1;
    try expectDigestChanged(
        baseline,
        try metalDeviceLifecycleSourceInstanceRootV1(
            changed_info,
            source_identity,
            snapshot,
        ),
    );
    var changed_snapshot = snapshot;
    changed_snapshot.observer_generation +%= 1;
    changed_identity = source_identity;
    changed_identity.observer_generation =
        changed_snapshot.observer_generation;
    try expectDigestChanged(
        baseline,
        try metalDeviceLifecycleSourceInstanceRootV1(
            info,
            changed_identity,
            changed_snapshot,
        ),
    );
    changed_info = info;
    changed_info.registry_id +%= 1;
    changed_snapshot = snapshot;
    changed_snapshot.registry_id = changed_info.registry_id;
    changed_identity = source_identity;
    changed_identity.registry_id = changed_info.registry_id;
    try expectDigestChanged(
        baseline,
        try metalDeviceLifecycleSourceInstanceRootV1(
            changed_info,
            changed_identity,
            changed_snapshot,
        ),
    );

    changed_identity = source_identity;
    changed_identity.observer_generation +%= 1;
    try std.testing.expectError(
        Error.InvalidDevice,
        metalDeviceLifecycleSourceInstanceRootV1(
            info,
            changed_identity,
            snapshot,
        ),
    );
}

test "Metal sticky lifecycle sources map to monotone observations" {
    const info = testMetalDeviceInfo();
    const capability = try testCapabilityV1(info);
    const prior = try testInventoryEntryV1(capability);
    const inventory = [_]device.DeviceInventoryEntryV1{prior};
    const Case = struct {
        event_kind: metal.MetalDeviceLifecycleEventKind,
        source: lifecycle.ObservationSourceV1,
        state: device.InventoryStateV1,
        command_status: u64 = 0,
        error_domain_kind: u64 = 0,
        error_code_bits: u64 = 0,
    };
    const cases = [_]Case{
        .{
            .event_kind = .initial_membership,
            .source = .initial_membership,
            .state = .present,
        },
        .{
            .event_kind = .added,
            .source = .added_notification,
            .state = .present,
        },
        .{
            .event_kind = .removal_requested,
            .source = .removal_requested_notification,
            .state = .unavailable,
        },
        .{
            .event_kind = .removed,
            .source = .removed_notification,
            .state = .lost,
        },
        .{
            .event_kind = .command_buffer_removed,
            .source = .command_buffer_device_removed,
            .state = .lost,
            .command_status = lifecycle.command_buffer_status_error,
            .error_domain_kind = lifecycle.command_buffer_error_domain,
            .error_code_bits = lifecycle.command_buffer_device_removed_error,
        },
    };
    for (cases) |case| {
        const snapshot = testLifecycleSnapshot(case.event_kind);
        const claim = try projectLifecycleSnapshotV1(
            info,
            testSourceIdentity(snapshot),
            snapshot,
            prior,
            &inventory,
            try cursorBeforeSnapshot(info, snapshot),
        );
        try std.testing.expectEqual(
            case.source,
            claim.observation.source,
        );
        try std.testing.expectEqual(
            case.state,
            claim.observation.observed_state,
        );
        try std.testing.expectEqual(
            case.command_status,
            claim.observation.native_command_status,
        );
        try std.testing.expectEqual(
            case.error_domain_kind,
            claim.observation.native_error_domain_kind,
        );
        try std.testing.expectEqual(
            case.error_code_bits,
            claim.observation.native_error_code_bits,
        );
    }

    var sticky_loss =
        testLifecycleSnapshot(.command_buffer_removed);
    sticky_loss.event_sequence = 8;
    sticky_loss.event_kind = .removal_requested;
    sticky_loss.source_bits |=
        metal.MetalDeviceLifecycleSourceBits.removal_requested;
    const sticky_claim = try projectLifecycleSnapshotV1(
        info,
        testSourceIdentity(sticky_loss),
        sticky_loss,
        prior,
        &inventory,
        try cursorBeforeSnapshot(info, sticky_loss),
    );
    try std.testing.expectEqual(
        lifecycle.ObservationSourceV1.command_buffer_device_removed,
        sticky_claim.observation.source,
    );
    try std.testing.expectEqual(
        device.InventoryStateV1.lost,
        sticky_claim.observation.observed_state,
    );
}

test "Metal lifecycle cursor accepts gaps and rejects replay or reset" {
    const info = testMetalDeviceInfo();
    const capability = try testCapabilityV1(info);
    const prior = try testInventoryEntryV1(capability);
    const inventory = [_]device.DeviceInventoryEntryV1{prior};
    const snapshot = testLifecycleSnapshot(.removed);
    const source_identity = testSourceIdentity(snapshot);
    const source_instance =
        try metalDeviceLifecycleSourceInstanceRootV1(
            info,
            source_identity,
            snapshot,
        );
    const claim = try projectLifecycleSnapshotV1(
        info,
        source_identity,
        snapshot,
        prior,
        &inventory,
        .{
            .source_instance_sha256 = source_instance,
            .last_sequence = 1,
        },
    );
    try std.testing.expectEqual(
        snapshot.event_sequence,
        claim.advanced_cursor.last_sequence,
    );
    try std.testing.expectError(
        lifecycle.Error.StaleObservation,
        projectLifecycleSnapshotV1(
            info,
            source_identity,
            snapshot,
            prior,
            &inventory,
            claim.advanced_cursor,
        ),
    );
    var foreign_cursor = claim.advanced_cursor;
    foreign_cursor.source_instance_sha256[0] ^= 1;
    foreign_cursor.last_sequence = 0;
    try std.testing.expectError(
        lifecycle.Error.SourceInstanceChanged,
        projectLifecycleSnapshotV1(
            info,
            source_identity,
            snapshot,
            prior,
            &inventory,
            foreign_cursor,
        ),
    );
}

test "Metal lifecycle adapter rejects foreign capability bindings" {
    const info = testMetalDeviceInfo();
    const capability = try testCapabilityV1(info);
    const prior = try testInventoryEntryV1(capability);
    const snapshot = testLifecycleSnapshot(.initial_membership);
    const source_identity = testSourceIdentity(snapshot);
    const cursor = try cursorBeforeSnapshot(info, snapshot);

    var foreign_input = capability;
    foreign_input.capability_sha256 = device.zero_digest;
    foreign_input.backend_kind = .cpu;
    foreign_input.device_class = .cpu;
    const foreign_backend = try testInventoryEntryV1(
        try device.sealCapabilityV1(foreign_input),
    );
    var inventory =
        [_]device.DeviceInventoryEntryV1{foreign_backend};
    try std.testing.expectError(
        Error.InvalidDevice,
        projectLifecycleSnapshotV1(
            info,
            source_identity,
            snapshot,
            foreign_backend,
            &inventory,
            cursor,
        ),
    );

    foreign_input = capability;
    foreign_input.capability_sha256 = device.zero_digest;
    foreign_input.device_sha256[0] ^= 1;
    const foreign_device = try testInventoryEntryV1(
        try device.sealCapabilityV1(foreign_input),
    );
    inventory[0] = foreign_device;
    try std.testing.expectError(
        Error.InvalidDevice,
        projectLifecycleSnapshotV1(
            info,
            source_identity,
            snapshot,
            foreign_device,
            &inventory,
            cursor,
        ),
    );

    foreign_input = capability;
    foreign_input.capability_sha256 = device.zero_digest;
    foreign_input.placement_sha256[0] ^= 1;
    const foreign_placement = try testInventoryEntryV1(
        try device.sealCapabilityV1(foreign_input),
    );
    inventory[0] = foreign_placement;
    try std.testing.expectError(
        Error.InvalidDevice,
        projectLifecycleSnapshotV1(
            info,
            source_identity,
            snapshot,
            foreign_placement,
            &inventory,
            cursor,
        ),
    );

    foreign_input = capability;
    foreign_input.capability_sha256 = device.zero_digest;
    foreign_input.feature_bits &=
        ~device.FeatureBitsV1.device_loss_signal;
    const no_loss_signal = try testInventoryEntryV1(
        try device.sealCapabilityV1(foreign_input),
    );
    inventory[0] = no_loss_signal;
    try std.testing.expectError(
        Error.InvalidDevice,
        projectLifecycleSnapshotV1(
            info,
            source_identity,
            snapshot,
            no_loss_signal,
            &inventory,
            cursor,
        ),
    );

    var wrong_registry = snapshot;
    wrong_registry.registry_id +%= 1;
    const prior_inventory =
        [_]device.DeviceInventoryEntryV1{prior};
    try std.testing.expectError(
        Error.InvalidDevice,
        projectLifecycleSnapshotV1(
            info,
            source_identity,
            wrong_registry,
            prior,
            &prior_inventory,
            cursor,
        ),
    );
}

test "Metal lifecycle source adoption requires exact initial position" {
    const info = testMetalDeviceInfo();
    const initial = testLifecycleSnapshot(.initial_membership);
    const source_identity = testSourceIdentity(initial);
    const cursor = try initialSourceCursorV1(
        info,
        source_identity,
        initial,
    );
    try std.testing.expectEqual(@as(u64, 0), cursor.last_sequence);

    var later = initial;
    later.event_sequence = 2;
    try std.testing.expectError(
        Error.InvalidObservation,
        initialSourceCursorV1(info, source_identity, later),
    );
    later = testLifecycleSnapshot(.added);
    try std.testing.expectError(
        Error.InvalidObservation,
        initialSourceCursorV1(
            info,
            testSourceIdentity(later),
            later,
        ),
    );
    later = initial;
    later.source_bits |= metal.MetalDeviceLifecycleSourceBits.added;
    later.event_kind = .added;
    try std.testing.expectError(
        Error.InvalidObservation,
        initialSourceCursorV1(
            info,
            testSourceIdentity(later),
            later,
        ),
    );
}
