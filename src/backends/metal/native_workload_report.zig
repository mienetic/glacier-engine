//! Production Metal producer for Native Workload Report V1.
//!
//! This module runs one fixed, finite INT4 matrix-vector campaign through the
//! production registered-buffer adapter.  Adapter slots and Bank pins are
//! logical ownership facts only; this producer deliberately makes no claim
//! about physical GPU parallelism, queue depth, residency, utilization, power,
//! energy, temperature, or frequency.
//!
//! `StorageV1` is caller-owned because the Metal allocation adapter, Resource
//! Bank, and LeaseTree coordinator become address-bound as soon as the first
//! interface is exposed.  Do not move or copy a storage value after calling
//! `runV1`.  On an error after native submission the storage and backend remain
//! live so a higher-level recovery authority can inspect the retained state;
//! no report is sealed and no wire is published.

const std = @import("std");
const core = @import("core");
const metal = @import("backend.zig");
const metal_allocation = @import("allocation_adapter.zig");
const native_observer = @import("native_observer.zig");

pub const native_report = core.native_workload_report;
pub const allocation = core.device_allocation_lease;
pub const lease_tree = core.device_allocation_lease_tree;
pub const device = core.device_capability_contract;
pub const resource = core.resource_bank;
pub const Digest = native_report.Digest;

pub const producer_abi: u64 = 0x4757_364d_0000_0001;
pub const in_features: usize = 64;
pub const out_features: usize = 37;
pub const group_size: usize = 8;
pub const flow_count: usize = 2;
pub const warmup_pair_count: usize = 2;
pub const measured_pair_count: usize = 8;
pub const pair_count: usize =
    warmup_pair_count + measured_pair_count;
pub const warmup_record_count: usize =
    warmup_pair_count * flow_count;
pub const measured_record_count: usize =
    measured_pair_count * flow_count;
pub const record_count: usize =
    warmup_record_count + measured_record_count;
pub const work_units_per_record: u64 =
    in_features * out_features;
pub const packed_byte_count: usize =
    (in_features * out_features + 1) / 2;
pub const scale_count: usize =
    (in_features * out_features + group_size - 1) /
    group_size;
pub const persistent_device_bytes: u64 =
    flow_count *
    (packed_byte_count +
        scale_count * @sizeOf(f32) +
        in_features * @sizeOf(f32) +
        out_features * @sizeOf(f32));
pub const maximum_abs_error: f64 = 0.00002;
pub const encoded_bytes: usize =
    native_report.minimum_encoded_bytes +
    record_count * native_report.record_wire_bytes;

comptime {
    if (record_count != 20 or work_units_per_record != 2_368 or
        persistent_device_bytes != 5_544)
        @compileError("native Metal workload geometry changed");
}

pub const RunConfigV1 = struct {
    /// Exact source/build identity supplied by the binary runner.
    build_sha256: Digest,
    /// Nonzero campaign challenge supplied by the invoking authority.
    challenge_sha256: Digest,
};

pub const StateV1 = enum {
    empty,
    running,
    failed_retained,
    complete,
};

pub const ArtifactV1 = struct {
    report: native_report.ReportV1,
    wire: []const u8,
};

const LaneV1 = struct {
    request: ?metal_allocation.MetalMatvecDispatchRequestV1 = null,
    pin: ?lease_tree.LeaseTreeDispatchPinV1 = null,
    ticket: ?metal_allocation.MetalAsyncDispatchTicketV1 = null,
};

/// All mutable campaign memory is fixed and caller-owned.  The payload and
/// oracle arrays also live here so a failure cannot leave adapter evidence
/// pointing into a returned stack frame.
pub const StorageV1 = struct {
    state: StateV1 = .empty,
    backend: ?*metal.MetalBackend = null,

    native_slots: [flow_count * 4]metal_allocation.MetalAllocationSlotV1 =
        [_]metal_allocation.MetalAllocationSlotV1{.{}} **
        (flow_count * 4),
    bank_slots: [1]resource.Slot = .{.{}},
    tree_roots: [1]resource.LeaseTreeRootSlot = .{.{}},
    tree_nodes: [flow_count * 4 + 1]resource.LeaseNodeSlot =
        [_]resource.LeaseNodeSlot{.{}} ** (flow_count * 4 + 1),
    pin_slots: [flow_count]resource.LeasePinSlotV1 =
        [_]resource.LeasePinSlotV1{.{}} ** flow_count,
    coordinator_objects: [flow_count * 4]lease_tree.CoordinatorObjectSlotV1 =
        [_]lease_tree.CoordinatorObjectSlotV1{.{}} **
        (flow_count * 4),
    coordinator_dispatches: [flow_count]lease_tree.CoordinatorDispatchSlotV1 =
        [_]lease_tree.CoordinatorDispatchSlotV1{.{}} ** flow_count,

    adapter: metal_allocation.MetalAllocationAdapterV1 = undefined,
    bank: resource.Bank = undefined,
    tree: resource.LeaseTreeV1 = undefined,
    coordinator: lease_tree.CoordinatorV1 = .{},
    parent: ?resource.Receipt = null,
    lease: ?lease_tree.LeaseTreeDeviceAllocationLeaseV1 = null,
    lanes: [flow_count]LaneV1 =
        [_]LaneV1{.{}} ** flow_count,
    publication_sequence: u64 = 0,
    session_anchor: u8 = 0,

    packed_weights: [packed_byte_count]u8 = undefined,
    scales: [scale_count]f32 = undefined,
    inputs: [flow_count][in_features]f32 = undefined,
    oracles: [flow_count][out_features]f32 = undefined,
    outputs: [flow_count][out_features]f32 = undefined,
    records: [record_count]native_report.RecordV1 = undefined,
    wire: [encoded_bytes]u8 = undefined,
};

const FixtureV1 = struct {
    inventory: [1]device.DeviceInventoryEntryV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    bindings: [flow_count]metal_allocation.MetalMatvecAllocationBindingsV1,
    entries: [flow_count * 4]allocation.AllocationEntryV1,
    manifest: allocation.AllocationManifestV1,
};

const EventClockV1 = struct {
    timer: std.time.Timer,
    sequence: u64 = 0,

    fn next(self: *EventClockV1) !native_report.EventPointV1 {
        self.sequence = std.math.add(
            u64,
            self.sequence,
            1,
        ) catch return error.EventSequenceExhausted;
        return .{
            .ns = @max(@as(u64, 1), self.timer.read()),
            .sequence = self.sequence,
        };
    }
};

const PendingRecordV1 = struct {
    ordinal: u32,
    cohort: native_report.CohortV1,
    flow_id: u32,
    host: native_report.HostEventsV1 = .{
        .presence_mask = native_report.event_presence_all,
    },
    request: metal_allocation.MetalMatvecDispatchRequestV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    ticket: metal_allocation.MetalAsyncDispatchTicketV1,
    result: ?metal_allocation.MetalLeaseTreeDispatchResultV1 = null,
    completion: ?lease_tree.LeaseTreeDispatchCompletionV1 = null,
    maximum_abs_error: f64 = 0,
    correctness: native_report.CorrectnessV1 = .not_applicable,
    bank_used_before: u64 = 0,
};

/// Run the fixed production-native campaign and return an encoded report only
/// after terminal zero ownership has been proven.
pub fn runV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    config: RunConfigV1,
) !ArtifactV1 {
    if (storage.state != .empty) return error.StorageAlreadyBound;
    if (digestIsZero(config.build_sha256) or
        digestIsZero(config.challenge_sha256))
        return error.InvalidIdentity;
    storage.state = .running;
    storage.backend = backend;
    errdefer storage.state = .failed_retained;

    return runBoundV1(storage, backend, config);
}

pub const run = runV1;

fn runBoundV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    config: RunConfigV1,
) !ArtifactV1 {
    if (backend.liveBufferCount() != 0 or
        try backend.nativeLiveBufferCount() != 0 or
        try backend.nativeLiveCommandCount() != 0 or
        backend.compatibilityUnresolvedSubmission() != null)
        return error.DirtyMetalBackend;
    try backend.requireInt4MatvecSupport();
    const initial_lifecycle =
        try backend.deviceLifecycleSnapshot();
    try validateLifecycleSnapshot(
        backend,
        initial_lifecycle,
        initial_lifecycle,
    );
    const initial_device = backend.initialDeviceInfo();
    if (initial_device.registry_id !=
        initial_lifecycle.registry_id)
        return error.InvalidMetalIdentity;
    const retirement_before =
        try backend.dispatchRetirementTelemetry();
    try metal.validateMetalDispatchRetirementTelemetryV1(
        retirement_before,
    );
    const completed_dispatches_before =
        backend.completedDispatchCount();

    fillPayloadV1(storage);
    computeOraclesV1(storage);
    const logical_cpu_count: u64 = std.math.cast(
        u64,
        try std.Thread.getCpuCount(),
    ) orelse return error.InvalidHostIdentity;
    if (logical_cpu_count == 0)
        return error.InvalidHostIdentity;

    const scenario = try makeScenarioV1(
        storage,
        initial_device,
        logical_cpu_count,
        config,
    );
    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            backend,
            0x5736_4d45_5441,
            0,
            1 * 1024 * 1024,
        );
    storage.adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            backend,
            inventory_entry,
            0x5736_4144_4150,
            0x5736_4d65_7461_6c41,
            &storage.native_slots,
        );
    const fixture = try makeFixtureV1(
        &storage.adapter,
        inventory_entry,
        scenario.profile_sha256,
    );
    if (fixture.manifest.total_charged_bytes !=
        persistent_device_bytes or
        fixture.requirement.queue_slots != flow_count)
        return error.InvalidCampaignFixture;

    storage.bank = try resource.Bank.initWithLeaseTreePinStorage(
        &storage.bank_slots,
        &storage.tree_roots,
        &storage.tree_nodes,
        &storage.pin_slots,
        .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = persistent_device_bytes,
            .queue_slots = flow_count,
        },
        0x5736_4241_4e4b,
    );
    const parent = try storage.bank.commit(
        try storage.bank.reserve(
            0x5736_5041_5245,
            .{
                .capsule_bytes = 64,
                .queue_slots = flow_count,
            },
        ),
    );
    storage.parent = parent;
    const opened = try storage.bank.openLeaseTree(
        parent,
        0x5736_5452_4545,
        0x5736_4155_5448,
        .{ .device_bytes = persistent_device_bytes },
    );
    const scoped = try storage.bank.openLeaseScope(
        opened,
        0x5736_5343_4f50,
        0x5736_5445_4e41,
        .{ .device_bytes = persistent_device_bytes },
    );
    storage.tree = scoped.tree;
    const session_id = @intFromPtr(&storage.session_anchor);
    if (session_id == 0) return error.InvalidSessionIdentity;
    try storage.bank.bindPublicationSessionWithLeaseTree(
        storage.tree,
        0x5736_5251_4550,
        session_id,
    );
    storage.coordinator = .{};
    try storage.coordinator.initWithDispatchStorage(
        0x5736_434f_4f52,
        &storage.bank,
        &storage.tree,
        scoped.scope,
        0x5736_5251_4550,
        session_id,
        &storage.publication_sequence,
        &storage.coordinator_objects,
        &storage.coordinator_dispatches,
    );
    const allocation_request = try allocation.makeRequestV1(
        0x5736_5251_4550,
        digestV1("glacier-w6-metal-campaign-owner-v1\x00"),
        storage.adapter.authority,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const admission = try storage.coordinator.admit(
        storage.adapter.interface(),
        allocation_request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const materialized = try storage.coordinator.materialize(
        admission,
        storage.adapter.interface(),
        .{},
    );
    const campaign_lease = switch (materialized) {
        .active => |value| value,
        .terminal, .recovery_required => return error.NativeAllocationNotMaterialized,
    };
    storage.lease = campaign_lease;
    if (campaign_lease.allocation_count != flow_count * 4 or
        campaign_lease.materialized_bytes !=
            persistent_device_bytes or
        backend.liveBufferCount() != flow_count * 4 or
        try backend.nativeLiveBufferCount() != flow_count * 4)
        return error.InvalidNativeOwnership;

    var clock: EventClockV1 = .{
        .timer = try std.time.Timer.start(),
    };
    for (0..pair_count) |pair_index| {
        try validateLifecycleSnapshot(
            backend,
            initial_lifecycle,
            try backend.deviceLifecycleSnapshot(),
        );
        var pending: [flow_count]PendingRecordV1 = undefined;
        for (0..flow_count) |flow| {
            pending[flow] = try startLaneV1(
                storage,
                campaign_lease,
                fixture,
                pair_index,
                flow,
                &clock,
            );
        }
        try validatePairActiveV1(
            storage,
            backend,
            pair_index,
            &pending,
        );
        for (0..flow_count) |flow| {
            try finishLaneV1(
                storage,
                campaign_lease,
                flow,
                &pending[flow],
                &clock,
            );
        }
        // Deliberately settle B before A.  This proves the two logical
        // adapter lanes do not depend on submission-order settlement; it is
        // still not evidence of physical GPU completion order.
        var reverse_flow: usize = flow_count;
        while (reverse_flow != 0) {
            reverse_flow -= 1;
            try settleLaneV1(
                storage,
                backend,
                scenario,
                reverse_flow,
                &pending[reverse_flow],
                &clock,
            );
        }
        try validatePairSettledV1(
            storage,
            backend,
            pair_index,
            &pending,
        );
    }

    if (clock.sequence !=
        record_count * native_report.event_count)
        return error.InvalidEventSequence;
    const released = try storage.coordinator.release(
        campaign_lease,
        storage.adapter.interface(),
    );
    const allocation_terminal = switch (released) {
        .terminal => |value| value,
        .recovery_required => return error.NativeReleaseRequiresRecovery,
    };
    try lease_tree.validateTerminalReceiptV1(
        allocation_terminal,
    );
    if (!allocation_terminal.terminal_tree.current.isZero())
        return error.InvalidNativeOwnership;
    try storage.adapter.validateEmpty();
    if (backend.liveBufferCount() != 0 or
        try backend.nativeLiveBufferCount() != 0 or
        try backend.nativeLiveCommandCount() != 0 or
        backend.compatibilityUnresolvedSubmission() != null)
        return error.InvalidNativeOwnership;

    try storage.bank.closePublicationSession(
        parent,
        0x5736_5251_4550,
        session_id,
        storage.publication_sequence,
    );
    try storage.bank.closeLeaseTree(storage.tree);
    try storage.bank.release(parent);
    const final_bank = try storage.bank.snapshotV4();
    if (!final_bank.used.isZero() or
        final_bank.active_reservations != 0 or
        final_bank.committed_receipts != 0 or
        final_bank.active_lease_trees != 0 or
        final_bank.active_lease_nodes != 0 or
        final_bank.active_lease_pin_slots != 0 or
        final_bank.lease_pin_acquisitions != record_count or
        final_bank.lease_pin_completions != record_count)
        return error.InvalidTerminalClosure;
    if (backend.completedDispatchCount() !=
        completed_dispatches_before + record_count)
        return error.InvalidDispatchCount;
    if (!std.meta.eql(
        retirement_before,
        try backend.dispatchRetirementTelemetry(),
    ))
        return error.UnexpectedRetirementActivity;
    try validateLifecycleSnapshot(
        backend,
        initial_lifecycle,
        try backend.deviceLifecycleSnapshot(),
    );
    const final_device = try backend.deviceInfo();
    if (!std.mem.eql(
        u8,
        &native_observer.deviceIdentityV1(initial_device),
        &native_observer.deviceIdentityV1(final_device),
    ) or !std.mem.eql(
        u8,
        &native_observer.placementIdentityV1(initial_device),
        &native_observer.placementIdentityV1(final_device),
    ))
        return error.InvalidMetalIdentity;

    const closure = try native_report.makeClosureV1(
        final_bank.lease_pin_acquisitions,
        final_bank.lease_pin_completions,
    );
    const sealed = try native_report.sealV1(
        scenario,
        &storage.records,
        closure,
    );
    const wire = try native_report.encodeV1(
        sealed,
        &storage.wire,
    );
    if (wire.len != encoded_bytes)
        return error.InvalidEncodedLength;

    storage.parent = null;
    storage.lease = null;
    storage.backend = null;
    storage.state = .complete;
    return .{
        .report = sealed,
        .wire = wire,
    };
}

fn digestIsZero(value: Digest) bool {
    return std.mem.eql(
        u8,
        &value,
        &native_report.zero_digest,
    );
}

fn digestV1(bytes: []const u8) Digest {
    return native_report.digestV1(bytes);
}

fn finishHash(
    hash: *std.crypto.hash.sha2.Sha256,
) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    const normalized: u64 = @intCast(value);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, normalized, .little);
    hash.update(&bytes);
}

fn hashF32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: f32,
) void {
    hashU64(hash, @as(u32, @bitCast(value)));
}

fn workloadIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-w6-metal-native-workload-v1\x00");
    hashU64(&hash, producer_abi);
    hashU64(&hash, in_features);
    hashU64(&hash, out_features);
    hashU64(&hash, group_size);
    hashU64(&hash, work_units_per_record);
    return finishHash(&hash);
}

fn profileIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-w6-metal-native-profile-v1\x00");
    hashU64(&hash, producer_abi);
    hashU64(&hash, warmup_pair_count);
    hashU64(&hash, measured_pair_count);
    hashU64(&hash, flow_count);
    hashU64(&hash, metal_allocation.maximum_async_dispatch_slots);
    hashU64(&hash, persistent_device_bytes);
    return finishHash(&hash);
}

fn backendIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-w6-metal-production-backend-v1\x00");
    hashU64(&hash, producer_abi);
    hashU64(&hash, metal.device_info_abi);
    hashU64(&hash, metal.dispatch_observation_abi);
    hashU64(&hash, metal.async_submission_abi);
    hashU64(&hash, metal.async_completion_abi);
    hashU64(&hash, metal_allocation.adapter_abi);
    hashU64(&hash, metal_allocation.observation_abi);
    hashU64(&hash, metal_allocation.dispatch_observation_abi);
    return finishHash(&hash);
}

fn hostSourceIdentityV1() Digest {
    return digestV1(
        "std.time.Timer.read+global-sequence/metal-workload-v1",
    );
}

fn hostClockIdentityV1() Digest {
    return digestV1("std.time.Timer monotonic nanoseconds/v1");
}

fn deviceClockIdentityV1() Digest {
    return digestV1(
        "MTLCommandBuffer.GPUStartTime+GPUEndTime seconds/v1",
    );
}

fn artifactIdentityV1(
    storage: *const StorageV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-w6-metal-native-artifact-v1\x00");
    hashU64(&hash, producer_abi);
    hashU64(&hash, storage.packed_weights.len);
    hash.update(&storage.packed_weights);
    hashU64(&hash, storage.scales.len);
    for (storage.scales) |value| hashF32(&hash, value);
    for (0..flow_count) |flow| {
        hashU64(&hash, flow);
        for (storage.inputs[flow]) |value|
            hashF32(&hash, value);
        for (storage.oracles[flow]) |value|
            hashF32(&hash, value);
    }
    return finishHash(&hash);
}

fn oracleIdentityV1(
    flow: usize,
    oracle: []const f32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-w6-metal-cpu-oracle-v1\x00");
    hashU64(&hash, producer_abi);
    hashU64(&hash, flow);
    hashU64(&hash, oracle.len);
    for (oracle) |value| hashF32(&hash, value);
    return finishHash(&hash);
}

fn makeScenarioV1(
    storage: *const StorageV1,
    info: metal.MetalDeviceInfo,
    logical_cpu_count: u64,
    config: RunConfigV1,
) !native_report.ScenarioV1 {
    const device_sha256 =
        native_observer.deviceIdentityV1(info);
    return native_report.makeScenarioV1(.{
        .mode = .closed,
        .evidence = .production_native,
        .warmup_count = warmup_record_count,
        .measured_count = measured_record_count,
        .max_in_flight = flow_count,
        .queue_count = flow_count,
        .flow_count = flow_count,
        .workload_sha256 = workloadIdentityV1(),
        .profile_sha256 = profileIdentityV1(),
        .artifact_sha256 = artifactIdentityV1(storage),
        .build_sha256 = config.build_sha256,
        .machine_sha256 = native_observer.machineIdentityV1(
            logical_cpu_count,
            device_sha256,
        ),
        .backend_sha256 = backendIdentityV1(),
        .device_sha256 = device_sha256,
        .placement_sha256 = native_observer.placementIdentityV1(info),
        .host_source_sha256 = hostSourceIdentityV1(),
        .host_clock_sha256 = hostClockIdentityV1(),
        .device_source_sha256 = native_observer.sourceIdentityV1(),
        .device_clock_sha256 = deviceClockIdentityV1(),
        .challenge_sha256 = config.challenge_sha256,
    });
}

fn validateLifecycleSnapshot(
    backend: *metal.MetalBackend,
    initial: metal.MetalDeviceLifecycleSnapshot,
    current: metal.MetalDeviceLifecycleSnapshot,
) !void {
    try metal.validateMetalDeviceLifecycleSnapshot(initial);
    try metal.validateMetalDeviceLifecycleSnapshot(current);
    try metal.requireAcceptingLifecycleSnapshot(current);
    if (!std.meta.eql(initial, current) or
        current.registry_id !=
            backend.initialDeviceInfo().registry_id or
        current.observer_active != 1 or
        current.observer_fault != 0 or
        current.removal_requested != 0 or
        current.removed != 0)
        return error.NativeLifecycleChanged;
}

fn fillPayloadV1(storage: *StorageV1) void {
    for (&storage.packed_weights, 0..) |*value, index| {
        const low: u8 = @intCast((index * 5 + 3) % 15);
        const high: u8 = @intCast((index * 11 + 7) % 15);
        value.* = low | (high << 4);
    }
    for (&storage.scales, 0..) |*value, index| {
        value.* = 0.0025 +
            @as(f32, @floatFromInt(index % 13)) * 0.000125;
    }
    for (0..flow_count) |flow| {
        for (&storage.inputs[flow], 0..) |*value, index| {
            const centered: i32 = @as(i32, @intCast(
                (index * (flow + 3) + flow * 5) % 23,
            )) - 11;
            value.* =
                @as(f32, @floatFromInt(centered)) * 0.03125;
        }
    }
}

fn computeOraclesV1(storage: *StorageV1) void {
    for (0..flow_count) |flow| {
        for (0..out_features) |row| {
            var accumulator: f32 = 0;
            for (0..in_features) |column| {
                const weight_index = row * in_features + column;
                const packed_byte = storage.packed_weights[
                    weight_index / 2
                ];
                const nibble: u8 = if (weight_index & 1 == 0)
                    packed_byte & 0x0f
                else
                    packed_byte >> 4;
                const quantized: i32 =
                    @as(i32, nibble) - 7;
                const weight =
                    @as(f32, @floatFromInt(quantized)) *
                    storage.scales[weight_index / group_size];
                accumulator = @mulAdd(
                    f32,
                    storage.inputs[flow][column],
                    weight,
                    accumulator,
                );
            }
            storage.oracles[flow][row] = accumulator;
        }
    }
}

fn lessThanEntry(
    _: void,
    left: allocation.AllocationEntryV1,
    right: allocation.AllocationEntryV1,
) bool {
    return std.mem.order(
        u8,
        &left.binding_sha256,
        &right.binding_sha256,
    ) == .lt;
}

fn bindingIdentityV1(
    flow: usize,
    role: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-w6-metal-buffer-role-v1\x00");
    hashU64(&hash, producer_abi);
    hashU64(&hash, flow);
    hash.update(role);
    return finishHash(&hash);
}

fn makeFixtureV1(
    adapter: *metal_allocation.MetalAllocationAdapterV1,
    inventory_entry: device.DeviceInventoryEntryV1,
    profile_sha256: Digest,
) !FixtureV1 {
    const geometry = try metal_allocation.makeMatvecGeometryV1(
        group_size,
        in_features,
        out_features,
    );
    var bindings: [flow_count]metal_allocation.MetalMatvecAllocationBindingsV1 =
        undefined;
    var entries: [flow_count * 4]allocation.AllocationEntryV1 =
        undefined;
    for (0..flow_count) |flow| {
        bindings[flow] = .{
            .packed_weights_sha256 = bindingIdentityV1(flow, "packed"),
            .scales_sha256 = bindingIdentityV1(flow, "scales"),
            .input_sha256 = bindingIdentityV1(flow, "input"),
            .output_sha256 = bindingIdentityV1(flow, "output"),
        };
        const requested = [4]u64{
            geometry.packed_bytes,
            geometry.scales_bytes,
            geometry.input_bytes,
            geometry.output_bytes,
        };
        const role_bindings = [4]Digest{
            bindings[flow].packed_weights_sha256,
            bindings[flow].scales_sha256,
            bindings[flow].input_sha256,
            bindings[flow].output_sha256,
        };
        for (0..4) |role| {
            const index = flow * 4 + role;
            const quote = try adapter.quote(
                role_bindings[role],
                requested[role],
            );
            entries[index] = .{
                .binding_sha256 = role_bindings[role],
                .requested_bytes = requested[role],
                .charged_bytes = quote.charged_bytes,
                .quote_sha256 = quote.quote_sha256,
            };
        }
    }
    std.mem.sort(
        allocation.AllocationEntryV1,
        &entries,
        {},
        lessThanEntry,
    );
    const manifest = try allocation.sealManifestV1(&entries);
    const operation_profile =
        device.OperationProfileBitsV1.matvec_int4_f32_bounded;
    const requirement = try device.sealRequirementV1(.{
        .plan_sha256 = profile_sha256,
        .required_device_class = .accelerator,
        .required_operation_profile_bits = operation_profile,
        .required_operator_bits = device.profileOperatorBitsV1(operation_profile),
        .required_element_type_bits = device.profileElementTypeBitsV1(operation_profile),
        .required_numerical_policy_bits = device.profileNumericalPolicyBitsV1(
            operation_profile,
        ),
        .required_feature_bits = device.FeatureBitsV1.allocation |
            device.FeatureBitsV1.dispatch |
            device.FeatureBitsV1.completion_fence |
            device.FeatureBitsV1.persistent_weights |
            device.FeatureBitsV1.allocated_bytes_observation |
            device.FeatureBitsV1.device_loss_signal,
        .largest_single_allocation_bytes = manifest.largest_charged_bytes,
        .total_device_bytes = manifest.total_charged_bytes,
        .queue_slots = flow_count,
        .fallback_policy = .forbidden,
    });
    const inventory = [1]device.DeviceInventoryEntryV1{
        inventory_entry,
    };
    const selected = try device.selectDeviceV1(
        requirement,
        &inventory,
    );
    if (selected.selected_index != 0 or
        selected.receipt.fallback_used != 0)
        return error.InvalidDeviceSelection;
    return .{
        .inventory = inventory,
        .requirement = requirement,
        .selection = selected.receipt,
        .bindings = bindings,
        .entries = entries,
        .manifest = manifest,
    };
}

fn startLaneV1(
    storage: *StorageV1,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    fixture: FixtureV1,
    pair_index: usize,
    flow: usize,
    clock: *EventClockV1,
) !PendingRecordV1 {
    if (flow >= flow_count or
        storage.lanes[flow].request != null or
        storage.lanes[flow].pin != null or
        storage.lanes[flow].ticket != null)
        return error.InvalidLaneState;
    const ordinal: usize = pair_index * flow_count + flow;
    if (ordinal >= record_count)
        return error.InvalidRecordOrdinal;
    storage.outputs[flow] =
        [_]f32{-8_765.25} ** out_features;

    var host: native_report.HostEventsV1 = .{
        .presence_mask = native_report.event_presence_all,
    };
    host.arrival = try clock.next();
    const bank_before = try storage.bank.snapshotV4();
    if (bank_before.used.device_bytes !=
        persistent_device_bytes)
        return error.InvalidNativeOwnership;
    const attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings[flow],
            storage.packed_weights.len,
            storage.scales.len,
            storage.inputs[flow].len,
            storage.outputs[flow].len,
            group_size,
            in_features,
            out_features,
        );
    const request =
        try storage.adapter.prepareMatvecDispatchRequestV1(
            attempt,
        );
    storage.lanes[flow].request = request;
    const pin = try storage.coordinator.acquireDispatchPin(
        campaign_lease,
        storage.adapter.dispatchInterface(),
        request.request_sha256,
    );
    storage.lanes[flow].pin = pin;
    try lease_tree.validateDispatchPinV1(pin);
    host.admission = try clock.next();
    const bank_after_acquire =
        try storage.bank.snapshotV4();
    if (bank_after_acquire.lease_pin_acquisitions !=
        bank_before.lease_pin_acquisitions + 1 or
        bank_after_acquire.lease_pin_completions !=
            bank_before.lease_pin_completions or
        bank_after_acquire.active_lease_pin_slots !=
            bank_before.active_lease_pin_slots + 1 or
        bank_after_acquire.used.device_bytes !=
            bank_before.used.device_bytes)
        return error.InvalidBankPinFacts;

    host.first_service = try clock.next();
    const ticket =
        try storage.adapter.submitMatvecInt4AsyncObserved(
            campaign_lease,
            pin,
            fixture.bindings[flow],
            &storage.packed_weights,
            &storage.scales,
            &storage.inputs[flow],
            &storage.outputs[flow],
            group_size,
            in_features,
            out_features,
        );
    storage.lanes[flow].ticket = ticket;
    host.submit_return = try clock.next();
    try metal_allocation.validateMetalAsyncDispatchTicketV1(
        ticket,
    );
    if (ticket.queue_slot != flow or
        !std.meta.eql(
            storage.adapter
                .currentAsyncDispatchTicketForQueueSlotV1(
                flow,
            ) orelse return error.InvalidLaneState,
            ticket,
        ) or
        storage.adapter
            .currentAsyncDispatchQuarantineForQueueSlotV1(
            flow,
        ) != null)
        return error.InvalidLaneState;

    return .{
        .ordinal = @intCast(ordinal),
        .cohort = if (pair_index < warmup_pair_count)
            .warmup
        else
            .measured,
        .flow_id = @intCast(flow),
        .host = host,
        .request = request,
        .pin = pin,
        .ticket = ticket,
        .bank_used_before = bank_before.used.device_bytes,
    };
}

fn validatePairActiveV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    pair_index: usize,
    pending: *const [flow_count]PendingRecordV1,
) !void {
    const coordinator_snapshot =
        try storage.coordinator.snapshot();
    const bank_snapshot = try storage.bank.snapshotV4();
    if (coordinator_snapshot.active_dispatches != flow_count or
        bank_snapshot.active_lease_pin_slots != flow_count or
        bank_snapshot.lease_pin_acquisitions !=
            (pair_index + 1) * flow_count or
        bank_snapshot.lease_pin_completions !=
            pair_index * flow_count or
        try backend.nativeLiveCommandCount() != flow_count)
        return error.InvalidPairOwnership;
    if (pending[0].ticket.queue_slot != 0 or
        pending[1].ticket.queue_slot != 1 or
        pending[0].ticket.ticket_generation >=
            pending[1].ticket.ticket_generation or
        pending[0].pin.dispatch_generation >=
            pending[1].pin.dispatch_generation or
        pending[0].host.arrival.sequence >=
            pending[1].host.arrival.sequence or
        pending[0].host.submit_return.sequence >=
            pending[1].host.submit_return.sequence or
        pending[0].host.submit_return.sequence >=
            pending[1].host.first_service.sequence or
        pending[0].host.first_output.sequence != 0 or
        pending[1].host.first_output.sequence != 0)
        return error.InvalidPairOrder;
    for (0..flow_count) |flow| {
        if (!std.meta.eql(
            storage.adapter
                .currentAsyncDispatchTicketForQueueSlotV1(
                flow,
            ) orelse return error.InvalidLaneState,
            pending[flow].ticket,
        ) or storage.adapter
            .currentAsyncDispatchQuarantineForQueueSlotV1(
            flow,
        ) != null)
            return error.InvalidLaneState;
    }
}

fn finishLaneV1(
    storage: *StorageV1,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    flow: usize,
    pending: *PendingRecordV1,
    clock: *EventClockV1,
) !void {
    if (flow >= flow_count or pending.result != null or
        !std.meta.eql(
            storage.lanes[flow].request orelse
                return error.InvalidLaneState,
            pending.request,
        ) or !std.meta.eql(
        storage.lanes[flow].pin orelse
            return error.InvalidLaneState,
        pending.pin,
    ) or !std.meta.eql(
        storage.lanes[flow].ticket orelse
            return error.InvalidLaneState,
        pending.ticket,
    ))
        return error.InvalidLaneState;

    const observed =
        try storage.adapter.waitMatvecInt4AsyncObserved(
            campaign_lease,
            pending.pin,
            pending.ticket,
            &storage.outputs[flow],
        );
    const result = switch (observed) {
        .completed => |value| value,
        .quarantined => return error.NativeDispatchQuarantined,
        .pending => return error.NativeDispatchUnresolved,
    };
    pending.host.first_output = try clock.next();
    try metal_allocation
        .validateMetalLeaseTreeDispatchPayloadV1(
        result.observation,
        &storage.packed_weights,
        &storage.scales,
        &storage.inputs[flow],
        &storage.outputs[flow],
    );
    try metal_allocation
        .validateMetalLeaseTreeDispatchObservationForPinV1(
        result.observation,
        pending.pin,
        result.terminal,
    );
    if (result.observation.outcome != .succeeded or
        result.observation.telemetry.command_status !=
            metal.completed_command_buffer_status or
        result.observation.telemetry.gpu_duration_nanoseconds !=
            (native_report.deviceDurationNsV1(
                result.observation.telemetry
                    .gpu_start_time_bits,
                result.observation.telemetry
                    .gpu_end_time_bits,
            ) orelse return error.InvalidDeviceTiming))
        return error.InvalidDeviceTiming;

    var maximum: f64 = 0;
    for (
        storage.oracles[flow],
        storage.outputs[flow],
    ) |expected, actual| {
        if (!std.math.isFinite(expected) or
            !std.math.isFinite(actual))
            return error.InvalidOutput;
        maximum = @max(
            maximum,
            @abs(
                @as(f64, expected) -
                    @as(f64, actual),
            ),
        );
    }
    pending.maximum_abs_error = maximum;
    pending.correctness =
        if (maximum <= maximum_abs_error)
            .correct
        else
            .incorrect;
    pending.host.terminal = try clock.next();
    pending.result = result;
}

fn settleLaneV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    scenario: native_report.ScenarioV1,
    flow: usize,
    pending: *PendingRecordV1,
    clock: *EventClockV1,
) !void {
    if (flow >= flow_count or pending.completion != null)
        return error.InvalidLaneState;
    const result = pending.result orelse
        return error.InvalidLaneState;
    const bank_before = try storage.bank.snapshotV4();
    const coordinator_before =
        try storage.coordinator.snapshot();
    const native_commands_before =
        try backend.nativeLiveCommandCount();
    if (bank_before.active_lease_pin_slots == 0 or
        coordinator_before.active_dispatches == 0 or
        native_commands_before == 0)
        return error.InvalidPairOwnership;
    const completion =
        try storage.coordinator.completeDispatchPin(
            pending.pin,
            storage.adapter.dispatchInterface(),
            result.terminal,
        );
    try lease_tree.validateDispatchCompletionForPinV1(
        completion,
        pending.pin,
        result.terminal,
    );
    try storage.adapter.acknowledgeDispatchCompletion(
        completion,
    );
    pending.host.settlement = try clock.next();
    pending.completion = completion;

    const bank_after = try storage.bank.snapshotV4();
    const coordinator_after =
        try storage.coordinator.snapshot();
    const native_commands_after =
        try backend.nativeLiveCommandCount();
    if (bank_after.lease_pin_acquisitions !=
        bank_before.lease_pin_acquisitions or
        bank_after.lease_pin_completions !=
            bank_before.lease_pin_completions + 1 or
        bank_after.active_lease_pin_slots + 1 !=
            bank_before.active_lease_pin_slots or
        coordinator_after.active_dispatches + 1 !=
            coordinator_before.active_dispatches or
        native_commands_after + 1 !=
            native_commands_before or
        bank_after.used.device_bytes !=
            pending.bank_used_before or
        storage.adapter
            .currentAsyncDispatchTicketForQueueSlotV1(
            flow,
        ) != null or
        storage.adapter
            .currentAsyncDispatchQuarantineForQueueSlotV1(
            flow,
        ) != null)
        return error.InvalidSettlementFacts;

    const telemetry = result.observation.telemetry;
    const oracle_sha256 =
        oracleIdentityV1(flow, &storage.oracles[flow]);
    const record = try native_report.makeRecordV1(.{
        .ordinal = pending.ordinal,
        .cohort = pending.cohort,
        .outcome = .completed,
        .correctness = pending.correctness,
        .fallback = false,
        .flow_id = pending.flow_id,
        .work_units = work_units_per_record,
        .adapter_queue_slot = @intCast(
            pending.ticket.queue_slot,
        ),
        .host = pending.host,
        .roots = .{
            .request_sha256 = pending.request.request_sha256,
            .ticket_sha256 = pending.ticket.ticket_sha256,
            .pin_sha256 = pending.pin.pin_sha256,
            .dispatch_sha256 = result.observation.observation_sha256,
            .submission_sha256 = result.observation.submission_sha256,
            .output_sha256 = result.observation.output_sha256,
            .oracle_sha256 = oracle_sha256,
            .terminal_sha256 = result.terminal.terminal_sha256,
            .completion_sha256 = completion.completion_sha256,
        },
        .maximum_abs_error_f64_bits = @bitCast(pending.maximum_abs_error),
        .device_timing = .{
            .availability = .present,
            .raw_start_f64_bits = telemetry.gpu_start_time_bits,
            .raw_end_f64_bits = telemetry.gpu_end_time_bits,
            .duration_ns = telemetry.gpu_duration_nanoseconds,
            .source_sha256 = scenario.device_source_sha256,
            .clock_sha256 = scenario.device_clock_sha256,
        },
        .allocated_context = .{
            .availability = .present,
            .before_bytes = telemetry.current_allocated_before,
            .after_bytes = telemetry.current_allocated_after,
            .source_sha256 = scenario.device_source_sha256,
        },
        .logical = .{
            .bank_acquisitions = 1,
            .bank_completions = 1,
            .bank_used_before = pending.bank_used_before,
            .bank_used_after_settlement = bank_after.used.device_bytes,
            .pin_count_before = 1,
            .pin_count_after_settlement = 0,
            .dispatch_count_before = 1,
            .dispatch_count_after_settlement = 0,
            .native_command_count_before = 1,
            .native_command_count_after_settlement = 0,
        },
    });
    storage.records[pending.ordinal] = record;
    storage.lanes[flow] = .{};
}

fn validatePairSettledV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    pair_index: usize,
    pending: *const [flow_count]PendingRecordV1,
) !void {
    const coordinator_snapshot =
        try storage.coordinator.snapshot();
    const bank_snapshot = try storage.bank.snapshotV4();
    if (coordinator_snapshot.active_dispatches != 0 or
        bank_snapshot.active_lease_pin_slots != 0 or
        bank_snapshot.lease_pin_acquisitions !=
            (pair_index + 1) * flow_count or
        bank_snapshot.lease_pin_completions !=
            (pair_index + 1) * flow_count or
        try backend.nativeLiveCommandCount() != 0 or
        pending[1].host.submit_return.sequence >=
            pending[0].host.first_output.sequence or
        pending[1].host.settlement.sequence >=
            pending[0].host.settlement.sequence)
        return error.InvalidPairOrder;
    for (0..flow_count) |flow| {
        if (storage.lanes[flow].request != null or
            storage.lanes[flow].pin != null or
            storage.lanes[flow].ticket != null or
            storage.adapter
                .currentAsyncDispatchTicketForQueueSlotV1(
                flow,
            ) != null or
            storage.adapter
                .currentAsyncDispatchQuarantineForQueueSlotV1(
                flow,
            ) != null)
            return error.InvalidLaneState;
    }
}
