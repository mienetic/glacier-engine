//! Hard native Metal allocation ownership gate.
//!
//! This test must run only in the explicitly native macOS/Metal build step.
//! It creates real direct Shared MTLBuffers, observes each resource through
//! MTLResource, composes them with the portable ChildLease coordinator, then
//! proves release and generation-fenced reuse. It makes no residency,
//! performance, or device-wide allocation-delta claim.

const std = @import("std");
const engine = @import("engine");
const config = @import("config");

const testing = std.testing;
const allocation = engine.device_allocation_lease;
const device = engine.device_capability_contract;
const resource = engine.resource_bank;
const metal_allocation = engine.metal_allocation_adapter;

const Fixture = struct {
    inventory: [1]device.DeviceInventoryEntryV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    entries: [3]allocation.AllocationEntryV1,
    manifest: allocation.AllocationManifestV1,
};

fn digest(bytes: []const u8) allocation.Digest {
    var result: allocation.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn lessThan(
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

fn makeFixture(
    adapter: *metal_allocation.MetalAllocationAdapterV1,
    inventory_entry: device.DeviceInventoryEntryV1,
) !Fixture {
    var entries = [3]allocation.AllocationEntryV1{
        .{
            .binding_sha256 = digest(
                "native Metal activation allocation",
            ),
            .requested_bytes = 1_000,
        },
        .{
            .binding_sha256 = digest(
                "native Metal kv allocation",
            ),
            .requested_bytes = 3_000,
        },
        .{
            .binding_sha256 = digest(
                "native Metal weight allocation",
            ),
            .requested_bytes = 4_000,
        },
    };
    for (&entries) |*entry| {
        const quote = try adapter.quote(
            entry.binding_sha256,
            entry.requested_bytes,
        );
        entry.charged_bytes = quote.charged_bytes;
        entry.quote_sha256 = quote.quote_sha256;
    }
    std.mem.sort(
        allocation.AllocationEntryV1,
        &entries,
        {},
        lessThan,
    );
    const manifest = try allocation.sealManifestV1(&entries);
    const profile =
        device.OperationProfileBitsV1.matvec_int4_f32_bounded;
    const requirement = try device.sealRequirementV1(.{
        .plan_sha256 = digest(
            "native Metal allocation execution plan",
        ),
        .required_device_class = .accelerator,
        .required_operation_profile_bits = profile,
        .required_operator_bits = device.profileOperatorBitsV1(profile),
        .required_element_type_bits = device.profileElementTypeBitsV1(profile),
        .required_numerical_policy_bits = device.profileNumericalPolicyBitsV1(profile),
        .required_feature_bits = device.FeatureBitsV1.allocation |
            device.FeatureBitsV1.allocated_bytes_observation,
        .largest_single_allocation_bytes = manifest.largest_charged_bytes,
        .total_device_bytes = manifest.total_charged_bytes,
        .queue_slots = 1,
        .fallback_policy = .forbidden,
    });
    const inventory = [1]device.DeviceInventoryEntryV1{
        inventory_entry,
    };
    const selected = try device.selectDeviceV1(
        requirement,
        &inventory,
    );
    try testing.expectEqual(@as(usize, 0), selected.selected_index);
    try testing.expectEqual(@as(u64, 0), selected.receipt.fallback_used);
    return .{
        .inventory = inventory,
        .requirement = requirement,
        .selection = selected.receipt,
        .entries = entries,
        .manifest = manifest,
    };
}

fn makeRequest(
    adapter: *metal_allocation.MetalAllocationAdapterV1,
    parent: resource.Receipt,
    fixture: Fixture,
) !allocation.AllocationRequestV1 {
    return allocation.makeRequestV1(
        301,
        digest("native Metal allocation owner"),
        adapter.authority,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
}

fn resealInventoryCapability(
    base: device.DeviceInventoryEntryV1,
    changed: device.DeviceCapabilityV1,
) !device.DeviceInventoryEntryV1 {
    var capability = changed;
    capability.capability_sha256 = device.zero_digest;
    capability = try device.sealCapabilityV1(capability);
    var entry = base;
    entry.capability = capability;
    entry.entry_sha256 = device.zero_digest;
    return device.sealInventoryEntryV1(entry);
}

const NativeBufferWorker = struct {
    backend: *engine.MetalBackend,
    start: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    requested_bytes: u64,

    fn run(self: *@This()) void {
        while (!self.start.load(.acquire))
            std.atomic.spinLoopHint();
        for (0..8) |_| {
            const token = self.backend.createBufferAllocation(
                self.requested_bytes,
            ) catch {
                self.failed.store(true, .release);
                return;
            };
            const info = self.backend.inspectBufferAllocation(
                token,
            ) catch {
                self.backend.destroyBufferAllocation(token) catch {};
                self.failed.store(true, .release);
                return;
            };
            if (info.requested_length != self.requested_bytes or
                info.resource_length != self.requested_bytes or
                info.allocated_size < info.resource_length)
            {
                self.backend.destroyBufferAllocation(token) catch {};
                self.failed.store(true, .release);
                return;
            }
            self.backend.destroyBufferAllocation(token) catch {
                self.failed.store(true, .release);
                return;
            };
        }
    }
};

test "real Metal buffers obey receipt charge release and generation reuse" {
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    defer backend.deinit();
    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            &backend,
            101,
            0,
            1 * 1024 * 1024,
        );

    var native_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}} ** 3;
    var adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            inventory_entry,
            201,
            0x4d65_7461_6c41_6c6c,
            &native_slots,
        );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    const fixture = try makeFixture(&adapter, inventory_entry);
    try testing.expectEqual(
        @as(u64, 8_000),
        fixture.manifest.total_charged_bytes,
    );

    var bank_slots = [_]resource.Slot{.{}};
    var child_slots = [_]resource.ChildSlot{.{}};
    var bank = try resource.Bank.initWithChildSlots(
        &bank_slots,
        &child_slots,
        .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = fixture.manifest.total_charged_bytes,
            .queue_slots = 1,
        },
        401,
    );
    const parent = try bank.commit(
        try bank.reserve(501, .{
            .capsule_bytes = 64,
            .queue_slots = 1,
        }),
    );
    var coordinator_slots =
        [_]allocation.CoordinatorSlotV1{.{}};
    var coordinator_objects =
        [_]allocation.CoordinatorObjectSlotV1{.{}} ** 3;
    var coordinator = try allocation.CoordinatorV1.init(
        601,
        &coordinator_slots,
        &coordinator_objects,
    );
    const request = try makeRequest(&adapter, parent, fixture);

    var first_generations: [3]u64 = undefined;
    var first_lease: allocation.DeviceAllocationLeaseV1 = undefined;
    for (0..2) |cycle| {
        const admission = try coordinator.admit(
            &bank,
            adapter.interface(),
            request,
            fixture.selection,
            fixture.requirement,
            &fixture.inventory,
            parent,
            fixture.manifest,
            &fixture.entries,
        );
        try testing.expectEqual(
            fixture.manifest.total_charged_bytes,
            (try bank.snapshot()).used.device_bytes,
        );
        const materialized = try coordinator.materialize(
            &bank,
            admission,
            adapter.interface(),
            .{},
        );
        const lease = switch (materialized) {
            .active => |value| value,
            else => return error.TestUnexpectedResult,
        };
        if (cycle == 0) first_lease = lease;

        const live_snapshot = adapter.snapshot();
        try testing.expectEqual(@as(usize, 3), live_snapshot.live_objects);
        try testing.expectEqual(@as(usize, 1), live_snapshot.materialized_leases);
        try testing.expectEqual(
            fixture.manifest.total_charged_bytes,
            live_snapshot.used_resource_bytes,
        );
        try testing.expect(
            live_snapshot.observed_allocated_size_bytes >=
                live_snapshot.used_resource_bytes,
        );
        try testing.expectEqual(@as(u64, 3), backend.liveBufferCount());
        try testing.expectEqual(
            @as(u64, 3),
            try backend.nativeLiveBufferCount(),
        );

        var observations =
            [_]metal_allocation.MetalAllocationObservationV1{.{}} ** 3;
        try testing.expectEqual(
            @as(usize, 3),
            try adapter.copyLiveObservations(&observations),
        );
        for (observations, 0..) |observation, ordinal| {
            try testing.expectEqual(
                @as(u64, @intCast(ordinal)),
                observation.ordinal,
            );
            try testing.expectEqual(
                fixture.entries[ordinal].binding_sha256,
                observation.binding_sha256,
            );
            try testing.expectEqual(
                fixture.entries[ordinal].requested_bytes,
                observation.requested_bytes,
            );
            try testing.expectEqual(
                observation.requested_bytes,
                observation.charged_resource_bytes,
            );
            try testing.expectEqual(
                observation.requested_bytes,
                observation.buffer_length_bytes,
            );
            try testing.expect(
                observation.resource_allocated_size_bytes >=
                    observation.buffer_length_bytes,
            );
            try testing.expectEqual(
                live_snapshot.device_registry_id,
                observation.device_registry_id,
            );
            try testing.expectEqual(
                metal_allocation.observationRootV1(observation),
                observation.observation_sha256,
            );
            if (cycle == 0) {
                first_generations[ordinal] =
                    observation.backend_object_generation;
            } else {
                try testing.expect(
                    observation.backend_object_generation >
                        first_generations[ordinal],
                );
            }
        }

        const release = try coordinator.release(
            &bank,
            lease,
            adapter.interface(),
        );
        const terminal = switch (release) {
            .terminal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(
            allocation.TerminalOutcomeV1.released,
            terminal.outcome,
        );
        try testing.expectEqual(
            fixture.manifest.total_charged_bytes,
            terminal.returned_device_bytes,
        );
        try testing.expectEqual(
            @as(u64, 0),
            (try bank.snapshot()).used.device_bytes,
        );
        try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
        try testing.expectEqual(
            @as(u64, 0),
            try backend.nativeLiveBufferCount(),
        );
        try adapter.validateEmpty();
    }

    try testing.expectError(
        allocation.Error.StaleHandle,
        coordinator.release(
            &bank,
            first_lease,
            adapter.interface(),
        ),
    );
    const final_snapshot = adapter.snapshot();
    try testing.expectEqual(@as(u64, 6), final_snapshot.allocate_calls);
    try testing.expectEqual(@as(u64, 6), final_snapshot.free_calls);
    try testing.expectEqual(@as(u64, 6), final_snapshot.inspect_calls);
    try bank.release(parent);
    try testing.expect((try bank.snapshot()).used.isZero());
}

test "native Metal adapter rejects invalid logical lengths without allocation" {
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    defer backend.deinit();
    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            &backend,
            102,
            0,
            4_096,
        );
    var native_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}};
    var adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            inventory_entry,
            202,
            0x4d65_7461_6c52_656a,
            &native_slots,
        );
    var second_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}};
    var second_adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            inventory_entry,
            202,
            0x4d65_7461_6c52_656a,
            &second_slots,
        );
    try testing.expect(
        !device.digestEqual(
            adapter.authority.authority_sha256,
            second_adapter.authority.authority_sha256,
        ),
    );
    try testing.expect(
        second_adapter.snapshot().adapter_instance >
            adapter.snapshot().adapter_instance,
    );
    try testing.expectError(
        allocation.CallbackError.InvalidRequest,
        adapter.quote(allocation.zero_digest, 1),
    );
    try testing.expectError(
        allocation.CallbackError.InvalidRequest,
        adapter.quote(digest("zero request"), 0),
    );
    try testing.expectError(
        allocation.CallbackError.CapacityExceeded,
        adapter.quote(digest("oversize request"), 4_097),
    );
    try testing.expectError(
        engine.metal_backend.MetalError.AllocationFailed,
        backend.createBufferAllocation(0),
    );
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try adapter.validateEmpty();
    try second_adapter.validateEmpty();

    var reject_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}};
    var backend_drift = inventory_entry.capability;
    backend_drift.backend_sha256 =
        digest("foreign Metal allocation backend");
    try testing.expectError(
        error.InvalidDevice,
        metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            try resealInventoryCapability(
                inventory_entry,
                backend_drift,
            ),
            203,
            1,
            &reject_slots,
        ),
    );

    var profile_drift = inventory_entry.capability;
    profile_drift.operation_profile_bits =
        device.OperationProfileBitsV1.dequantize_int4_f16;
    profile_drift.operator_bits = device.profileOperatorBitsV1(
        profile_drift.operation_profile_bits,
    );
    profile_drift.element_type_bits =
        device.profileElementTypeBitsV1(
            profile_drift.operation_profile_bits,
        );
    profile_drift.numerical_policy_bits =
        device.profileNumericalPolicyBitsV1(
            profile_drift.operation_profile_bits,
        );
    try testing.expectError(
        error.InvalidDevice,
        metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            try resealInventoryCapability(
                inventory_entry,
                profile_drift,
            ),
            204,
            2,
            &reject_slots,
        ),
    );

    var feature_drift = inventory_entry.capability;
    feature_drift.feature_bits |=
        device.FeatureBitsV1.command_buffer_time;
    try testing.expectError(
        error.InvalidDevice,
        metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            try resealInventoryCapability(
                inventory_entry,
                feature_drift,
            ),
            205,
            3,
            &reject_slots,
        ),
    );

    var foreign_backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    defer foreign_backend.deinit();
    const token = try backend.createBufferAllocation(1_000);
    const foreign_token =
        try foreign_backend.createBufferAllocation(512);
    try testing.expectEqual(@as(u64, 1), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveBufferCount(),
    );
    try testing.expectError(
        engine.metal_backend.MetalError.InvalidObservation,
        foreign_backend.inspectBufferAllocation(token),
    );
    try testing.expectError(
        engine.metal_backend.MetalError.InvalidObservation,
        foreign_backend.destroyBufferAllocation(token),
    );
    try testing.expectEqual(
        @as(u64, 1),
        foreign_backend.liveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 1),
        try foreign_backend.nativeLiveBufferCount(),
    );
    try foreign_backend.destroyBufferAllocation(foreign_token);
    try backend.destroyBufferAllocation(token);
    const replacement =
        try backend.createBufferAllocation(1_001);
    try testing.expectError(
        engine.metal_backend.MetalError.InvalidObservation,
        backend.inspectBufferAllocation(token),
    );
    try testing.expectError(
        engine.metal_backend.MetalError.InvalidObservation,
        backend.destroyBufferAllocation(token),
    );
    try testing.expectEqual(@as(u64, 1), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveBufferCount(),
    );
    try backend.destroyBufferAllocation(replacement);
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
}

test "native Metal buffer registry remains balanced across callers" {
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    defer backend.deinit();
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var workers: [4]NativeBufferWorker = undefined;
    var threads: [4]std.Thread = undefined;
    for (&workers, 0..) |*worker, index| {
        worker.* = .{
            .backend = &backend,
            .start = &start,
            .failed = &failed,
            .requested_bytes = 1_000 + index,
        };
        threads[index] = std.Thread.spawn(
            .{},
            NativeBufferWorker.run,
            .{worker},
        ) catch |err| {
            start.store(true, .release);
            for (threads[0..index]) |thread| thread.join();
            return err;
        };
    }
    start.store(true, .release);
    for (threads) |thread| thread.join();

    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
}
