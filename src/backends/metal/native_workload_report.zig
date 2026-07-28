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
//! `runV1` or `runControlledDisruptionV1`. On an error after native submission
//! the storage and backend remain live so a higher-level recovery authority
//! can inspect the retained state; no report is sealed and no wire is
//! published.

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
pub const disruption_producer_abi: u64 = 0x4757_374d_0000_0001;
pub const cancellation_storm_producer_abi: u64 =
    0x4757_434d_0000_0001;
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

pub const disruption_warmup_epoch_count: usize = 2;
pub const disruption_measured_epoch_count: usize = 48;
pub const disruption_epoch_count: usize =
    disruption_warmup_epoch_count +
    disruption_measured_epoch_count;
pub const disruption_records_per_epoch: usize = 5;
pub const disruption_warmup_record_count: usize =
    disruption_warmup_epoch_count *
    disruption_records_per_epoch;
pub const disruption_measured_record_count: usize =
    disruption_measured_epoch_count *
    disruption_records_per_epoch;
pub const disruption_record_count: usize =
    disruption_epoch_count *
    disruption_records_per_epoch;
pub const disruption_completed_dispatch_count: usize =
    disruption_epoch_count * flow_count;
pub const disruption_cancelled_count: usize =
    disruption_epoch_count;
pub const disruption_failed_count: usize =
    disruption_epoch_count;
pub const disruption_capacity_rejected_count: usize =
    disruption_epoch_count;
pub const disruption_pin_count: usize =
    disruption_epoch_count * 4;
pub const disruption_encoded_bytes: usize =
    native_report.minimum_encoded_bytes +
    disruption_record_count * native_report.record_wire_bytes;
pub const cancellation_storm_block_count: usize = 8;
pub const cancellation_storm_waves_per_block: usize = 8;
pub const cancellation_storm_warmup_block_count: usize = 1;
pub const cancellation_storm_records_per_wave: usize = 3;
pub const cancellation_storm_control_records_per_block: usize =
    flow_count;
pub const cancellation_storm_records_per_block: usize =
    cancellation_storm_waves_per_block *
    cancellation_storm_records_per_wave +
    cancellation_storm_control_records_per_block;
pub const cancellation_storm_warmup_record_count: usize =
    cancellation_storm_warmup_block_count *
    cancellation_storm_records_per_block;
pub const cancellation_storm_record_count: usize =
    cancellation_storm_block_count *
    cancellation_storm_records_per_block;
pub const cancellation_storm_measured_record_count: usize =
    cancellation_storm_record_count -
    cancellation_storm_warmup_record_count;
pub const cancellation_storm_cancelled_count: usize =
    cancellation_storm_block_count *
    cancellation_storm_waves_per_block *
    flow_count;
pub const cancellation_storm_capacity_rejected_count: usize =
    cancellation_storm_block_count *
    cancellation_storm_waves_per_block;
pub const cancellation_storm_completed_dispatch_count: usize =
    cancellation_storm_block_count * flow_count;
pub const cancellation_storm_pin_count: usize =
    cancellation_storm_cancelled_count +
    cancellation_storm_completed_dispatch_count;
pub const cancellation_storm_event_count: usize =
    cancellation_storm_block_count *
    (cancellation_storm_waves_per_block * 11 + 14);
pub const cancellation_storm_encoded_bytes: usize =
    native_report.minimum_encoded_bytes +
    cancellation_storm_record_count *
        native_report.record_wire_bytes;
pub const storage_record_capacity: usize =
    disruption_record_count;
pub const storage_wire_capacity: usize =
    disruption_encoded_bytes;

const DisruptionActionV1 = enum(u64) {
    cancel_before_submit = 1,
    malformed_pre_submit = 2,
    completed_lane0 = 3,
    completed_lane1 = 4,
    full_capacity_rejection = 5,
};

const DisruptionActionDetailV1 = enum(u64) {
    cancelled_before_submit = 1,
    invalid_host_lengths = 2,
};

const CancellationStormActionV1 = enum(u64) {
    cancel_lane0 = 1,
    cancel_lane1 = 2,
    capacity_probe = 3,
    completed_lane0 = 4,
    completed_lane1 = 5,
};

const CancellationStormRootRoleV1 = enum(u64) {
    request = 1,
    terminal = 2,
    completion = 3,
    timing_unsupported = 4,
    allocation_unsupported = 5,
    action_evidence = 6,
};

const disruption_admitted_presence: u8 =
    native_report.event_arrival |
    native_report.event_admission |
    native_report.event_terminal |
    native_report.event_settlement;

const DisruptionRootRoleV1 = enum(u64) {
    request = 1,
    terminal = 2,
    completion = 3,
    timing_unsupported = 4,
    allocation_unsupported = 5,
    action_evidence = 6,
};

comptime {
    if (record_count != 20 or work_units_per_record != 2_368 or
        persistent_device_bytes != 5_544)
        @compileError("native Metal workload geometry changed");
    if (disruption_epoch_count != 50 or
        disruption_record_count != 250 or
        disruption_completed_dispatch_count != 100 or
        disruption_pin_count != 200 or
        disruption_record_count > native_report.max_records)
        @compileError("native Metal disruption schedule changed");
    if (cancellation_storm_record_count != 208 or
        cancellation_storm_warmup_record_count != 26 or
        cancellation_storm_measured_record_count != 182 or
        cancellation_storm_cancelled_count != 128 or
        cancellation_storm_capacity_rejected_count != 64 or
        cancellation_storm_completed_dispatch_count != 16 or
        cancellation_storm_pin_count != 144 or
        cancellation_storm_event_count != 816 or
        cancellation_storm_encoded_bytes != 163_132 or
        cancellation_storm_record_count >
            native_report.max_records)
        @compileError(
            "native Metal cancellation-storm schedule changed",
        );
}

pub const RunConfigV1 = struct {
    /// Exact source/build identity supplied by the binary runner.
    build_sha256: Digest,
    /// Nonzero campaign challenge supplied by the invoking authority.
    challenge_sha256: Digest,
    /// Optional minimum spacing between controlled-disruption epoch starts.
    /// Zero preserves the original fixed W7 campaign schedule.
    epoch_start_spacing_ns: u64 = 0,
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
    records: [storage_record_capacity]native_report.RecordV1 = undefined,
    wire: [storage_wire_capacity]u8 = undefined,
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
    mutex: std.Thread.Mutex = .{},

    fn next(self: *EventClockV1) !native_report.EventPointV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
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

fn controlledEpochStartTargetNsV1(
    epoch_index: usize,
    spacing_ns: u64,
) !u64 {
    const one_based_epoch = std.math.add(
        usize,
        epoch_index,
        1,
    ) catch return error.EpochStartSpacingOverflow;
    const one_based_epoch_u64 = std.math.cast(
        u64,
        one_based_epoch,
    ) orelse return error.EpochStartSpacingOverflow;
    return std.math.mul(
        u64,
        one_based_epoch_u64,
        spacing_ns,
    ) catch return error.EpochStartSpacingOverflow;
}

fn validateControlledEpochStartSpacingV1(
    spacing_ns: u64,
) !void {
    if (spacing_ns == 0) return;
    _ = try controlledEpochStartTargetNsV1(
        disruption_epoch_count - 1,
        spacing_ns,
    );
}

fn validateNativeWorkloadEpochStartSpacingV1(
    spacing_ns: u64,
) !void {
    if (spacing_ns != 0)
        return error.EpochStartSpacingRequiresControlledDisruption;
}

fn waitForControlledEpochStartV1(
    clock: *EventClockV1,
    epoch_index: usize,
    spacing_ns: u64,
) !void {
    // Preserve the original W7 schedule exactly when pacing is disabled,
    // including avoiding an additional timer read.
    if (spacing_ns == 0) return;
    const target_ns = try controlledEpochStartTargetNsV1(
        epoch_index,
        spacing_ns,
    );
    while (true) {
        const elapsed_ns = clock.timer.read();
        if (elapsed_ns >= target_ns) return;
        std.Thread.sleep(target_ns - elapsed_ns);
    }
}

test "controlled epoch start targets use checked one-based spacing" {
    try std.testing.expectEqual(
        @as(u64, 100),
        try controlledEpochStartTargetNsV1(0, 100),
    );
    try std.testing.expectEqual(
        @as(u64, 5_000),
        try controlledEpochStartTargetNsV1(49, 100),
    );
    const maximum_spacing =
        std.math.maxInt(u64) / disruption_epoch_count;
    try std.testing.expectEqual(
        maximum_spacing * disruption_epoch_count,
        try controlledEpochStartTargetNsV1(
            disruption_epoch_count - 1,
            maximum_spacing,
        ),
    );
    try std.testing.expectError(
        error.EpochStartSpacingOverflow,
        controlledEpochStartTargetNsV1(
            disruption_epoch_count - 1,
            maximum_spacing + 1,
        ),
    );
    try std.testing.expectError(
        error.EpochStartSpacingOverflow,
        controlledEpochStartTargetNsV1(
            std.math.maxInt(usize),
            1,
        ),
    );
}

test "epoch start spacing is controlled-disruption only" {
    try validateNativeWorkloadEpochStartSpacingV1(0);
    try std.testing.expectError(
        error.EpochStartSpacingRequiresControlledDisruption,
        validateNativeWorkloadEpochStartSpacingV1(1),
    );
}

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

const CancellationStormPendingV1 = struct {
    request: metal_allocation.MetalMatvecDispatchRequestV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    host: native_report.HostEventsV1 = .{
        .presence_mask = disruption_admitted_presence,
    },
    terminal: ?lease_tree.DispatchTerminalEvidenceV1 = null,
    completion: ?lease_tree.LeaseTreeDispatchCompletionV1 = null,
};

const CancellationStormWorkerV1 = struct {
    adapter: *metal_allocation.MetalAllocationAdapterV1,
    lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    clock: *EventClockV1,
    ready: *std.atomic.Value(usize),
    release: *std.atomic.Value(bool),
    terminal: ?lease_tree.DispatchTerminalEvidenceV1 = null,
    observed_return: native_report.EventPointV1 = .{},
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (!self.release.load(.acquire))
            std.atomic.spinLoopHint();
        self.terminal =
            self.adapter.cancelMatvecBeforeSubmitObserved(
                self.lease,
                self.pin,
            ) catch |err| {
                self.failure = err;
                return;
            };
        self.observed_return = self.clock.next() catch |err| {
            self.failure = err;
            return;
        };
    }
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
    try validateNativeWorkloadEpochStartSpacingV1(
        config.epoch_start_spacing_ns,
    );
    storage.state = .running;
    storage.backend = backend;
    errdefer storage.state = .failed_retained;

    return runBoundV1(storage, backend, config);
}

pub const run = runV1;

/// Run the fixed W7 controlled-disruption campaign. The storage binding and
/// retained-failure semantics are identical to `runV1`.
pub fn runControlledDisruptionV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    config: RunConfigV1,
) !ArtifactV1 {
    if (storage.state != .empty) return error.StorageAlreadyBound;
    if (digestIsZero(config.build_sha256) or
        digestIsZero(config.challenge_sha256))
        return error.InvalidIdentity;
    try validateControlledEpochStartSpacingV1(
        config.epoch_start_spacing_ns,
    );
    storage.state = .running;
    storage.backend = backend;
    errdefer storage.state = .failed_retained;

    return runBoundCampaignV1(
        storage,
        backend,
        config,
        .controlled_disruption,
    );
}

/// Run the fixed W7b cancellation-storm concurrent-caller campaign.
/// Cancellation records prove concurrent host callers against two disjoint
/// production-adapter lanes before native submission; only the clean control
/// pairs submit Metal commands.
pub fn runCancellationStormV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    config: RunConfigV1,
) !ArtifactV1 {
    if (storage.state != .empty) return error.StorageAlreadyBound;
    if (digestIsZero(config.build_sha256) or
        digestIsZero(config.challenge_sha256))
        return error.InvalidIdentity;
    try validateNativeWorkloadEpochStartSpacingV1(
        config.epoch_start_spacing_ns,
    );
    storage.state = .running;
    storage.backend = backend;
    errdefer storage.state = .failed_retained;

    return runBoundCampaignV1(
        storage,
        backend,
        config,
        .cancellation_storm,
    );
}

const CampaignKindV1 = enum {
    native_workload,
    controlled_disruption,
    cancellation_storm,
};

fn runBoundV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    config: RunConfigV1,
) !ArtifactV1 {
    return runBoundCampaignV1(
        storage,
        backend,
        config,
        .native_workload,
    );
}

fn runBoundCampaignV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    config: RunConfigV1,
    campaign: CampaignKindV1,
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

    const scenario = switch (campaign) {
        .native_workload => try makeScenarioV1(
            storage,
            initial_device,
            logical_cpu_count,
            config,
        ),
        .controlled_disruption => try makeControlledDisruptionScenarioV1(
            storage,
            initial_device,
            logical_cpu_count,
            config,
        ),
        .cancellation_storm => try makeCancellationStormScenarioV1(
            storage,
            initial_device,
            logical_cpu_count,
            config,
        ),
    };
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
        switch (campaign) {
            .native_workload => digestV1(
                "glacier-w6-metal-campaign-owner-v1\x00",
            ),
            .controlled_disruption => digestV1(
                "glacier-w7-metal-controlled-disruption-owner-v1\x00",
            ),
            .cancellation_storm => scenario.profile_sha256,
        },
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
    switch (campaign) {
        .native_workload => {
            for (0..pair_count) |pair_index| {
                try validateLifecycleSnapshot(
                    backend,
                    initial_lifecycle,
                    try backend.deviceLifecycleSnapshot(),
                );
                var pending: [flow_count]PendingRecordV1 =
                    undefined;
                for (0..flow_count) |flow| {
                    pending[flow] = try startLaneV1(
                        storage,
                        campaign_lease,
                        fixture,
                        pair_index * flow_count + flow,
                        if (pair_index < warmup_pair_count)
                            .warmup
                        else
                            .measured,
                        flow,
                        &clock,
                    );
                }
                try validatePairActiveV1(
                    storage,
                    backend,
                    (pair_index + 1) * flow_count,
                    pair_index * flow_count,
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
                // Deliberately settle B before A.  This proves the two
                // logical adapter lanes do not depend on submission-order
                // settlement; it is still not evidence of physical GPU
                // completion order.
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
                    (pair_index + 1) * flow_count,
                    &pending,
                );
            }
        },
        .controlled_disruption => {
            try runControlledDisruptionEpochsV1(
                storage,
                backend,
                campaign_lease,
                fixture,
                scenario,
                initial_lifecycle,
                initial_device,
                initial_device.recommended_max_working_set_size,
                completed_dispatches_before,
                config.epoch_start_spacing_ns,
                &clock,
            );
        },
        .cancellation_storm => {
            try runCancellationStormBlocksV1(
                storage,
                backend,
                campaign_lease,
                fixture,
                scenario,
                initial_lifecycle,
                initial_device,
                initial_device.recommended_max_working_set_size,
                completed_dispatches_before,
                config.challenge_sha256,
                &clock,
            );
        },
    }

    const expected_event_count: u64 = switch (campaign) {
        .native_workload => record_count * native_report.event_count,
        .controlled_disruption => disruption_epoch_count * 25,
        .cancellation_storm => cancellation_storm_event_count,
    };
    if (clock.sequence != expected_event_count)
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
    const expected_pin_count: u64 = switch (campaign) {
        .native_workload => record_count,
        .controlled_disruption => disruption_pin_count,
        .cancellation_storm => cancellation_storm_pin_count,
    };
    const expected_dispatch_count: u64 = switch (campaign) {
        .native_workload => record_count,
        .controlled_disruption => disruption_completed_dispatch_count,
        .cancellation_storm => cancellation_storm_completed_dispatch_count,
    };
    if (!final_bank.used.isZero() or
        final_bank.active_reservations != 0 or
        final_bank.committed_receipts != 0 or
        final_bank.active_lease_trees != 0 or
        final_bank.active_lease_nodes != 0 or
        final_bank.active_lease_pin_slots != 0 or
        final_bank.lease_pin_acquisitions !=
            expected_pin_count or
        final_bank.lease_pin_completions !=
            expected_pin_count)
        return error.InvalidTerminalClosure;
    if (backend.completedDispatchCount() !=
        completed_dispatches_before + expected_dispatch_count)
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
    try validateDeviceAndPlacementIdentityV1(
        initial_device,
        final_device,
    );

    const closure = try native_report.makeClosureV1(
        final_bank.lease_pin_acquisitions,
        final_bank.lease_pin_completions,
    );
    const campaign_record_count: usize = switch (campaign) {
        .native_workload => record_count,
        .controlled_disruption => disruption_record_count,
        .cancellation_storm => cancellation_storm_record_count,
    };
    const campaign_encoded_bytes: usize = switch (campaign) {
        .native_workload => encoded_bytes,
        .controlled_disruption => disruption_encoded_bytes,
        .cancellation_storm => cancellation_storm_encoded_bytes,
    };
    const sealed = try native_report.sealV1(
        scenario,
        storage.records[0..campaign_record_count],
        closure,
    );
    if (campaign == .cancellation_storm)
        try validateCancellationStormSealedV1(sealed);
    const wire = try native_report.encodeV1(
        sealed,
        storage.wire[0..campaign_encoded_bytes],
    );
    if (wire.len != campaign_encoded_bytes)
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

fn hashControlledDisruptionScheduleV1(
    hash: *std.crypto.hash.sha2.Sha256,
) void {
    hashU64(hash, disruption_producer_abi);
    hashU64(hash, disruption_warmup_epoch_count);
    hashU64(hash, disruption_measured_epoch_count);
    hashU64(hash, disruption_records_per_epoch);
    hashU64(hash, flow_count);
    hashU64(
        hash,
        metal_allocation.maximum_async_dispatch_slots,
    );
    hashU64(hash, persistent_device_bytes);
    inline for (std.meta.fields(DisruptionActionV1)) |field| {
        hashU64(hash, field.value);
    }
}

fn controlledDisruptionIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7-metal-controlled-disruption-schedule-v1\x00",
    );
    hashControlledDisruptionScheduleV1(&hash);
    return finishHash(&hash);
}

fn controlledDisruptionWorkloadIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-w7-metal-native-workload-v1\x00");
    hashU64(&hash, disruption_producer_abi);
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

fn controlledDisruptionProfileIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7-metal-controlled-disruption-profile-v1\x00",
    );
    hash.update(&controlledDisruptionIdentityV1());
    hashControlledDisruptionScheduleV1(&hash);
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

fn controlledDisruptionBackendIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-w7-metal-production-backend-v1\x00");
    hashU64(&hash, disruption_producer_abi);
    hashU64(&hash, metal.device_info_abi);
    hashU64(&hash, metal.dispatch_observation_abi);
    hashU64(&hash, metal.async_submission_abi);
    hashU64(&hash, metal.async_completion_abi);
    hashU64(&hash, metal_allocation.adapter_abi);
    hashU64(&hash, metal_allocation.observation_abi);
    hashU64(&hash, metal_allocation.dispatch_observation_abi);
    return finishHash(&hash);
}

fn hashCancellationStormScheduleTupleV1(
    hash: *std.crypto.hash.sha2.Sha256,
) void {
    hashU64(hash, cancellation_storm_producer_abi);
    hashU64(hash, cancellation_storm_block_count);
    hashU64(hash, cancellation_storm_waves_per_block);
    hashU64(hash, cancellation_storm_warmup_block_count);
    hashU64(hash, cancellation_storm_records_per_wave);
    hashU64(hash, cancellation_storm_control_records_per_block);
    hashU64(hash, flow_count);
    hashU64(
        hash,
        metal_allocation.maximum_async_dispatch_slots,
    );
    hashU64(hash, persistent_device_bytes);
    hashU64(hash, cancellation_storm_pin_count);
    inline for (
        std.meta.fields(CancellationStormActionV1),
    ) |field| {
        hashU64(hash, field.value);
    }
}

pub fn cancellationStormScheduleIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7b-metal-cancellation-storm-schedule-v1\x00",
    );
    hashCancellationStormScheduleTupleV1(&hash);
    return finishHash(&hash);
}

pub fn cancellationStormProfileIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7b-metal-cancellation-storm-profile-v1\x00",
    );
    hash.update(&cancellationStormScheduleIdentityV1());
    hashCancellationStormScheduleTupleV1(&hash);
    return finishHash(&hash);
}

pub fn cancellationStormWorkloadIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7b-metal-cancellation-storm-workload-v1\x00",
    );
    hashU64(&hash, cancellation_storm_producer_abi);
    hashU64(&hash, in_features);
    hashU64(&hash, out_features);
    hashU64(&hash, group_size);
    hashU64(&hash, work_units_per_record);
    return finishHash(&hash);
}

fn cancellationStormArtifactIdentityV1(
    storage: *const StorageV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7b-metal-cancellation-storm-artifact-v1\x00",
    );
    hashU64(&hash, cancellation_storm_producer_abi);
    hash.update(&artifactIdentityV1(storage));
    return finishHash(&hash);
}

pub fn cancellationStormBackendIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7b-metal-cancellation-storm-backend-v1\x00",
    );
    hashU64(&hash, cancellation_storm_producer_abi);
    hashU64(&hash, metal.device_info_abi);
    hashU64(&hash, metal.dispatch_observation_abi);
    hashU64(&hash, metal.async_submission_abi);
    hashU64(&hash, metal.async_completion_abi);
    hashU64(&hash, metal_allocation.adapter_abi);
    hashU64(&hash, metal_allocation.observation_abi);
    hashU64(
        &hash,
        metal_allocation.dispatch_observation_abi,
    );
    return finishHash(&hash);
}

pub fn cancellationStormHostSourceIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7b-metal-cancellation-storm-host-source-v1\x00",
    );
    hashU64(&hash, cancellation_storm_producer_abi);
    hash.update(&cancellationStormScheduleIdentityV1());
    return finishHash(&hash);
}

fn hostSourceIdentityV1() Digest {
    return digestV1(
        "std.time.Timer.read+global-sequence/metal-workload-v1",
    );
}

fn controlledDisruptionHostSourceIdentityV1() Digest {
    return digestV1(
        "std.time.Timer.read+global-sequence/metal-disruption-v1",
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

fn controlledDisruptionArtifactIdentityV1(
    storage: *const StorageV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7-metal-controlled-disruption-artifact-v1\x00",
    );
    hashU64(&hash, disruption_producer_abi);
    hash.update(&artifactIdentityV1(storage));
    return finishHash(&hash);
}

fn controlledDisruptionRecordRootV1(
    scenario: native_report.ScenarioV1,
    epoch_index: usize,
    action: DisruptionActionV1,
    role: DisruptionRootRoleV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7-metal-controlled-disruption-record-v1\x00",
    );
    hash.update(&scenario.profile_sha256);
    hashU64(&hash, disruption_producer_abi);
    hashU64(&hash, epoch_index);
    hashU64(&hash, @intFromEnum(action));
    hashU64(&hash, @intFromEnum(role));
    return finishHash(&hash);
}

fn controlledDisruptionAdmittedCommitmentV1(
    scenario: native_report.ScenarioV1,
    epoch_index: usize,
    action: DisruptionActionV1,
    detail: DisruptionActionDetailV1,
    outcome: native_report.OutcomeV1,
    flow: usize,
    request_sha256: Digest,
    pin_sha256: Digest,
    terminal_sha256: Digest,
    completion_sha256: Digest,
    action_evidence_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7-metal-controlled-disruption-admitted-v1\x00",
    );
    hash.update(&scenario.profile_sha256);
    hashU64(&hash, disruption_producer_abi);
    hashU64(&hash, epoch_index);
    hashU64(&hash, @intFromEnum(action));
    hashU64(&hash, @intFromEnum(detail));
    hashU64(&hash, @intFromEnum(outcome));
    hashU64(&hash, flow);
    hash.update(&request_sha256);
    hash.update(&pin_sha256);
    hash.update(&terminal_sha256);
    hash.update(&completion_sha256);
    hash.update(&action_evidence_sha256);
    return finishHash(&hash);
}

fn controlledDisruptionCapacityRootV1(
    scenario: native_report.ScenarioV1,
    epoch_index: usize,
    role: DisruptionRootRoleV1,
    generations: metal_allocation.MetalDispatchGenerationSnapshotV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7-metal-controlled-disruption-capacity-v1\x00",
    );
    hash.update(&scenario.profile_sha256);
    hashU64(&hash, disruption_producer_abi);
    hashU64(&hash, epoch_index);
    hashU64(
        &hash,
        @intFromEnum(
            DisruptionActionV1.full_capacity_rejection,
        ),
    );
    hashU64(&hash, @intFromEnum(role));
    hashU64(&hash, generations.next_request_generation);
    hashU64(&hash, generations.next_ticket_generation);
    return finishHash(&hash);
}

fn cancellationStormRecordRootV1(
    scenario: native_report.ScenarioV1,
    block_index: usize,
    wave_index: usize,
    action: CancellationStormActionV1,
    lane: usize,
    role: CancellationStormRootRoleV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7b-metal-cancellation-storm-record-v1\x00",
    );
    hash.update(&scenario.profile_sha256);
    hashU64(&hash, cancellation_storm_producer_abi);
    hashU64(&hash, block_index);
    hashU64(&hash, wave_index);
    hashU64(&hash, @intFromEnum(action));
    hashU64(&hash, lane);
    hashU64(&hash, @intFromEnum(role));
    return finishHash(&hash);
}

fn cancellationStormAdmittedCommitmentV1(
    scenario: native_report.ScenarioV1,
    block_index: usize,
    wave_index: usize,
    action: CancellationStormActionV1,
    lane: usize,
    terminal_rank: usize,
    outcome: native_report.OutcomeV1,
    request_sha256: Digest,
    pin_sha256: Digest,
    terminal_sha256: Digest,
    completion_sha256: Digest,
    action_evidence_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7b-metal-cancellation-storm-admitted-v1\x00",
    );
    hash.update(&scenario.profile_sha256);
    hashU64(&hash, cancellation_storm_producer_abi);
    hashU64(&hash, block_index);
    hashU64(&hash, wave_index);
    hashU64(&hash, @intFromEnum(action));
    hashU64(&hash, lane);
    hashU64(&hash, terminal_rank);
    hashU64(&hash, @intFromEnum(outcome));
    hash.update(&request_sha256);
    hash.update(&pin_sha256);
    hash.update(&terminal_sha256);
    hash.update(&completion_sha256);
    hash.update(&action_evidence_sha256);
    return finishHash(&hash);
}

fn cancellationStormCapacityRootV1(
    scenario: native_report.ScenarioV1,
    block_index: usize,
    wave_index: usize,
    probe_flow: usize,
    role: CancellationStormRootRoleV1,
    generations: metal_allocation.MetalDispatchGenerationSnapshotV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-w7b-metal-cancellation-storm-capacity-v1\x00",
    );
    hash.update(&scenario.profile_sha256);
    hashU64(&hash, cancellation_storm_producer_abi);
    hashU64(&hash, block_index);
    hashU64(&hash, wave_index);
    hashU64(&hash, probe_flow);
    hashU64(&hash, @intFromEnum(role));
    hashU64(&hash, generations.next_request_generation);
    hashU64(&hash, generations.next_ticket_generation);
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

fn makeControlledDisruptionScenarioV1(
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
        .warmup_count = disruption_warmup_record_count,
        .measured_count = disruption_measured_record_count,
        .max_in_flight = flow_count,
        .queue_count = flow_count,
        .flow_count = flow_count,
        .workload_sha256 = controlledDisruptionWorkloadIdentityV1(),
        .profile_sha256 = controlledDisruptionProfileIdentityV1(),
        .artifact_sha256 = controlledDisruptionArtifactIdentityV1(storage),
        .build_sha256 = config.build_sha256,
        .machine_sha256 = native_observer.machineIdentityV1(
            logical_cpu_count,
            device_sha256,
        ),
        .backend_sha256 = controlledDisruptionBackendIdentityV1(),
        .device_sha256 = device_sha256,
        .placement_sha256 = native_observer.placementIdentityV1(info),
        .host_source_sha256 = controlledDisruptionHostSourceIdentityV1(),
        .host_clock_sha256 = hostClockIdentityV1(),
        .device_source_sha256 = native_observer.sourceIdentityV1(),
        .device_clock_sha256 = deviceClockIdentityV1(),
        .challenge_sha256 = config.challenge_sha256,
    });
}

fn makeCancellationStormScenarioV1(
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
        .warmup_count = cancellation_storm_warmup_record_count,
        .measured_count = cancellation_storm_measured_record_count,
        .max_in_flight = flow_count,
        .queue_count = flow_count,
        .flow_count = flow_count,
        .workload_sha256 = cancellationStormWorkloadIdentityV1(),
        .profile_sha256 = cancellationStormProfileIdentityV1(),
        .artifact_sha256 = cancellationStormArtifactIdentityV1(storage),
        .build_sha256 = config.build_sha256,
        .machine_sha256 = native_observer.machineIdentityV1(
            logical_cpu_count,
            device_sha256,
        ),
        .backend_sha256 = cancellationStormBackendIdentityV1(),
        .device_sha256 = device_sha256,
        .placement_sha256 = native_observer.placementIdentityV1(info),
        .host_source_sha256 = cancellationStormHostSourceIdentityV1(),
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

fn validateDeviceAndPlacementIdentityV1(
    initial: metal.MetalDeviceInfo,
    current: metal.MetalDeviceInfo,
) !void {
    if (!std.mem.eql(
        u8,
        &native_observer.deviceIdentityV1(initial),
        &native_observer.deviceIdentityV1(current),
    ) or !std.mem.eql(
        u8,
        &native_observer.placementIdentityV1(initial),
        &native_observer.placementIdentityV1(current),
    ))
        return error.InvalidMetalIdentity;
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
    ordinal: usize,
    cohort: native_report.CohortV1,
    flow: usize,
    clock: *EventClockV1,
) !PendingRecordV1 {
    if (flow >= flow_count or
        storage.lanes[flow].request != null or
        storage.lanes[flow].pin != null or
        storage.lanes[flow].ticket != null)
        return error.InvalidLaneState;
    if (ordinal >= storage.records.len)
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
        .cohort = cohort,
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
    expected_acquisitions: u64,
    expected_completions: u64,
    pending: *const [flow_count]PendingRecordV1,
) !void {
    const coordinator_snapshot =
        try storage.coordinator.snapshot();
    const bank_snapshot = try storage.bank.snapshotV4();
    if (coordinator_snapshot.active_dispatches != flow_count or
        bank_snapshot.active_lease_pin_slots != flow_count or
        bank_snapshot.lease_pin_acquisitions !=
            expected_acquisitions or
        bank_snapshot.lease_pin_completions !=
            expected_completions or
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
    try observeLaneV1(
        storage,
        campaign_lease,
        flow,
        pending,
        clock,
    );
    pending.host.terminal = try clock.next();
}

fn observeLaneV1(
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
    expected_pin_count: u64,
    pending: *const [flow_count]PendingRecordV1,
) !void {
    const coordinator_snapshot =
        try storage.coordinator.snapshot();
    const bank_snapshot = try storage.bank.snapshotV4();
    if (coordinator_snapshot.active_dispatches != 0 or
        bank_snapshot.active_lease_pin_slots != 0 or
        bank_snapshot.lease_pin_acquisitions !=
            expected_pin_count or
        bank_snapshot.lease_pin_completions !=
            expected_pin_count or
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

fn disruptionCohortV1(
    epoch_index: usize,
) native_report.CohortV1 {
    return if (epoch_index <
        disruption_warmup_epoch_count)
        .warmup
    else
        .measured;
}

fn disruptionUnavailableTimingV1(
    scenario: native_report.ScenarioV1,
    epoch_index: usize,
    action: DisruptionActionV1,
) native_report.DeviceTimingV1 {
    return .{
        .availability = .unsupported,
        .source_sha256 = scenario.device_source_sha256,
        .clock_sha256 = scenario.device_clock_sha256,
        .reason_sha256 = controlledDisruptionRecordRootV1(
            scenario,
            epoch_index,
            action,
            .timing_unsupported,
        ),
    };
}

fn disruptionUnavailableAllocationV1(
    scenario: native_report.ScenarioV1,
    epoch_index: usize,
    action: DisruptionActionV1,
) native_report.AllocatedContextV1 {
    return .{
        .availability = .unsupported,
        .source_sha256 = scenario.device_source_sha256,
        .reason_sha256 = controlledDisruptionRecordRootV1(
            scenario,
            epoch_index,
            action,
            .allocation_unsupported,
        ),
    };
}

fn writeAdmittedDisruptionRecordV1(
    storage: *StorageV1,
    scenario: native_report.ScenarioV1,
    epoch_index: usize,
    ordinal: usize,
    action: DisruptionActionV1,
    detail: DisruptionActionDetailV1,
    outcome: native_report.OutcomeV1,
    flow: usize,
    host: native_report.HostEventsV1,
    request: metal_allocation.MetalMatvecDispatchRequestV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
    completion: lease_tree.LeaseTreeDispatchCompletionV1,
    action_evidence_sha256: Digest,
    bank_used_before: u64,
    bank_used_after: u64,
) !void {
    if (ordinal >= disruption_record_count or
        (outcome != .cancelled and outcome != .failed) or
        flow >= flow_count or
        digestIsZero(action_evidence_sha256) or
        host.presence_mask != disruption_admitted_presence or
        bank_used_before != persistent_device_bytes or
        bank_used_after != bank_used_before)
        return error.InvalidDisruptionRecord;
    const expected_shape =
        (action == .cancel_before_submit and
            detail == .cancelled_before_submit and
            outcome == .cancelled and flow == 0) or
        (action == .malformed_pre_submit and
            detail == .invalid_host_lengths and
            outcome == .failed and flow == 1);
    if (!expected_shape) return error.InvalidDisruptionRecord;
    const admitted_commitment =
        controlledDisruptionAdmittedCommitmentV1(
            scenario,
            epoch_index,
            action,
            detail,
            outcome,
            flow,
            request.request_sha256,
            pin.pin_sha256,
            terminal.terminal_sha256,
            completion.completion_sha256,
            action_evidence_sha256,
        );
    storage.records[ordinal] = try native_report.makeRecordV1(.{
        .ordinal = @intCast(ordinal),
        .cohort = disruptionCohortV1(epoch_index),
        .outcome = outcome,
        .correctness = .not_applicable,
        .fallback = false,
        .flow_id = @intCast(flow),
        .work_units = work_units_per_record,
        .adapter_queue_slot = 0,
        .host = host,
        .roots = .{
            .request_sha256 = request.request_sha256,
            .pin_sha256 = pin.pin_sha256,
            .terminal_sha256 = terminal.terminal_sha256,
            .completion_sha256 = completion.completion_sha256,
        },
        .device_timing = .{
            .availability = .unsupported,
            .source_sha256 = scenario.device_source_sha256,
            .clock_sha256 = scenario.device_clock_sha256,
            .reason_sha256 = admitted_commitment,
        },
        .allocated_context = .{
            .availability = .unsupported,
            .source_sha256 = scenario.device_source_sha256,
            .reason_sha256 = action_evidence_sha256,
        },
        .logical = .{
            .bank_acquisitions = 1,
            .bank_completions = 1,
            .bank_used_before = bank_used_before,
            .bank_used_after_settlement = bank_used_after,
            .pin_count_before = 1,
            .pin_count_after_settlement = 0,
            .dispatch_count_before = 0,
            .dispatch_count_after_settlement = 0,
            .native_command_count_before = 0,
            .native_command_count_after_settlement = 0,
        },
    });
}

fn runCancellationDisruptionV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    fixture: FixtureV1,
    scenario: native_report.ScenarioV1,
    epoch_index: usize,
    ordinal: usize,
    clock: *EventClockV1,
) !void {
    var host: native_report.HostEventsV1 = .{
        .presence_mask = disruption_admitted_presence,
    };
    host.arrival = try clock.next();
    const bank_before = try storage.bank.snapshotV4();
    const coordinator_before =
        try storage.coordinator.snapshot();
    if (bank_before.used.device_bytes !=
        persistent_device_bytes or
        bank_before.active_lease_pin_slots != 0 or
        coordinator_before.active_dispatches != 0 or
        try backend.nativeLiveCommandCount() != 0)
        return error.InvalidDisruptionBoundary;

    const attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings[0],
            storage.packed_weights.len,
            storage.scales.len,
            storage.inputs[0].len,
            storage.outputs[0].len,
            group_size,
            in_features,
            out_features,
        );
    const request =
        try storage.adapter.prepareMatvecDispatchRequestV1(
            attempt,
        );
    if (request.request_generation !=
        @as(u64, @intCast(epoch_index * 4 + 1)))
        return error.InvalidRequestGeneration;
    const pin = try storage.coordinator.acquireDispatchPin(
        campaign_lease,
        storage.adapter.dispatchInterface(),
        request.request_sha256,
    );
    try lease_tree.validateDispatchPinV1(pin);
    host.admission = try clock.next();
    const bank_acquired = try storage.bank.snapshotV4();
    if (bank_acquired.lease_pin_acquisitions !=
        bank_before.lease_pin_acquisitions + 1 or
        bank_acquired.lease_pin_completions !=
            bank_before.lease_pin_completions or
        bank_acquired.active_lease_pin_slots != 1 or
        bank_acquired.used.device_bytes !=
            bank_before.used.device_bytes or
        (try storage.coordinator.snapshot())
            .active_dispatches != 1 or
        try backend.nativeLiveCommandCount() != 0)
        return error.InvalidBankPinFacts;

    const terminal =
        try storage.adapter.cancelMatvecBeforeSubmitObserved(
            campaign_lease,
            pin,
        );
    try lease_tree.validateDispatchTerminalForPinV1(
        terminal,
        pin,
    );
    if (terminal.outcome != .cancelled_before_submit)
        return error.InvalidDisruptionOutcome;
    host.terminal = try clock.next();
    const completion =
        try storage.coordinator.completeDispatchPin(
            pin,
            storage.adapter.dispatchInterface(),
            terminal,
        );
    try lease_tree.validateDispatchCompletionForPinV1(
        completion,
        pin,
        terminal,
    );
    try storage.adapter.acknowledgeDispatchCompletion(
        completion,
    );
    host.settlement = try clock.next();
    const bank_after = try storage.bank.snapshotV4();
    if (bank_after.lease_pin_acquisitions !=
        bank_acquired.lease_pin_acquisitions or
        bank_after.lease_pin_completions !=
            bank_acquired.lease_pin_completions + 1 or
        bank_after.active_lease_pin_slots != 0 or
        (try storage.coordinator.snapshot())
            .active_dispatches != 0 or
        try backend.nativeLiveCommandCount() != 0)
        return error.InvalidSettlementFacts;
    try writeAdmittedDisruptionRecordV1(
        storage,
        scenario,
        epoch_index,
        ordinal,
        .cancel_before_submit,
        .cancelled_before_submit,
        .cancelled,
        0,
        host,
        request,
        pin,
        terminal,
        completion,
        controlledDisruptionRecordRootV1(
            scenario,
            epoch_index,
            .cancel_before_submit,
            .action_evidence,
        ),
        bank_before.used.device_bytes,
        bank_after.used.device_bytes,
    );
}

fn runMalformedRejectionDisruptionV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    fixture: FixtureV1,
    scenario: native_report.ScenarioV1,
    epoch_index: usize,
    ordinal: usize,
    clock: *EventClockV1,
) !void {
    var host: native_report.HostEventsV1 = .{
        .presence_mask = disruption_admitted_presence,
    };
    host.arrival = try clock.next();
    const bank_before = try storage.bank.snapshotV4();
    if (bank_before.used.device_bytes !=
        persistent_device_bytes or
        bank_before.active_lease_pin_slots != 0 or
        (try storage.coordinator.snapshot())
            .active_dispatches != 0 or
        try backend.nativeLiveCommandCount() != 0)
        return error.InvalidDisruptionBoundary;

    const malformed_output =
        storage.outputs[1][0 .. out_features - 1];
    const attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings[1],
            storage.packed_weights.len,
            storage.scales.len,
            storage.inputs[1].len,
            malformed_output.len,
            group_size,
            in_features,
            out_features,
        );
    const request =
        try storage.adapter.prepareMatvecDispatchRequestV1(
            attempt,
        );
    if (request.request_generation !=
        @as(u64, @intCast(epoch_index * 4 + 2)))
        return error.InvalidRequestGeneration;
    const pin = try storage.coordinator.acquireDispatchPin(
        campaign_lease,
        storage.adapter.dispatchInterface(),
        request.request_sha256,
    );
    try lease_tree.validateDispatchPinV1(pin);
    host.admission = try clock.next();
    const bank_acquired = try storage.bank.snapshotV4();
    if (bank_acquired.lease_pin_acquisitions !=
        bank_before.lease_pin_acquisitions + 1 or
        bank_acquired.lease_pin_completions !=
            bank_before.lease_pin_completions or
        bank_acquired.active_lease_pin_slots != 1 or
        bank_acquired.used.device_bytes !=
            bank_before.used.device_bytes or
        (try storage.coordinator.snapshot())
            .active_dispatches != 1 or
        try backend.nativeLiveCommandCount() != 0)
        return error.InvalidBankPinFacts;

    const rejected =
        try storage.adapter.rejectMatvecInt4BeforeSubmitObserved(
            campaign_lease,
            pin,
            fixture.bindings[1],
            &storage.packed_weights,
            &storage.scales,
            &storage.inputs[1],
            malformed_output,
            group_size,
            in_features,
            out_features,
        );
    try metal_allocation
        .validateMetalMatvecPreSubmitRejectionForPinV1(
        rejected.rejection,
        pin,
        rejected.terminal,
    );
    if (rejected.rejection.reason != .invalid_host_lengths or
        rejected.terminal.outcome != .rejected_before_submit)
        return error.InvalidDisruptionOutcome;
    host.terminal = try clock.next();
    const completion =
        try storage.coordinator.completeDispatchPin(
            pin,
            storage.adapter.dispatchInterface(),
            rejected.terminal,
        );
    try lease_tree.validateDispatchCompletionForPinV1(
        completion,
        pin,
        rejected.terminal,
    );
    try storage.adapter.acknowledgeDispatchCompletion(
        completion,
    );
    host.settlement = try clock.next();
    const bank_after = try storage.bank.snapshotV4();
    if (bank_after.lease_pin_acquisitions !=
        bank_acquired.lease_pin_acquisitions or
        bank_after.lease_pin_completions !=
            bank_acquired.lease_pin_completions + 1 or
        bank_after.active_lease_pin_slots != 0 or
        (try storage.coordinator.snapshot())
            .active_dispatches != 0 or
        try backend.nativeLiveCommandCount() != 0)
        return error.InvalidSettlementFacts;
    try writeAdmittedDisruptionRecordV1(
        storage,
        scenario,
        epoch_index,
        ordinal,
        .malformed_pre_submit,
        .invalid_host_lengths,
        .failed,
        1,
        host,
        request,
        pin,
        rejected.terminal,
        completion,
        rejected.rejection.rejection_sha256,
        bank_before.used.device_bytes,
        bank_after.used.device_bytes,
    );
}

fn startControlledPairV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    fixture: FixtureV1,
    epoch_index: usize,
    ordinal_base: usize,
    clock: *EventClockV1,
) ![flow_count]PendingRecordV1 {
    var pending: [flow_count]PendingRecordV1 = undefined;
    for (0..flow_count) |flow| {
        if (storage.lanes[flow].request != null or
            storage.lanes[flow].pin != null or
            storage.lanes[flow].ticket != null)
            return error.InvalidLaneState;
        storage.outputs[flow] =
            [_]f32{-8_765.25} ** out_features;
        pending[flow] = .{
            .ordinal = @intCast(ordinal_base + flow),
            .cohort = disruptionCohortV1(epoch_index),
            .flow_id = @intCast(flow),
            .request = undefined,
            .pin = undefined,
            .ticket = undefined,
        };
        pending[flow].host.arrival = try clock.next();
    }

    for (0..flow_count) |flow| {
        const bank_before = try storage.bank.snapshotV4();
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
        if (request.request_generation !=
            @as(
                u64,
                @intCast(epoch_index * 4 + 3 + flow),
            ))
            return error.InvalidRequestGeneration;
        storage.lanes[flow].request = request;
        const pin = try storage.coordinator.acquireDispatchPin(
            campaign_lease,
            storage.adapter.dispatchInterface(),
            request.request_sha256,
        );
        storage.lanes[flow].pin = pin;
        try lease_tree.validateDispatchPinV1(pin);
        pending[flow].host.admission = try clock.next();
        const bank_after = try storage.bank.snapshotV4();
        if (bank_after.lease_pin_acquisitions !=
            bank_before.lease_pin_acquisitions + 1 or
            bank_after.lease_pin_completions !=
                bank_before.lease_pin_completions or
            bank_after.active_lease_pin_slots != flow + 1 or
            bank_after.used.device_bytes !=
                bank_before.used.device_bytes)
            return error.InvalidBankPinFacts;
        pending[flow].request = request;
        pending[flow].pin = pin;
        pending[flow].bank_used_before =
            bank_before.used.device_bytes;
    }

    // Service entry is recorded for both admitted lanes before either
    // submission returns. This makes the fixed two-lane schedule explicit
    // without claiming physical command overlap.
    for (0..flow_count) |flow| {
        pending[flow].host.first_service =
            try clock.next();
    }
    for (0..flow_count) |flow| {
        const ticket =
            try storage.adapter.submitMatvecInt4AsyncObserved(
                campaign_lease,
                pending[flow].pin,
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
        pending[flow].ticket = ticket;
        pending[flow].host.submit_return =
            try clock.next();
        try metal_allocation
            .validateMetalAsyncDispatchTicketV1(ticket);
        if (ticket.ticket_generation !=
            @as(
                u64,
                @intCast(epoch_index * 2 + 1 + flow),
            ) or ticket.queue_slot != flow or
            !std.meta.eql(
                storage.adapter
                    .currentAsyncDispatchTicketForQueueSlotV1(
                    flow,
                ) orelse return error.InvalidLaneState,
                ticket,
            ) or storage.adapter
            .currentAsyncDispatchQuarantineForQueueSlotV1(
            flow,
        ) != null)
            return error.InvalidLaneState;
    }

    if ((try storage.coordinator.snapshot())
        .active_dispatches != flow_count or
        (try storage.bank.snapshotV4())
            .active_lease_pin_slots != flow_count or
        try backend.nativeLiveCommandCount() != flow_count or
        pending[0].request.request_generation >=
            pending[1].request.request_generation or
        pending[0].pin.dispatch_generation >=
            pending[1].pin.dispatch_generation or
        pending[0].ticket.ticket_generation >=
            pending[1].ticket.ticket_generation)
        return error.InvalidPairOwnership;
    return pending;
}

fn runCapacityDisruptionV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    fixture: FixtureV1,
    scenario: native_report.ScenarioV1,
    epoch_index: usize,
    ordinal: usize,
    pending: *const [flow_count]PendingRecordV1,
    clock: *EventClockV1,
) !void {
    var host: native_report.HostEventsV1 = .{
        .presence_mask = native_report.capacity_rejected_presence,
    };
    host.arrival = try clock.next();

    const adapter_before = storage.adapter.snapshot();
    const generations_before =
        storage.adapter.dispatchGenerationSnapshotV1();
    const expected_generations: metal_allocation.MetalDispatchGenerationSnapshotV1 = .{
        .next_request_generation = @intCast(epoch_index * 4 + 5),
        .next_ticket_generation = @intCast(epoch_index * 2 + 3),
    };
    if (!std.meta.eql(
        generations_before,
        expected_generations,
    ))
        return error.InvalidRequestGeneration;
    const bank_before = try storage.bank.snapshotV4();
    const coordinator_before =
        try storage.coordinator.snapshot();
    const native_commands_before =
        try backend.nativeLiveCommandCount();
    const native_buffers_before =
        try backend.nativeLiveBufferCount();
    const logical_buffers_before =
        backend.liveBufferCount();
    const completed_before =
        backend.completedDispatchCount();
    const tickets_before = [flow_count]metal_allocation.MetalAsyncDispatchTicketV1{
        storage.adapter
            .currentAsyncDispatchTicketForQueueSlotV1(0) orelse
            return error.InvalidLaneState,
        storage.adapter
            .currentAsyncDispatchTicketForQueueSlotV1(1) orelse
            return error.InvalidLaneState,
    };
    if (!std.meta.eql(tickets_before[0], pending[0].ticket) or
        !std.meta.eql(tickets_before[1], pending[1].ticket) or
        native_commands_before != flow_count)
        return error.InvalidPairOwnership;

    const distinct_attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings[0],
            storage.packed_weights.len,
            storage.scales.len,
            storage.inputs[0].len,
            out_features - 2,
            group_size,
            in_features,
            out_features,
        );
    if (storage.adapter.prepareMatvecDispatchRequestV1(
        distinct_attempt,
    )) |_| {
        return error.CapacityAttemptUnexpectedlyAdmitted;
    } else |err| switch (err) {
        error.DispatchBusy => {},
        else => return err,
    }
    const generations_after =
        storage.adapter.dispatchGenerationSnapshotV1();
    if (!std.meta.eql(
        generations_before,
        generations_after,
    ) or !std.meta.eql(
        generations_after,
        expected_generations,
    ))
        return error.CapacityRejectionMutatedState;
    host.terminal = try clock.next();

    const adapter_after = storage.adapter.snapshot();
    const bank_after = try storage.bank.snapshotV4();
    const coordinator_after =
        try storage.coordinator.snapshot();
    const tickets_after = [flow_count]metal_allocation.MetalAsyncDispatchTicketV1{
        storage.adapter
            .currentAsyncDispatchTicketForQueueSlotV1(0) orelse
            return error.InvalidLaneState,
        storage.adapter
            .currentAsyncDispatchTicketForQueueSlotV1(1) orelse
            return error.InvalidLaneState,
    };
    if (!std.meta.eql(adapter_before, adapter_after) or
        !std.meta.eql(bank_before, bank_after) or
        !std.meta.eql(
            coordinator_before,
            coordinator_after,
        ) or !std.meta.eql(tickets_before, tickets_after) or
        try backend.nativeLiveCommandCount() !=
            native_commands_before or
        try backend.nativeLiveBufferCount() !=
            native_buffers_before or
        backend.liveBufferCount() !=
            logical_buffers_before or
        backend.completedDispatchCount() != completed_before)
        return error.CapacityRejectionMutatedState;
    host.settlement = try clock.next();

    storage.records[ordinal] = try native_report.makeRecordV1(.{
        .ordinal = @intCast(ordinal),
        .cohort = disruptionCohortV1(epoch_index),
        .outcome = .capacity_rejected,
        .correctness = .not_applicable,
        .fallback = false,
        .flow_id = 0,
        .work_units = work_units_per_record,
        .adapter_queue_slot = native_report.no_queue_slot,
        .host = host,
        .roots = .{
            .request_sha256 = controlledDisruptionCapacityRootV1(
                scenario,
                epoch_index,
                .request,
                generations_before,
            ),
            .terminal_sha256 = controlledDisruptionCapacityRootV1(
                scenario,
                epoch_index,
                .terminal,
                generations_before,
            ),
            .completion_sha256 = controlledDisruptionCapacityRootV1(
                scenario,
                epoch_index,
                .completion,
                generations_before,
            ),
        },
        .device_timing = disruptionUnavailableTimingV1(
            scenario,
            epoch_index,
            .full_capacity_rejection,
        ),
        .allocated_context = disruptionUnavailableAllocationV1(
            scenario,
            epoch_index,
            .full_capacity_rejection,
        ),
    });
}

fn validateControlledEpochScheduleV1(
    storage: *const StorageV1,
    epoch_index: usize,
) !void {
    const base = epoch_index *
        disruption_records_per_epoch;
    const sequence_base: u64 = epoch_index * 25;
    const cancelled = storage.records[base];
    const rejected = storage.records[base + 1];
    const lane_a = storage.records[base + 2];
    const lane_b = storage.records[base + 3];
    const capacity = storage.records[base + 4];
    const expected = [_]u64{
        cancelled.host.arrival.sequence,
        cancelled.host.admission.sequence,
        cancelled.host.terminal.sequence,
        cancelled.host.settlement.sequence,
        rejected.host.arrival.sequence,
        rejected.host.admission.sequence,
        rejected.host.terminal.sequence,
        rejected.host.settlement.sequence,
        lane_a.host.arrival.sequence,
        lane_b.host.arrival.sequence,
        lane_a.host.admission.sequence,
        lane_b.host.admission.sequence,
        lane_a.host.first_service.sequence,
        lane_b.host.first_service.sequence,
        lane_a.host.submit_return.sequence,
        lane_b.host.submit_return.sequence,
        capacity.host.arrival.sequence,
        capacity.host.terminal.sequence,
        capacity.host.settlement.sequence,
        lane_a.host.first_output.sequence,
        lane_b.host.first_output.sequence,
        lane_a.host.terminal.sequence,
        lane_b.host.terminal.sequence,
        lane_b.host.settlement.sequence,
        lane_a.host.settlement.sequence,
    };
    for (expected, 0..) |actual, offset| {
        if (actual != sequence_base + offset + 1)
            return error.InvalidEventSequence;
    }
    if (cancelled.outcome != .cancelled or
        cancelled.flow_id != 0 or
        cancelled.adapter_queue_slot != 0 or
        rejected.outcome != .failed or
        rejected.flow_id != 1 or
        rejected.adapter_queue_slot != 0 or
        lane_a.outcome != .completed or
        lane_a.flow_id != 0 or
        lane_a.adapter_queue_slot != 0 or
        lane_b.outcome != .completed or
        lane_b.flow_id != 1 or
        lane_b.adapter_queue_slot != 1 or
        capacity.outcome != .capacity_rejected or
        capacity.flow_id != 0 or
        capacity.adapter_queue_slot !=
            native_report.no_queue_slot)
        return error.InvalidDisruptionOutcome;
}

fn validateControlledEpochBoundaryV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    initial_lifecycle: metal.MetalDeviceLifecycleSnapshot,
    initial_device: metal.MetalDeviceInfo,
    epoch_index: usize,
    completed_dispatches_before: u64,
) !void {
    try validateLifecycleSnapshot(
        backend,
        initial_lifecycle,
        try backend.deviceLifecycleSnapshot(),
    );
    try validateDeviceAndPlacementIdentityV1(
        initial_device,
        try backend.deviceInfo(),
    );
    const adapter_snapshot = storage.adapter.snapshot();
    const bank_snapshot = try storage.bank.snapshotV4();
    const coordinator_snapshot =
        try storage.coordinator.snapshot();
    const expected_pin_count: u64 =
        (epoch_index + 1) * 4;
    if (adapter_snapshot.live_objects != flow_count * 4 or
        adapter_snapshot.materialized_leases != 1 or
        adapter_snapshot.used_resource_bytes !=
            persistent_device_bytes or
        backend.liveBufferCount() != flow_count * 4 or
        try backend.nativeLiveBufferCount() !=
            flow_count * 4 or
        try backend.nativeLiveCommandCount() != 0 or
        bank_snapshot.used.device_bytes !=
            persistent_device_bytes or
        bank_snapshot.active_lease_pin_slots != 0 or
        bank_snapshot.lease_pin_acquisitions !=
            expected_pin_count or
        bank_snapshot.lease_pin_completions !=
            expected_pin_count or
        !coordinator_snapshot.live_lease or
        coordinator_snapshot.active_dispatches != 0 or
        backend.completedDispatchCount() !=
            completed_dispatches_before +
                (epoch_index + 1) * flow_count or
        backend.compatibilityUnresolvedSubmission() != null)
        return error.InvalidDisruptionBoundary;
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

fn runControlledDisruptionEpochsV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    fixture: FixtureV1,
    scenario: native_report.ScenarioV1,
    initial_lifecycle: metal.MetalDeviceLifecycleSnapshot,
    initial_device: metal.MetalDeviceInfo,
    recommended_max_working_set_size: u64,
    completed_dispatches_before: u64,
    epoch_start_spacing_ns: u64,
    clock: *EventClockV1,
) !void {
    if (recommended_max_working_set_size == 0)
        return error.InvalidAllocatedContext;
    var allocated_context_high_water: u64 = 0;
    for (0..disruption_epoch_count) |epoch_index| {
        try waitForControlledEpochStartV1(
            clock,
            epoch_index,
            epoch_start_spacing_ns,
        );
        const base = epoch_index *
            disruption_records_per_epoch;
        try runCancellationDisruptionV1(
            storage,
            backend,
            campaign_lease,
            fixture,
            scenario,
            epoch_index,
            base,
            clock,
        );
        try runMalformedRejectionDisruptionV1(
            storage,
            backend,
            campaign_lease,
            fixture,
            scenario,
            epoch_index,
            base + 1,
            clock,
        );
        var pending = try startControlledPairV1(
            storage,
            backend,
            campaign_lease,
            fixture,
            epoch_index,
            base + 2,
            clock,
        );
        const bank_active = try storage.bank.snapshotV4();
        if (bank_active.lease_pin_acquisitions !=
            epoch_index * 4 + 4 or
            bank_active.lease_pin_completions !=
                epoch_index * 4 + 2)
            return error.InvalidBankPinFacts;
        try runCapacityDisruptionV1(
            storage,
            backend,
            fixture,
            scenario,
            epoch_index,
            base + 4,
            &pending,
            clock,
        );

        // Observe A then B, publish terminals A then B, and deliberately
        // settle B before A.
        for (0..flow_count) |flow| {
            try observeLaneV1(
                storage,
                campaign_lease,
                flow,
                &pending[flow],
                clock,
            );
        }
        for (0..flow_count) |flow| {
            pending[flow].host.terminal =
                try clock.next();
        }
        var reverse_flow: usize = flow_count;
        while (reverse_flow != 0) {
            reverse_flow -= 1;
            try settleLaneV1(
                storage,
                backend,
                scenario,
                reverse_flow,
                &pending[reverse_flow],
                clock,
            );
        }
        try validatePairSettledV1(
            storage,
            backend,
            (epoch_index + 1) * 4,
            &pending,
        );

        for (0..flow_count) |flow| {
            const allocated =
                storage.records[base + 2 + flow]
                    .allocated_context;
            if (allocated.availability != .present or
                allocated.before_bytes == 0 or
                allocated.after_bytes == 0 or
                allocated.before_bytes >
                    recommended_max_working_set_size or
                allocated.after_bytes >
                    recommended_max_working_set_size)
                return error.InvalidAllocatedContext;
            allocated_context_high_water = @max(
                allocated_context_high_water,
                @max(
                    allocated.before_bytes,
                    allocated.after_bytes,
                ),
            );
        }
        try validateControlledEpochScheduleV1(
            storage,
            epoch_index,
        );
        try validateControlledEpochBoundaryV1(
            storage,
            backend,
            initial_lifecycle,
            initial_device,
            epoch_index,
            completed_dispatches_before,
        );
    }
    if (allocated_context_high_water == 0 or
        allocated_context_high_water >
            recommended_max_working_set_size)
        return error.InvalidAllocatedContext;
}

fn cancellationStormCohortV1(
    block_index: usize,
) native_report.CohortV1 {
    return if (block_index <
        cancellation_storm_warmup_block_count)
        .warmup
    else
        .measured;
}

fn cancellationStormCancelActionV1(
    lane: usize,
) !CancellationStormActionV1 {
    return switch (lane) {
        0 => .cancel_lane0,
        1 => .cancel_lane1,
        else => error.InvalidLaneState,
    };
}

fn cancellationStormControlActionV1(
    lane: usize,
) !CancellationStormActionV1 {
    return switch (lane) {
        0 => .completed_lane0,
        1 => .completed_lane1,
        else => error.InvalidLaneState,
    };
}

fn cancellationStormSettlementFirstLaneV1(
    challenge_sha256: Digest,
    global_wave: usize,
) usize {
    const byte_index = global_wave / 8;
    const bit_index: u3 = @intCast(global_wave % 8);
    return (challenge_sha256[byte_index] >> bit_index) & 1;
}

fn prepareCancellationStormWaveV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    fixture: FixtureV1,
    block_index: usize,
    wave_index: usize,
    clock: *EventClockV1,
) ![flow_count]CancellationStormPendingV1 {
    const prior_pins =
        block_index * 18 + wave_index * flow_count;
    const bank_before = try storage.bank.snapshotV4();
    const coordinator_before =
        try storage.coordinator.snapshot();
    if (bank_before.used.device_bytes !=
        persistent_device_bytes or
        bank_before.active_lease_pin_slots != 0 or
        bank_before.lease_pin_acquisitions != prior_pins or
        bank_before.lease_pin_completions != prior_pins or
        coordinator_before.active_dispatches != 0 or
        try backend.nativeLiveCommandCount() != 0)
        return error.InvalidCancellationStormBoundary;

    var pending: [flow_count]CancellationStormPendingV1 =
        undefined;
    for (0..flow_count) |lane| {
        if (storage.lanes[lane].request != null or
            storage.lanes[lane].pin != null or
            storage.lanes[lane].ticket != null)
            return error.InvalidLaneState;
        pending[lane] = .{
            .request = undefined,
            .pin = undefined,
        };
        pending[lane].host.arrival = try clock.next();
    }

    for (0..flow_count) |lane| {
        const attempt =
            try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
                fixture.bindings[lane],
                storage.packed_weights.len,
                storage.scales.len,
                storage.inputs[lane].len,
                storage.outputs[lane].len,
                group_size,
                in_features,
                out_features,
            );
        const request =
            try storage.adapter.prepareMatvecDispatchRequestV1(
                attempt,
            );
        const expected_request_generation: u64 =
            @intCast(
                block_index * 18 +
                    wave_index * flow_count +
                    lane +
                    1,
            );
        if (request.request_generation !=
            expected_request_generation)
            return error.InvalidRequestGeneration;
        storage.lanes[lane].request = request;
        const pin = try storage.coordinator.acquireDispatchPin(
            campaign_lease,
            storage.adapter.dispatchInterface(),
            request.request_sha256,
        );
        try lease_tree.validateDispatchPinV1(pin);
        if (pin.dispatch_generation !=
            expected_request_generation)
            return error.InvalidDispatchGeneration;
        storage.lanes[lane].pin = pin;
        pending[lane].request = request;
        pending[lane].pin = pin;
        pending[lane].host.admission = try clock.next();

        const bank_after = try storage.bank.snapshotV4();
        if (bank_after.lease_pin_acquisitions !=
            prior_pins + lane + 1 or
            bank_after.lease_pin_completions != prior_pins or
            bank_after.active_lease_pin_slots != lane + 1 or
            bank_after.used.device_bytes !=
                persistent_device_bytes or
            (try storage.coordinator.snapshot())
                .active_dispatches != lane + 1 or
            try backend.nativeLiveCommandCount() != 0)
            return error.InvalidBankPinFacts;
    }

    const generations =
        storage.adapter.dispatchGenerationSnapshotV1();
    const expected_generations: metal_allocation.MetalDispatchGenerationSnapshotV1 = .{
        .next_request_generation = @intCast(
            block_index * 18 +
                wave_index * flow_count +
                3,
        ),
        .next_ticket_generation = @intCast(block_index * flow_count + 1),
    };
    if (!std.meta.eql(generations, expected_generations))
        return error.InvalidRequestGeneration;
    return pending;
}

fn writeCancellationStormCapacityRecordV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    fixture: FixtureV1,
    scenario: native_report.ScenarioV1,
    block_index: usize,
    wave_index: usize,
    ordinal: usize,
    clock: *EventClockV1,
) !void {
    const global_wave =
        block_index * cancellation_storm_waves_per_block +
        wave_index;
    const probe_flow = global_wave & 1;
    var host: native_report.HostEventsV1 = .{
        .presence_mask = native_report.capacity_rejected_presence,
    };
    host.arrival = try clock.next();

    const adapter_before = storage.adapter.snapshot();
    const generations_before =
        storage.adapter.dispatchGenerationSnapshotV1();
    const expected_generations: metal_allocation.MetalDispatchGenerationSnapshotV1 = .{
        .next_request_generation = @intCast(
            block_index * 18 +
                wave_index * flow_count +
                3,
        ),
        .next_ticket_generation = @intCast(block_index * flow_count + 1),
    };
    if (!std.meta.eql(
        generations_before,
        expected_generations,
    ))
        return error.InvalidRequestGeneration;
    const bank_before = try storage.bank.snapshotV4();
    const coordinator_before =
        try storage.coordinator.snapshot();
    const native_commands_before =
        try backend.nativeLiveCommandCount();
    const native_buffers_before =
        try backend.nativeLiveBufferCount();
    const logical_buffers_before =
        backend.liveBufferCount();
    const completed_before =
        backend.completedDispatchCount();
    if (bank_before.active_lease_pin_slots != flow_count or
        coordinator_before.active_dispatches != flow_count or
        native_commands_before != 0)
        return error.InvalidCancellationStormBoundary;

    const distinct_attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings[probe_flow],
            storage.packed_weights.len,
            storage.scales.len,
            storage.inputs[probe_flow].len,
            out_features - 2,
            group_size,
            in_features,
            out_features,
        );
    if (storage.adapter.prepareMatvecDispatchRequestV1(
        distinct_attempt,
    )) |_| {
        return error.CapacityAttemptUnexpectedlyAdmitted;
    } else |err| switch (err) {
        error.DispatchBusy => {},
        else => return err,
    }
    host.terminal = try clock.next();

    const adapter_after = storage.adapter.snapshot();
    const generations_after =
        storage.adapter.dispatchGenerationSnapshotV1();
    const bank_after = try storage.bank.snapshotV4();
    const coordinator_after =
        try storage.coordinator.snapshot();
    if (!std.meta.eql(adapter_before, adapter_after) or
        !std.meta.eql(
            generations_before,
            generations_after,
        ) or !std.meta.eql(bank_before, bank_after) or
        !std.meta.eql(
            coordinator_before,
            coordinator_after,
        ) or try backend.nativeLiveCommandCount() !=
        native_commands_before or
        try backend.nativeLiveBufferCount() !=
            native_buffers_before or
        backend.liveBufferCount() !=
            logical_buffers_before or
        backend.completedDispatchCount() != completed_before)
        return error.CapacityRejectionMutatedState;
    host.settlement = try clock.next();

    storage.records[ordinal] = try native_report.makeRecordV1(.{
        .ordinal = @intCast(ordinal),
        .cohort = cancellationStormCohortV1(block_index),
        .outcome = .capacity_rejected,
        .correctness = .not_applicable,
        .fallback = false,
        .flow_id = @intCast(probe_flow),
        .work_units = work_units_per_record,
        .adapter_queue_slot = native_report.no_queue_slot,
        .host = host,
        .roots = .{
            .request_sha256 = cancellationStormCapacityRootV1(
                scenario,
                block_index,
                wave_index,
                probe_flow,
                .request,
                generations_before,
            ),
            .terminal_sha256 = cancellationStormCapacityRootV1(
                scenario,
                block_index,
                wave_index,
                probe_flow,
                .terminal,
                generations_before,
            ),
            .completion_sha256 = cancellationStormCapacityRootV1(
                scenario,
                block_index,
                wave_index,
                probe_flow,
                .completion,
                generations_before,
            ),
        },
        .device_timing = .{
            .availability = .unsupported,
            .source_sha256 = scenario.device_source_sha256,
            .clock_sha256 = scenario.device_clock_sha256,
            .reason_sha256 = cancellationStormCapacityRootV1(
                scenario,
                block_index,
                wave_index,
                probe_flow,
                .timing_unsupported,
                generations_before,
            ),
        },
        .allocated_context = .{
            .availability = .unsupported,
            .source_sha256 = scenario.device_source_sha256,
            .reason_sha256 = cancellationStormCapacityRootV1(
                scenario,
                block_index,
                wave_index,
                probe_flow,
                .allocation_unsupported,
                generations_before,
            ),
        },
    });
}

fn writeCancellationStormCancelledRecordV1(
    storage: *StorageV1,
    scenario: native_report.ScenarioV1,
    block_index: usize,
    wave_index: usize,
    ordinal: usize,
    lane: usize,
    terminal_rank: usize,
    pending: CancellationStormPendingV1,
) !void {
    const terminal = pending.terminal orelse
        return error.InvalidCancellationStormOutcome;
    const completion = pending.completion orelse
        return error.InvalidCancellationStormOutcome;
    const action = try cancellationStormCancelActionV1(lane);
    const action_evidence_sha256 =
        cancellationStormRecordRootV1(
            scenario,
            block_index,
            wave_index,
            action,
            lane,
            .action_evidence,
        );
    const admitted_commitment =
        cancellationStormAdmittedCommitmentV1(
            scenario,
            block_index,
            wave_index,
            action,
            lane,
            terminal_rank,
            .cancelled,
            pending.request.request_sha256,
            pending.pin.pin_sha256,
            terminal.terminal_sha256,
            completion.completion_sha256,
            action_evidence_sha256,
        );
    storage.records[ordinal] = try native_report.makeRecordV1(.{
        .ordinal = @intCast(ordinal),
        .cohort = cancellationStormCohortV1(block_index),
        .outcome = .cancelled,
        .correctness = .not_applicable,
        .fallback = false,
        .flow_id = @intCast(lane),
        .work_units = work_units_per_record,
        .adapter_queue_slot = @intCast(lane),
        .host = pending.host,
        .roots = .{
            .request_sha256 = pending.request.request_sha256,
            .pin_sha256 = pending.pin.pin_sha256,
            .terminal_sha256 = terminal.terminal_sha256,
            .completion_sha256 = completion.completion_sha256,
        },
        .device_timing = .{
            .availability = .unsupported,
            .source_sha256 = scenario.device_source_sha256,
            .clock_sha256 = scenario.device_clock_sha256,
            .reason_sha256 = admitted_commitment,
        },
        .allocated_context = .{
            .availability = .unsupported,
            .source_sha256 = scenario.device_source_sha256,
            .reason_sha256 = action_evidence_sha256,
        },
        .logical = .{
            .bank_acquisitions = 1,
            .bank_completions = 1,
            .bank_used_before = persistent_device_bytes,
            .bank_used_after_settlement = persistent_device_bytes,
            .pin_count_before = 1,
            .pin_count_after_settlement = 0,
            .dispatch_count_before = 0,
            .dispatch_count_after_settlement = 0,
            .native_command_count_before = 0,
            .native_command_count_after_settlement = 0,
        },
    });
}

fn runCancellationStormConcurrentCancellationV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    scenario: native_report.ScenarioV1,
    block_index: usize,
    wave_index: usize,
    ordinal_base: usize,
    challenge_sha256: Digest,
    pending: *[flow_count]CancellationStormPendingV1,
    clock: *EventClockV1,
) !void {
    if (try backend.nativeLiveCommandCount() != 0)
        return error.InvalidCancellationStormBoundary;
    const completed_before =
        backend.completedDispatchCount();
    var ready = std.atomic.Value(usize).init(0);
    var release = std.atomic.Value(bool).init(false);
    var workers: [flow_count]CancellationStormWorkerV1 =
        undefined;
    for (&workers, 0..) |*worker, lane| {
        worker.* = .{
            .adapter = &storage.adapter,
            .lease = campaign_lease,
            .pin = pending[lane].pin,
            .clock = clock,
            .ready = &ready,
            .release = &release,
        };
    }

    var threads: [flow_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        release.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&threads, 0..) |*thread, lane| {
        thread.* = try std.Thread.spawn(
            .{},
            CancellationStormWorkerV1.run,
            .{&workers[lane]},
        );
        spawned += 1;
    }
    while (ready.load(.acquire) != flow_count)
        std.atomic.spinLoopHint();
    release.store(true, .release);
    for (&threads) |*thread| thread.join();
    spawned = 0;

    for (&workers, 0..) |*worker, lane| {
        if (worker.failure) |err| return err;
        const terminal = worker.terminal orelse
            return error.InvalidCancellationStormOutcome;
        try lease_tree.validateDispatchTerminalForPinV1(
            terminal,
            pending[lane].pin,
        );
        if (terminal.outcome != .cancelled_before_submit or
            worker.observed_return.sequence == 0)
            return error.InvalidCancellationStormOutcome;
        pending[lane].terminal = terminal;
        pending[lane].host.terminal =
            worker.observed_return;
    }
    if (pending[0].host.terminal.sequence ==
        pending[1].host.terminal.sequence or
        try backend.nativeLiveCommandCount() != 0 or
        backend.completedDispatchCount() != completed_before)
        return error.InvalidCancellationStormOutcome;

    const terminal_ranks = [flow_count]usize{
        if (pending[0].host.terminal.sequence <
            pending[1].host.terminal.sequence) 0 else 1,
        if (pending[1].host.terminal.sequence <
            pending[0].host.terminal.sequence) 0 else 1,
    };
    const global_wave =
        block_index * cancellation_storm_waves_per_block +
        wave_index;
    const first_lane =
        cancellationStormSettlementFirstLaneV1(
            challenge_sha256,
            global_wave,
        );
    const settlement_order =
        [flow_count]usize{ first_lane, first_lane ^ 1 };
    for (settlement_order) |lane| {
        const terminal = pending[lane].terminal.?;
        const completion =
            try storage.coordinator.completeDispatchPin(
                pending[lane].pin,
                storage.adapter.dispatchInterface(),
                terminal,
            );
        try lease_tree.validateDispatchCompletionForPinV1(
            completion,
            pending[lane].pin,
            terminal,
        );
        try storage.adapter.acknowledgeDispatchCompletion(
            completion,
        );
        pending[lane].completion = completion;
        pending[lane].host.settlement = try clock.next();
        storage.lanes[lane] = .{};
    }

    const expected_pins =
        block_index * 18 + wave_index * flow_count +
        flow_count;
    const bank_after = try storage.bank.snapshotV4();
    const coordinator_after =
        try storage.coordinator.snapshot();
    if (bank_after.used.device_bytes !=
        persistent_device_bytes or
        bank_after.active_lease_pin_slots != 0 or
        bank_after.lease_pin_acquisitions != expected_pins or
        bank_after.lease_pin_completions != expected_pins or
        coordinator_after.active_dispatches != 0 or
        try backend.nativeLiveCommandCount() != 0)
        return error.InvalidCancellationStormBoundary;

    for (0..flow_count) |lane| {
        try writeCancellationStormCancelledRecordV1(
            storage,
            scenario,
            block_index,
            wave_index,
            ordinal_base + lane,
            lane,
            terminal_ranks[lane],
            pending[lane],
        );
    }
}

fn startCancellationStormControlPairV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    fixture: FixtureV1,
    block_index: usize,
    ordinal_base: usize,
    clock: *EventClockV1,
) ![flow_count]PendingRecordV1 {
    const prior_pins = block_index * 18 + 16;
    var pending: [flow_count]PendingRecordV1 = undefined;
    for (0..flow_count) |lane| {
        if (storage.lanes[lane].request != null or
            storage.lanes[lane].pin != null or
            storage.lanes[lane].ticket != null)
            return error.InvalidLaneState;
        storage.outputs[lane] =
            [_]f32{-8_765.25} ** out_features;
        pending[lane] = .{
            .ordinal = @intCast(ordinal_base + lane),
            .cohort = cancellationStormCohortV1(
                block_index,
            ),
            .flow_id = @intCast(lane),
            .request = undefined,
            .pin = undefined,
            .ticket = undefined,
        };
        pending[lane].host.arrival = try clock.next();
    }

    for (0..flow_count) |lane| {
        const bank_before = try storage.bank.snapshotV4();
        const attempt =
            try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
                fixture.bindings[lane],
                storage.packed_weights.len,
                storage.scales.len,
                storage.inputs[lane].len,
                storage.outputs[lane].len,
                group_size,
                in_features,
                out_features,
            );
        const request =
            try storage.adapter.prepareMatvecDispatchRequestV1(
                attempt,
            );
        const expected_request_generation: u64 =
            @intCast(block_index * 18 + 17 + lane);
        if (request.request_generation !=
            expected_request_generation)
            return error.InvalidRequestGeneration;
        storage.lanes[lane].request = request;
        const pin = try storage.coordinator.acquireDispatchPin(
            campaign_lease,
            storage.adapter.dispatchInterface(),
            request.request_sha256,
        );
        try lease_tree.validateDispatchPinV1(pin);
        if (pin.dispatch_generation !=
            expected_request_generation)
            return error.InvalidDispatchGeneration;
        storage.lanes[lane].pin = pin;
        pending[lane].host.admission = try clock.next();
        const bank_after = try storage.bank.snapshotV4();
        if (bank_after.lease_pin_acquisitions !=
            prior_pins + lane + 1 or
            bank_after.lease_pin_completions != prior_pins or
            bank_after.active_lease_pin_slots != lane + 1 or
            bank_after.used.device_bytes !=
                bank_before.used.device_bytes or
            try backend.nativeLiveCommandCount() != 0)
            return error.InvalidBankPinFacts;
        pending[lane].request = request;
        pending[lane].pin = pin;
        pending[lane].bank_used_before =
            bank_before.used.device_bytes;
    }

    for (0..flow_count) |lane| {
        pending[lane].host.first_service =
            try clock.next();
    }
    for (0..flow_count) |lane| {
        const ticket =
            try storage.adapter.submitMatvecInt4AsyncObserved(
                campaign_lease,
                pending[lane].pin,
                fixture.bindings[lane],
                &storage.packed_weights,
                &storage.scales,
                &storage.inputs[lane],
                &storage.outputs[lane],
                group_size,
                in_features,
                out_features,
            );
        storage.lanes[lane].ticket = ticket;
        pending[lane].ticket = ticket;
        pending[lane].host.submit_return = try clock.next();
        try metal_allocation
            .validateMetalAsyncDispatchTicketV1(ticket);
        const expected_ticket_generation: u64 =
            @intCast(block_index * flow_count + lane + 1);
        if (ticket.ticket_generation !=
            expected_ticket_generation or
            ticket.queue_slot != lane or
            !std.meta.eql(
                storage.adapter
                    .currentAsyncDispatchTicketForQueueSlotV1(
                    lane,
                ) orelse return error.InvalidLaneState,
                ticket,
            ) or storage.adapter
            .currentAsyncDispatchQuarantineForQueueSlotV1(
            lane,
        ) != null)
            return error.InvalidLaneState;
    }

    const expected_generations: metal_allocation.MetalDispatchGenerationSnapshotV1 = .{
        .next_request_generation = @intCast((block_index + 1) * 18 + 1),
        .next_ticket_generation = @intCast((block_index + 1) * flow_count + 1),
    };
    if (!std.meta.eql(
        storage.adapter.dispatchGenerationSnapshotV1(),
        expected_generations,
    ) or (try storage.coordinator.snapshot())
        .active_dispatches != flow_count or
        (try storage.bank.snapshotV4())
            .active_lease_pin_slots != flow_count or
        try backend.nativeLiveCommandCount() != flow_count or
        pending[0].request.request_generation >=
            pending[1].request.request_generation or
        pending[0].pin.dispatch_generation >=
            pending[1].pin.dispatch_generation or
        pending[0].ticket.ticket_generation >=
            pending[1].ticket.ticket_generation)
        return error.InvalidPairOwnership;
    return pending;
}

fn runCancellationStormControlPairV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    fixture: FixtureV1,
    scenario: native_report.ScenarioV1,
    block_index: usize,
    ordinal_base: usize,
    clock: *EventClockV1,
) !void {
    var pending = try startCancellationStormControlPairV1(
        storage,
        backend,
        campaign_lease,
        fixture,
        block_index,
        ordinal_base,
        clock,
    );
    for (0..flow_count) |lane| {
        try observeLaneV1(
            storage,
            campaign_lease,
            lane,
            &pending[lane],
            clock,
        );
    }
    for (0..flow_count) |lane| {
        pending[lane].host.terminal = try clock.next();
    }
    var reverse_lane: usize = flow_count;
    while (reverse_lane != 0) {
        reverse_lane -= 1;
        try settleLaneV1(
            storage,
            backend,
            scenario,
            reverse_lane,
            &pending[reverse_lane],
            clock,
        );
    }
    try validatePairSettledV1(
        storage,
        backend,
        (block_index + 1) * 18,
        &pending,
    );
}

fn validateCancellationStormWaveScheduleV1(
    storage: *const StorageV1,
    scenario: native_report.ScenarioV1,
    block_index: usize,
    wave_index: usize,
    challenge_sha256: Digest,
) !void {
    const record_base =
        block_index * cancellation_storm_records_per_block +
        wave_index * cancellation_storm_records_per_wave;
    const sequence_base: u64 =
        @intCast(block_index * 102 + wave_index * 11);
    const cancelled = [flow_count]native_report.RecordV1{
        storage.records[record_base],
        storage.records[record_base + 1],
    };
    const capacity = storage.records[record_base + 2];
    const expected_cohort =
        cancellationStormCohortV1(block_index);

    if (cancelled[0].host.arrival.sequence !=
        sequence_base + 1 or
        cancelled[1].host.arrival.sequence !=
            sequence_base + 2 or
        cancelled[0].host.admission.sequence !=
            sequence_base + 3 or
        cancelled[1].host.admission.sequence !=
            sequence_base + 4 or
        capacity.host.arrival.sequence !=
            sequence_base + 5 or
        capacity.host.terminal.sequence !=
            sequence_base + 6 or
        capacity.host.settlement.sequence !=
            sequence_base + 7)
        return error.InvalidEventSequence;
    const terminal_sequences = [flow_count]u64{
        cancelled[0].host.terminal.sequence,
        cancelled[1].host.terminal.sequence,
    };
    if (!((terminal_sequences[0] == sequence_base + 8 and
        terminal_sequences[1] == sequence_base + 9) or
        (terminal_sequences[0] == sequence_base + 9 and
            terminal_sequences[1] == sequence_base + 8)))
        return error.InvalidEventSequence;
    const global_wave =
        block_index * cancellation_storm_waves_per_block +
        wave_index;
    const first_lane =
        cancellationStormSettlementFirstLaneV1(
            challenge_sha256,
            global_wave,
        );
    if (cancelled[first_lane].host.settlement.sequence !=
        sequence_base + 10 or
        cancelled[first_lane ^ 1].host.settlement.sequence !=
            sequence_base + 11)
        return error.InvalidEventSequence;

    const expected_generations: metal_allocation.MetalDispatchGenerationSnapshotV1 = .{
        .next_request_generation = @intCast(
            block_index * 18 +
                wave_index * flow_count +
                3,
        ),
        .next_ticket_generation = @intCast(block_index * flow_count + 1),
    };
    for (cancelled, 0..) |record, lane| {
        const action =
            try cancellationStormCancelActionV1(lane);
        const action_evidence_sha256 =
            cancellationStormRecordRootV1(
                scenario,
                block_index,
                wave_index,
                action,
                lane,
                .action_evidence,
            );
        const terminal_rank: usize =
            if (record.host.terminal.sequence ==
            sequence_base + 8) 0 else 1;
        const admitted_commitment =
            cancellationStormAdmittedCommitmentV1(
                scenario,
                block_index,
                wave_index,
                action,
                lane,
                terminal_rank,
                .cancelled,
                record.roots.request_sha256,
                record.roots.pin_sha256,
                record.roots.terminal_sha256,
                record.roots.completion_sha256,
                action_evidence_sha256,
            );
        if (record.ordinal != record_base + lane or
            record.cohort != expected_cohort or
            record.outcome != .cancelled or
            record.correctness != .not_applicable or
            record.fallback or
            record.flow_id != lane or
            record.work_units != work_units_per_record or
            record.adapter_queue_slot != lane or
            record.host.presence_mask !=
                disruption_admitted_presence or
            record.maximum_abs_error_f64_bits != 0 or
            !digestIsZero(record.roots.ticket_sha256) or
            !digestIsZero(record.roots.dispatch_sha256) or
            !digestIsZero(
                record.roots.submission_sha256,
            ) or
            !digestIsZero(record.roots.output_sha256) or
            !digestIsZero(record.roots.oracle_sha256) or
            !std.mem.eql(
                u8,
                &record.device_timing.reason_sha256,
                &admitted_commitment,
            ) or !std.mem.eql(
            u8,
            &record.allocated_context.reason_sha256,
            &action_evidence_sha256,
        ) or record.device_timing.availability !=
            .unsupported or
            record.allocated_context.availability !=
                .unsupported or
            record.logical.bank_acquisitions != 1 or
            record.logical.bank_completions != 1 or
            record.logical.bank_used_before !=
                persistent_device_bytes or
            record.logical.bank_used_after_settlement !=
                persistent_device_bytes or
            record.logical.pin_count_before != 1 or
            record.logical.pin_count_after_settlement != 0 or
            record.logical.dispatch_count_before != 0 or
            record.logical.dispatch_count_after_settlement != 0 or
            record.logical.native_command_count_before != 0 or
            record.logical.native_command_count_after_settlement !=
                0)
            return error.InvalidCancellationStormRecord;
    }

    const probe_flow = global_wave & 1;
    if (capacity.ordinal != record_base + 2 or
        capacity.cohort != expected_cohort or
        capacity.outcome != .capacity_rejected or
        capacity.correctness != .not_applicable or
        capacity.fallback or
        capacity.flow_id != probe_flow or
        capacity.work_units != work_units_per_record or
        capacity.adapter_queue_slot !=
            native_report.no_queue_slot or
        capacity.host.presence_mask !=
            native_report.capacity_rejected_presence or
        capacity.maximum_abs_error_f64_bits != 0 or
        !digestIsZero(capacity.roots.ticket_sha256) or
        !digestIsZero(capacity.roots.pin_sha256) or
        !digestIsZero(capacity.roots.dispatch_sha256) or
        !digestIsZero(capacity.roots.submission_sha256) or
        !digestIsZero(capacity.roots.output_sha256) or
        !digestIsZero(capacity.roots.oracle_sha256) or
        capacity.device_timing.availability !=
            .unsupported or
        capacity.allocated_context.availability !=
            .unsupported or
        !std.mem.eql(
            u8,
            &capacity.roots.request_sha256,
            &cancellationStormCapacityRootV1(
                scenario,
                block_index,
                wave_index,
                probe_flow,
                .request,
                expected_generations,
            ),
        ) or !std.mem.eql(
        u8,
        &capacity.roots.terminal_sha256,
        &cancellationStormCapacityRootV1(
            scenario,
            block_index,
            wave_index,
            probe_flow,
            .terminal,
            expected_generations,
        ),
    ) or !std.mem.eql(
        u8,
        &capacity.roots.completion_sha256,
        &cancellationStormCapacityRootV1(
            scenario,
            block_index,
            wave_index,
            probe_flow,
            .completion,
            expected_generations,
        ),
    ) or !std.mem.eql(
        u8,
        &capacity.device_timing.reason_sha256,
        &cancellationStormCapacityRootV1(
            scenario,
            block_index,
            wave_index,
            probe_flow,
            .timing_unsupported,
            expected_generations,
        ),
    ) or !std.mem.eql(
        u8,
        &capacity.allocated_context.reason_sha256,
        &cancellationStormCapacityRootV1(
            scenario,
            block_index,
            wave_index,
            probe_flow,
            .allocation_unsupported,
            expected_generations,
        ),
    ) or !std.meta.eql(
        capacity.logical,
        native_report.LogicalFactsV1{},
    ))
        return error.InvalidCancellationStormRecord;
}

fn validateCancellationStormControlScheduleV1(
    storage: *const StorageV1,
    block_index: usize,
) !void {
    const record_base =
        block_index * cancellation_storm_records_per_block +
        cancellation_storm_waves_per_block *
            cancellation_storm_records_per_wave;
    const sequence_base: u64 =
        @intCast(block_index * 102 + 88);
    const lane0 = storage.records[record_base];
    const lane1 = storage.records[record_base + 1];
    const expected_lane0 = [_]u64{
        sequence_base + 1,
        sequence_base + 3,
        sequence_base + 5,
        sequence_base + 7,
        sequence_base + 9,
        sequence_base + 11,
        sequence_base + 14,
    };
    const expected_lane1 = [_]u64{
        sequence_base + 2,
        sequence_base + 4,
        sequence_base + 6,
        sequence_base + 8,
        sequence_base + 10,
        sequence_base + 12,
        sequence_base + 13,
    };
    const lane0_points = [_]u64{
        lane0.host.arrival.sequence,
        lane0.host.admission.sequence,
        lane0.host.first_service.sequence,
        lane0.host.submit_return.sequence,
        lane0.host.first_output.sequence,
        lane0.host.terminal.sequence,
        lane0.host.settlement.sequence,
    };
    const lane1_points = [_]u64{
        lane1.host.arrival.sequence,
        lane1.host.admission.sequence,
        lane1.host.first_service.sequence,
        lane1.host.submit_return.sequence,
        lane1.host.first_output.sequence,
        lane1.host.terminal.sequence,
        lane1.host.settlement.sequence,
    };
    if (!std.meta.eql(lane0_points, expected_lane0) or
        !std.meta.eql(lane1_points, expected_lane1))
        return error.InvalidEventSequence;
    for (
        [_]native_report.RecordV1{ lane0, lane1 },
        0..,
    ) |record, lane| {
        _ = try cancellationStormControlActionV1(lane);
        const maximum_abs_error_value: f64 =
            @bitCast(record.maximum_abs_error_f64_bits);
        if (record.ordinal != record_base + lane or
            record.cohort !=
                cancellationStormCohortV1(block_index) or
            record.outcome != .completed or
            record.correctness != .correct or
            record.fallback or
            record.flow_id != lane or
            record.work_units != work_units_per_record or
            record.adapter_queue_slot != lane or
            record.host.presence_mask !=
                native_report.event_presence_all or
            !std.math.isFinite(maximum_abs_error_value) or
            maximum_abs_error_value < 0 or
            maximum_abs_error_value > maximum_abs_error or
            digestIsZero(record.roots.request_sha256) or
            digestIsZero(record.roots.ticket_sha256) or
            digestIsZero(record.roots.pin_sha256) or
            digestIsZero(record.roots.dispatch_sha256) or
            digestIsZero(record.roots.submission_sha256) or
            digestIsZero(record.roots.output_sha256) or
            digestIsZero(record.roots.oracle_sha256) or
            digestIsZero(record.roots.terminal_sha256) or
            digestIsZero(record.roots.completion_sha256) or
            record.device_timing.availability != .present or
            record.device_timing.duration_ns == 0 or
            record.allocated_context.availability != .present or
            record.allocated_context.before_bytes == 0 or
            record.allocated_context.after_bytes == 0 or
            record.logical.bank_acquisitions != 1 or
            record.logical.bank_completions != 1 or
            record.logical.bank_used_before !=
                persistent_device_bytes or
            record.logical.bank_used_after_settlement !=
                persistent_device_bytes or
            record.logical.pin_count_before != 1 or
            record.logical.pin_count_after_settlement != 0 or
            record.logical.dispatch_count_before != 1 or
            record.logical.dispatch_count_after_settlement != 0 or
            record.logical.native_command_count_before != 1 or
            record.logical.native_command_count_after_settlement !=
                0)
            return error.InvalidCancellationStormRecord;
    }
}

fn validateCancellationStormBlockBoundaryV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    initial_lifecycle: metal.MetalDeviceLifecycleSnapshot,
    initial_device: metal.MetalDeviceInfo,
    block_index: usize,
    completed_dispatches_before: u64,
) !void {
    try validateLifecycleSnapshot(
        backend,
        initial_lifecycle,
        try backend.deviceLifecycleSnapshot(),
    );
    try validateDeviceAndPlacementIdentityV1(
        initial_device,
        try backend.deviceInfo(),
    );
    const expected_pins: u64 =
        @intCast((block_index + 1) * 18);
    const adapter_snapshot = storage.adapter.snapshot();
    const bank_snapshot = try storage.bank.snapshotV4();
    const coordinator_snapshot =
        try storage.coordinator.snapshot();
    const expected_generations: metal_allocation.MetalDispatchGenerationSnapshotV1 = .{
        .next_request_generation = @intCast((block_index + 1) * 18 + 1),
        .next_ticket_generation = @intCast((block_index + 1) * flow_count + 1),
    };
    if (adapter_snapshot.live_objects != flow_count * 4 or
        adapter_snapshot.materialized_leases != 1 or
        adapter_snapshot.used_resource_bytes !=
            persistent_device_bytes or
        !std.meta.eql(
            storage.adapter.dispatchGenerationSnapshotV1(),
            expected_generations,
        ) or backend.liveBufferCount() != flow_count * 4 or
        try backend.nativeLiveBufferCount() !=
            flow_count * 4 or
        try backend.nativeLiveCommandCount() != 0 or
        bank_snapshot.used.device_bytes !=
            persistent_device_bytes or
        bank_snapshot.active_lease_pin_slots != 0 or
        bank_snapshot.lease_pin_acquisitions !=
            expected_pins or
        bank_snapshot.lease_pin_completions !=
            expected_pins or
        !coordinator_snapshot.live_lease or
        coordinator_snapshot.active_dispatches != 0 or
        backend.completedDispatchCount() !=
            completed_dispatches_before +
                (block_index + 1) * flow_count or
        backend.compatibilityUnresolvedSubmission() != null)
        return error.InvalidCancellationStormBoundary;
    for (0..flow_count) |lane| {
        if (storage.lanes[lane].request != null or
            storage.lanes[lane].pin != null or
            storage.lanes[lane].ticket != null or
            storage.adapter
                .currentAsyncDispatchTicketForQueueSlotV1(
                lane,
            ) != null or
            storage.adapter
                .currentAsyncDispatchQuarantineForQueueSlotV1(
                lane,
            ) != null)
            return error.InvalidLaneState;
    }
}

fn runCancellationStormBlocksV1(
    storage: *StorageV1,
    backend: *metal.MetalBackend,
    campaign_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    fixture: FixtureV1,
    scenario: native_report.ScenarioV1,
    initial_lifecycle: metal.MetalDeviceLifecycleSnapshot,
    initial_device: metal.MetalDeviceInfo,
    recommended_max_working_set_size: u64,
    completed_dispatches_before: u64,
    challenge_sha256: Digest,
    clock: *EventClockV1,
) !void {
    if (recommended_max_working_set_size == 0)
        return error.InvalidAllocatedContext;
    var allocated_context_high_water: u64 = 0;
    for (0..cancellation_storm_block_count) |block_index| {
        const block_record_base =
            block_index *
            cancellation_storm_records_per_block;
        for (
            0..cancellation_storm_waves_per_block,
        ) |wave_index| {
            const ordinal_base =
                block_record_base +
                wave_index *
                    cancellation_storm_records_per_wave;
            var pending =
                try prepareCancellationStormWaveV1(
                    storage,
                    backend,
                    campaign_lease,
                    fixture,
                    block_index,
                    wave_index,
                    clock,
                );
            try writeCancellationStormCapacityRecordV1(
                storage,
                backend,
                fixture,
                scenario,
                block_index,
                wave_index,
                ordinal_base + 2,
                clock,
            );
            try runCancellationStormConcurrentCancellationV1(
                storage,
                backend,
                campaign_lease,
                scenario,
                block_index,
                wave_index,
                ordinal_base,
                challenge_sha256,
                &pending,
                clock,
            );
            try validateCancellationStormWaveScheduleV1(
                storage,
                scenario,
                block_index,
                wave_index,
                challenge_sha256,
            );
        }

        const control_record_base =
            block_record_base +
            cancellation_storm_waves_per_block *
                cancellation_storm_records_per_wave;
        try runCancellationStormControlPairV1(
            storage,
            backend,
            campaign_lease,
            fixture,
            scenario,
            block_index,
            control_record_base,
            clock,
        );
        try validateCancellationStormControlScheduleV1(
            storage,
            block_index,
        );
        for (0..flow_count) |lane| {
            const allocated =
                storage.records[control_record_base + lane]
                    .allocated_context;
            if (allocated.availability != .present or
                allocated.before_bytes == 0 or
                allocated.after_bytes == 0 or
                allocated.before_bytes >
                    recommended_max_working_set_size or
                allocated.after_bytes >
                    recommended_max_working_set_size)
                return error.InvalidAllocatedContext;
            allocated_context_high_water = @max(
                allocated_context_high_water,
                @max(
                    allocated.before_bytes,
                    allocated.after_bytes,
                ),
            );
        }
        try validateCancellationStormBlockBoundaryV1(
            storage,
            backend,
            initial_lifecycle,
            initial_device,
            block_index,
            completed_dispatches_before,
        );
    }
    if (allocated_context_high_water == 0 or
        allocated_context_high_water >
            recommended_max_working_set_size)
        return error.InvalidAllocatedContext;
}

fn validateCancellationStormSealedV1(
    report_value: native_report.ReportV1,
) !void {
    if (report_value.records.len !=
        cancellation_storm_record_count or
        report_value.scenario.warmup_count !=
            cancellation_storm_warmup_record_count or
        report_value.scenario.measured_count !=
            cancellation_storm_measured_record_count or
        report_value.summary.measured_records !=
            cancellation_storm_measured_record_count or
        report_value.summary.admitted_count != 126 or
        report_value.summary.completed_count != 14 or
        report_value.summary.capacity_rejected_count != 56 or
        report_value.summary.failed_count != 0 or
        report_value.summary.cancelled_count != 112 or
        report_value.summary.timed_out_count != 0 or
        report_value.summary.attempted_work_units !=
            cancellation_storm_measured_record_count *
                work_units_per_record or
        report_value.summary.completed_work_units !=
            14 * work_units_per_record or
        report_value.summary.logical_in_flight_high_water !=
            flow_count or
        report_value.summary.flow_completion_min != 7 or
        report_value.summary.flow_completion_max != 7 or
        report_value.summary.flow_completion_spread != 0 or
        report_value.summary.fallback_count != 0 or
        report_value.summary.correctness_correct_count != 14 or
        report_value.summary.correctness_incorrect_count != 0 or
        report_value.closure.acquisitions !=
            cancellation_storm_pin_count or
        report_value.closure.completions !=
            cancellation_storm_pin_count or
        !report_value.closure.zero_orphan)
        return error.InvalidCancellationStormSummary;
}
