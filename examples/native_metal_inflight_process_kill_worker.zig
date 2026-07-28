//! Fault-linked native Metal victim for the W7b-b4 process-kill boundary.
//!
//! One production allocation-adapter request acquires four registered
//! buffers and one dispatch pin, then submits a real INT4 command buffer.
//! The private fault shim signals one shared event after the compute encoder
//! and waits for value two. Once the exact nonterminal ownership facts are
//! observed, this process emits one canonical ready frame and waits for an
//! external signal. It never releases, finalizes, or deinitializes the
//! unresolved command.

const std = @import("std");
const engine = @import("engine");
const metal_fault_control = @import("metal_fault_control");
const ready = @import("native_metal_inflight_process_kill_ready");

const allocation = engine.device_allocation_lease;
const lease_tree = engine.device_allocation_lease_tree;
const device = engine.device_capability_contract;
const resource = engine.resource_bank;
const metal = engine.metal_backend;
const metal_allocation = engine.metal_allocation_adapter;
const native_observer = engine.metal_native_observer;

const challenge_environment =
    "GLACIER_NATIVE_METAL_INFLIGHT_PROCESS_KILL_CHALLENGE_SHA256";
const build_domain =
    "glacier-w7b-b4-metal-inflight-victim-build-v1\x00";
const backend_domain =
    "glacier-w7b-b4-metal-inflight-backend-v1\x00";
const profile_domain =
    "glacier-w7b-b4-metal-inflight-profile-v1\x00";
const owner_domain =
    "glacier-w7b-b4-metal-inflight-owner-v1\x00";
const binding_domain =
    "glacier-w7b-b4-metal-inflight-buffer-role-v1\x00";

const in_features: usize = 64;
const out_features: usize = 37;
const group_size: u32 = 8;
const element_count: usize = in_features * out_features;
const packed_byte_count: usize = (element_count + 1) / 2;
const scale_count: usize =
    (element_count + group_size - 1) / group_size;
const persistent_device_bytes: u64 =
    packed_byte_count +
    scale_count * @sizeOf(f32) +
    in_features * @sizeOf(f32) +
    out_features * @sizeOf(f32);

comptime {
    if (element_count != 2_368 or
        packed_byte_count != 1_184 or
        scale_count != 296 or
        persistent_device_bytes != 2_772)
        @compileError("W7b-b4 victim geometry changed");
}

const Storage = struct {
    native_slots: [4]metal_allocation.MetalAllocationSlotV1 =
        [_]metal_allocation.MetalAllocationSlotV1{.{}} ** 4,
    bank_slots: [1]resource.Slot = .{.{}},
    tree_roots: [1]resource.LeaseTreeRootSlot = .{.{}},
    tree_nodes: [5]resource.LeaseNodeSlot =
        [_]resource.LeaseNodeSlot{.{}} ** 5,
    pin_slots: [1]resource.LeasePinSlotV1 = .{.{}},
    coordinator_objects: [4]lease_tree.CoordinatorObjectSlotV1 =
        [_]lease_tree.CoordinatorObjectSlotV1{.{}} ** 4,
    coordinator_dispatches: [1]lease_tree.CoordinatorDispatchSlotV1 =
        .{.{}},

    adapter: metal_allocation.MetalAllocationAdapterV1 = undefined,
    bank: resource.Bank = undefined,
    tree: resource.LeaseTreeV1 = undefined,
    coordinator: lease_tree.CoordinatorV1 = .{},
    publication_sequence: u64 = 0,
    session_anchor: u8 = 0,

    packed_weights: [packed_byte_count]u8 =
        [_]u8{0} ** packed_byte_count,
    scales: [scale_count]f32 = [_]f32{1.0} ** scale_count,
    input: [in_features]f32 = [_]f32{0.25} ** in_features,
    output: [out_features]f32 =
        [_]f32{-8_765.25} ** out_features,
};

const Fixture = struct {
    inventory: [1]device.DeviceInventoryEntryV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    bindings: metal_allocation.MetalMatvecAllocationBindingsV1,
    entries: [4]allocation.AllocationEntryV1,
    manifest: allocation.AllocationManifestV1,
};

const BoundFixture = struct {
    fixture: Fixture,
    lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
};

pub fn main() !void {
    if (!engine.metal_enabled or !metal_fault_control.enabled)
        return error.NativeMetalInflightVictimRequiresFaultShim;

    var argument_storage: [4096]u8 = undefined;
    var argument_allocator = std.heap.FixedBufferAllocator.init(
        &argument_storage,
    );
    var args = try std.process.argsWithAllocator(
        argument_allocator.allocator(),
    );
    defer args.deinit();
    const executable_path = args.next() orelse
        return error.MissingExecutablePath;
    if (args.next() != null) return error.UnexpectedArgument;

    const challenge_sha256 = try campaignChallenge(
        argument_allocator.allocator(),
    );
    const victim_sha256 = try fileSha256(executable_path);
    const metallib_path = std.mem.span(engine.metal_library_path);
    const metallib_sha256 = try fileSha256(metallib_path);
    const build_sha256 = buildIdentity(
        victim_sha256,
        metallib_sha256,
    );

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    var native_submission_live = false;
    defer if (!native_submission_live) backend.deinit();

    const initial_device = backend.initialDeviceInfo();
    const device_sha256 =
        native_observer.deviceIdentityV1(initial_device);
    const logical_cpu_count: u64 = std.math.cast(
        u64,
        try std.Thread.getCpuCount(),
    ) orelse return error.InvalidHostIdentity;
    if (logical_cpu_count == 0)
        return error.InvalidHostIdentity;
    const machine_sha256 = native_observer.machineIdentityV1(
        logical_cpu_count,
        device_sha256,
    );
    const placement_sha256 =
        native_observer.placementIdentityV1(initial_device);
    const backend_sha256 = backendIdentity();
    const profile_sha256 = profileIdentity();

    var storage: Storage = .{};
    const bound = try bindFixture(
        &storage,
        &backend,
        profile_sha256,
    );
    const attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            bound.fixture.bindings,
            storage.packed_weights.len,
            storage.scales.len,
            storage.input.len,
            storage.output.len,
            group_size,
            in_features,
            out_features,
        );
    const request =
        try storage.adapter.prepareMatvecDispatchRequestV1(
            attempt,
        );
    const pin = try storage.coordinator.acquireDispatchPin(
        bound.lease,
        storage.adapter.dispatchInterface(),
        request.request_sha256,
    );
    try lease_tree.validateDispatchPinV1(pin);

    const barrier_plan =
        try metal_fault_control.armNextInflightEventBarrierV1(
            &backend,
        );
    const ticket =
        try storage.adapter.submitMatvecInt4AsyncObserved(
            bound.lease,
            pin,
            bound.fixture.bindings,
            &storage.packed_weights,
            &storage.scales,
            &storage.input,
            &storage.output,
            group_size,
            in_features,
            out_features,
        );
    // From here onward, every failure remains process-scoped. Returning from
    // main is allowed to terminate the process, but the deferred backend
    // deinitializer must never manufacture local closure for this command.
    native_submission_live = true;

    const facts =
        metal_fault_control.waitForInflightEventBarrierV1(
            &backend,
            barrier_plan,
        ) catch blockForever();
    validateLiveBoundary(
        &storage,
        &backend,
        initial_device,
        pin,
        ticket,
        facts,
    ) catch blockForever();

    const frame = ready.makeReadyFrameV1(.{
        .pid = @intCast(std.c.getpid()),
        .barrier_generation = facts.barrier_generation,
        .command_generation = facts.token.generation,
        .submission_disposition = facts.submission_disposition,
        .command_buffer_status = facts.command_buffer_status,
        .commit_invoked = facts.commit_invoked,
        .completion_observed = facts.completion_observed,
        .shared_event_signaled_value = facts.shared_event_signaled_value,
        .encoded_signal_value = facts.signal_value,
        .encoded_wait_value = facts.wait_value,
        .live_native_buffer_count = facts.live_buffer_count,
        .live_native_command_count = facts.live_command_count,
        .active_allocation_reference_count = facts.active_allocation_reference_count,
        .challenge_sha256 = challenge_sha256,
        .victim_sha256 = victim_sha256,
        .metallib_sha256 = metallib_sha256,
        .build_sha256 = build_sha256,
        .machine_sha256 = machine_sha256,
        .backend_sha256 = backend_sha256,
        .device_sha256 = device_sha256,
        .placement_sha256 = placement_sha256,
        .ticket_sha256 = ticket.ticket_sha256,
        .pin_sha256 = pin.pin_sha256,
        .submission_sha256 = ticket.submission_sha256,
    }) catch blockForever();
    var wire: [ready.ready_frame_encoded_bytes]u8 = undefined;
    _ = ready.encodeReadyFrameV1(
        frame,
        &wire,
    ) catch blockForever();

    var stdout_buffer: [ready.ready_frame_encoded_bytes]u8 =
        undefined;
    var stdout_writer = std.fs.File.stdout().writer(
        &stdout_buffer,
    );
    stdout_writer.interface.writeAll(&wire) catch blockForever();
    stdout_writer.interface.flush() catch blockForever();
    blockForever();
}

fn bindFixture(
    storage: *Storage,
    backend: *engine.MetalBackend,
    profile_sha256: ready.Digest,
) !BoundFixture {
    if (backend.liveBufferCount() != 0 or
        try backend.nativeLiveBufferCount() != 0 or
        try backend.nativeLiveCommandCount() != 0)
        return error.DirtyMetalBackend;
    try backend.requireInt4MatvecSupport();

    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            backend,
            0x5737_4234_4d45,
            0,
            1 * 1024 * 1024,
        );
    storage.adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            backend,
            inventory_entry,
            0x5737_4234_4144,
            0x5737_4234_4d41,
            &storage.native_slots,
        );
    const fixture = try makeFixture(
        &storage.adapter,
        inventory_entry,
        profile_sha256,
    );
    if (fixture.manifest.total_charged_bytes !=
        persistent_device_bytes or
        fixture.requirement.queue_slots != 1)
        return error.InvalidVictimFixture;

    storage.bank = try resource.Bank.initWithLeaseTreePinStorage(
        &storage.bank_slots,
        &storage.tree_roots,
        &storage.tree_nodes,
        &storage.pin_slots,
        .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = persistent_device_bytes,
            .queue_slots = 1,
        },
        0x5737_4234_424b,
    );
    const parent = try storage.bank.commit(
        try storage.bank.reserve(
            0x5737_4234_5052,
            .{
                .capsule_bytes = 64,
                .queue_slots = 1,
            },
        ),
    );
    const opened = try storage.bank.openLeaseTree(
        parent,
        0x5737_4234_5452,
        0x5737_4234_4155,
        .{ .device_bytes = persistent_device_bytes },
    );
    const scoped = try storage.bank.openLeaseScope(
        opened,
        0x5737_4234_5343,
        0x5737_4234_544e,
        .{ .device_bytes = persistent_device_bytes },
    );
    storage.tree = scoped.tree;
    const session_id = @intFromPtr(&storage.session_anchor);
    if (session_id == 0) return error.InvalidSessionIdentity;
    try storage.bank.bindPublicationSessionWithLeaseTree(
        storage.tree,
        0x5737_4234_5251,
        session_id,
    );
    try storage.coordinator.initWithDispatchStorage(
        0x5737_4234_434f,
        &storage.bank,
        &storage.tree,
        scoped.scope,
        0x5737_4234_5251,
        session_id,
        &storage.publication_sequence,
        &storage.coordinator_objects,
        &storage.coordinator_dispatches,
    );
    const allocation_request = try allocation.makeRequestV1(
        0x5737_4234_5251,
        ownerIdentity(),
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
    const lease = switch (materialized) {
        .active => |value| value,
        .terminal, .recovery_required => return error.NativeAllocationNotMaterialized,
    };
    if (lease.allocation_count != 4 or
        lease.materialized_bytes != persistent_device_bytes or
        backend.liveBufferCount() != 4 or
        try backend.nativeLiveBufferCount() != 4)
        return error.InvalidNativeOwnership;
    return .{
        .fixture = fixture,
        .lease = lease,
    };
}

fn makeFixture(
    adapter: *metal_allocation.MetalAllocationAdapterV1,
    inventory_entry: device.DeviceInventoryEntryV1,
    profile_sha256: ready.Digest,
) !Fixture {
    const geometry = try metal_allocation.makeMatvecGeometryV1(
        group_size,
        in_features,
        out_features,
    );
    const bindings: metal_allocation.MetalMatvecAllocationBindingsV1 =
        .{
            .packed_weights_sha256 = bindingIdentity("packed"),
            .scales_sha256 = bindingIdentity("scales"),
            .input_sha256 = bindingIdentity("input"),
            .output_sha256 = bindingIdentity("output"),
        };
    const requested = [4]u64{
        geometry.packed_bytes,
        geometry.scales_bytes,
        geometry.input_bytes,
        geometry.output_bytes,
    };
    const role_bindings = [4]ready.Digest{
        bindings.packed_weights_sha256,
        bindings.scales_sha256,
        bindings.input_sha256,
        bindings.output_sha256,
    };
    var entries: [4]allocation.AllocationEntryV1 = undefined;
    for (0..4) |index| {
        const quote = try adapter.quote(
            role_bindings[index],
            requested[index],
        );
        entries[index] = .{
            .binding_sha256 = role_bindings[index],
            .requested_bytes = requested[index],
            .charged_bytes = quote.charged_bytes,
            .quote_sha256 = quote.quote_sha256,
        };
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

fn validateLiveBoundary(
    storage: *Storage,
    backend: *engine.MetalBackend,
    initial_device: metal.MetalDeviceInfo,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    ticket: metal_allocation.MetalAsyncDispatchTicketV1,
    facts: metal_fault_control.InflightBarrierFactsV1,
) !void {
    try metal_allocation.validateMetalAsyncDispatchTicketV1(
        ticket,
    );
    try lease_tree.validateDispatchPinV1(pin);
    if (!std.mem.eql(
        u8,
        &ticket.pin_sha256,
        &pin.pin_sha256,
    ) or !std.mem.eql(
        u8,
        &facts.submission_binding,
        &ticket.ticket_sha256,
    ) or facts.device_registry_id !=
        initial_device.registry_id or
        !std.meta.eql(
            storage.adapter
                .currentAsyncDispatchTicketForQueueSlotV1(0) orelse
                return error.MissingAsyncTicket,
            ticket,
        ) or storage.adapter
        .currentAsyncDispatchQuarantineForQueueSlotV1(0) != null or
        backend.liveBufferCount() != 4 or
        try backend.nativeLiveBufferCount() != 4 or
        try backend.nativeLiveCommandCount() != 1)
        return error.InvalidNativeOwnership;
}

fn campaignChallenge(
    allocator: std.mem.Allocator,
) !ready.Digest {
    const text = std.process.getEnvVarOwned(
        allocator,
        challenge_environment,
    ) catch |value| switch (value) {
        error.EnvironmentVariableNotFound => return error.MissingCampaignChallenge,
        error.InvalidWtf8 => return error.InvalidCampaignChallenge,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(text);
    if (text.len != 64)
        return error.InvalidCampaignChallenge;
    for (text) |byte| {
        if (!((byte >= '0' and byte <= '9') or
            (byte >= 'a' and byte <= 'f')))
            return error.InvalidCampaignChallenge;
    }
    var result: ready.Digest = undefined;
    _ = std.fmt.hexToBytes(
        &result,
        text,
    ) catch return error.InvalidCampaignChallenge;
    if (std.mem.allEqual(u8, &result, 0))
        return error.InvalidCampaignChallenge;
    return result;
}

fn fileSha256(path: []const u8) !ready.Digest {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [64 * 1024]u8 = undefined;
    while (true) {
        const length = try file.read(&bytes);
        if (length == 0) break;
        hash.update(bytes[0..length]);
    }
    var result: ready.Digest = undefined;
    hash.final(&result);
    return result;
}

fn buildIdentity(
    victim_sha256: ready.Digest,
    metallib_sha256: ready.Digest,
) ready.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(build_domain);
    hashU64(&hash, ready.ready_frame_abi);
    hashU64(
        &hash,
        metal_fault_control.inflight_barrier_plan_abi,
    );
    hashU64(
        &hash,
        metal_fault_control.inflight_barrier_facts_abi,
    );
    hash.update(&victim_sha256);
    hash.update(&metallib_sha256);
    return finishHash(&hash);
}

fn backendIdentity() ready.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(backend_domain);
    hashU64(&hash, ready.ready_frame_abi);
    hashU64(&hash, metal.device_info_abi);
    hashU64(&hash, metal.async_submission_abi);
    hashU64(&hash, metal_allocation.adapter_abi);
    hashU64(
        &hash,
        metal_fault_control.inflight_barrier_plan_abi,
    );
    hashU64(
        &hash,
        metal_fault_control.inflight_barrier_facts_abi,
    );
    return finishHash(&hash);
}

fn profileIdentity() ready.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(profile_domain);
    hashU64(&hash, ready.ready_frame_abi);
    hashU64(&hash, group_size);
    hashU64(&hash, in_features);
    hashU64(&hash, out_features);
    hashU64(&hash, element_count);
    hashU64(&hash, persistent_device_bytes);
    return finishHash(&hash);
}

fn ownerIdentity() ready.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(owner_domain);
    hash.update(&profileIdentity());
    return finishHash(&hash);
}

fn bindingIdentity(role: []const u8) ready.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(binding_domain);
    hash.update(role);
    return finishHash(&hash);
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

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &encoded,
        @intCast(value),
        .little,
    );
    hash.update(&encoded);
}

fn finishHash(
    hash: *std.crypto.hash.sha2.Sha256,
) ready.Digest {
    var result: ready.Digest = undefined;
    hash.final(&result);
    return result;
}

fn blockForever() noreturn {
    while (true)
        std.Thread.sleep(std.time.ns_per_s);
}
