//! Hard native Metal allocation ownership gate.
//!
//! This test must run only in the explicitly native macOS/Metal build step.
//! It creates real direct Shared MTLBuffers, observes each resource through
//! MTLResource, composes them with both the ChildLease and LeaseTree
//! coordinators, then proves rollback, release, and generation-fenced reuse.
//! It makes no residency, performance, or device-wide allocation-delta claim.

const std = @import("std");
const engine = @import("engine");
const config = @import("config");
const metal_fault_control = @import("metal_fault_control");

const testing = std.testing;
const allocation = engine.device_allocation_lease;
const tree_allocation = engine.device_allocation_lease_tree;
const device = engine.device_capability_contract;
const lifecycle = engine.device_lifecycle_contract;
const loss_dispatch_reconciliation =
    engine.device_loss_dispatch_reconciliation;
const loss_dispatch_callback_retirement =
    engine.device_loss_dispatch_callback_retirement;
const retirement = engine.device_loss_retirement;
const resource = engine.resource_bank;
const metal_allocation = engine.metal_allocation_adapter;
const metal_lifecycle = engine.metal_device_lifecycle_adapter;
const DispatchRetirementTelemetry =
    engine.metal_backend.MetalDispatchRetirementTelemetryV1;

const Fixture = struct {
    inventory: [1]device.DeviceInventoryEntryV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    entries: [3]allocation.AllocationEntryV1,
    manifest: allocation.AllocationManifestV1,
};

const DispatchFixture = struct {
    inventory: [1]device.DeviceInventoryEntryV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    bindings: metal_allocation.MetalMatvecAllocationBindingsV1,
    entries: [4]allocation.AllocationEntryV1,
    manifest: allocation.AllocationManifestV1,
};

const TwoSlotDispatchFixture = struct {
    inventory: [1]device.DeviceInventoryEntryV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    bindings: [2]metal_allocation.MetalMatvecAllocationBindingsV1,
    entries: [8]allocation.AllocationEntryV1,
    manifest: allocation.AllocationManifestV1,
};

fn digest(bytes: []const u8) allocation.Digest {
    var result: allocation.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn activeLeasePinCount(
    slots: []const resource.LeasePinSlotV1,
) usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (slot.active) count += 1;
    }
    return count;
}

fn initialDispatchRetirementTelemetry(
    backend: *engine.MetalBackend,
) !DispatchRetirementTelemetry {
    const snapshot = try backend.dispatchRetirementTelemetry();
    try engine.metal_backend
        .validateMetalDispatchRetirementTelemetryV1(snapshot);
    try testing.expectEqualDeep(
        DispatchRetirementTelemetry{
            .device_registry_id = backend.initialDeviceInfo().registry_id,
            .context_nonce = backend.initialDeviceLifecycleSourceIdentity()
                .context_nonce,
        },
        snapshot,
    );
    try testing.expectEqualDeep(
        snapshot,
        try backend.dispatchRetirementTelemetry(),
    );
    return snapshot;
}

fn expectDispatchRetirementTelemetry(
    backend: *engine.MetalBackend,
    expected: DispatchRetirementTelemetry,
) !void {
    const snapshot = try backend.dispatchRetirementTelemetry();
    try engine.metal_backend
        .validateMetalDispatchRetirementTelemetryV1(snapshot);
    try testing.expectEqualDeep(expected, snapshot);
    // Observation itself must not advance the source sequence or mutate any
    // ownership counter.
    try testing.expectEqualDeep(
        snapshot,
        try backend.dispatchRetirementTelemetry(),
    );
}

const held_callback_group_size: u32 = 8;
const held_callback_in_features: u32 = 64;
const held_callback_out_features: u32 = 37;
const held_callback_elements: usize =
    held_callback_in_features * held_callback_out_features;
const held_callback_packed_bytes: usize =
    (held_callback_elements + 1) / 2;
const held_callback_scale_count: usize =
    (held_callback_elements + held_callback_group_size - 1) /
    held_callback_group_size;

fn createHeldCallbackMatvecTokens(
    backend: *engine.MetalBackend,
) ![4]engine.metal_backend.MetalBufferToken {
    var tokens: [4]engine.metal_backend.MetalBufferToken =
        undefined;
    tokens[0] = try backend.createBufferAllocation(
        held_callback_packed_bytes,
    );
    errdefer backend.destroyBufferAllocation(tokens[0]) catch {};
    tokens[1] = try backend.createBufferAllocation(
        held_callback_scale_count * @sizeOf(f32),
    );
    errdefer backend.destroyBufferAllocation(tokens[1]) catch {};
    tokens[2] = try backend.createBufferAllocation(
        held_callback_in_features * @sizeOf(f32),
    );
    errdefer backend.destroyBufferAllocation(tokens[2]) catch {};
    tokens[3] = try backend.createBufferAllocation(
        held_callback_out_features * @sizeOf(f32),
    );
    return tokens;
}

fn destroyHeldCallbackMatvecTokens(
    backend: *engine.MetalBackend,
    tokens: [4]engine.metal_backend.MetalBufferToken,
) !void {
    for (tokens) |token|
        try backend.destroyBufferAllocation(token);
}

fn submitHeldCallbackMatvec(
    backend: *engine.MetalBackend,
    tokens: [4]engine.metal_backend.MetalBufferToken,
    binding: [32]u8,
) !engine.metal_backend.MetalAsyncSubmission {
    const packed_values =
        [_]u8{0} ** held_callback_packed_bytes;
    const scales =
        [_]f32{1.0} ** held_callback_scale_count;
    const input =
        [_]f32{0.25} ** held_callback_in_features;
    return backend.submitMatvecInt4RegisteredBuffers(
        binding,
        tokens[0],
        tokens[1],
        tokens[2],
        tokens[3],
        &packed_values,
        &scales,
        &input,
        held_callback_out_features,
        held_callback_group_size,
        held_callback_in_features,
        held_callback_out_features,
    );
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

fn makeDispatchFixture(
    adapter: *metal_allocation.MetalAllocationAdapterV1,
    inventory_entry: device.DeviceInventoryEntryV1,
) !DispatchFixture {
    const geometry = try metal_allocation.makeMatvecGeometryV1(
        8,
        64,
        37,
    );
    const bindings: metal_allocation.MetalMatvecAllocationBindingsV1 = .{
        .packed_weights_sha256 = digest(
            "native Metal dispatch packed weights",
        ),
        .scales_sha256 = digest(
            "native Metal dispatch scales",
        ),
        .input_sha256 = digest(
            "native Metal dispatch input",
        ),
        .output_sha256 = digest(
            "native Metal dispatch output",
        ),
    };
    var entries = [4]allocation.AllocationEntryV1{
        .{
            .binding_sha256 = bindings.packed_weights_sha256,
            .requested_bytes = geometry.packed_bytes,
        },
        .{
            .binding_sha256 = bindings.scales_sha256,
            .requested_bytes = geometry.scales_bytes,
        },
        .{
            .binding_sha256 = bindings.input_sha256,
            .requested_bytes = geometry.input_bytes,
        },
        .{
            .binding_sha256 = bindings.output_sha256,
            .requested_bytes = geometry.output_bytes,
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
            "native Metal pinned dispatch execution plan",
        ),
        .required_device_class = .accelerator,
        .required_operation_profile_bits = profile,
        .required_operator_bits = device.profileOperatorBitsV1(profile),
        .required_element_type_bits = device.profileElementTypeBitsV1(profile),
        .required_numerical_policy_bits = device.profileNumericalPolicyBitsV1(profile),
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
    return .{
        .inventory = inventory,
        .requirement = requirement,
        .selection = selected.receipt,
        .bindings = bindings,
        .entries = entries,
        .manifest = manifest,
    };
}

fn makeTwoSlotDispatchFixture(
    adapter: *metal_allocation.MetalAllocationAdapterV1,
    inventory_entry: device.DeviceInventoryEntryV1,
) !TwoSlotDispatchFixture {
    const geometry = try metal_allocation.makeMatvecGeometryV1(
        8,
        64,
        37,
    );
    const bindings = [2]metal_allocation.MetalMatvecAllocationBindingsV1{
        .{
            .packed_weights_sha256 = digest(
                "native Metal two-slot A packed weights",
            ),
            .scales_sha256 = digest(
                "native Metal two-slot A scales",
            ),
            .input_sha256 = digest(
                "native Metal two-slot A input",
            ),
            .output_sha256 = digest(
                "native Metal two-slot A output",
            ),
        },
        .{
            .packed_weights_sha256 = digest(
                "native Metal two-slot B packed weights",
            ),
            .scales_sha256 = digest(
                "native Metal two-slot B scales",
            ),
            .input_sha256 = digest(
                "native Metal two-slot B input",
            ),
            .output_sha256 = digest(
                "native Metal two-slot B output",
            ),
        },
    };
    var entries = [8]allocation.AllocationEntryV1{
        .{
            .binding_sha256 = bindings[0].packed_weights_sha256,
            .requested_bytes = geometry.packed_bytes,
        },
        .{
            .binding_sha256 = bindings[0].scales_sha256,
            .requested_bytes = geometry.scales_bytes,
        },
        .{
            .binding_sha256 = bindings[0].input_sha256,
            .requested_bytes = geometry.input_bytes,
        },
        .{
            .binding_sha256 = bindings[0].output_sha256,
            .requested_bytes = geometry.output_bytes,
        },
        .{
            .binding_sha256 = bindings[1].packed_weights_sha256,
            .requested_bytes = geometry.packed_bytes,
        },
        .{
            .binding_sha256 = bindings[1].scales_sha256,
            .requested_bytes = geometry.scales_bytes,
        },
        .{
            .binding_sha256 = bindings[1].input_sha256,
            .requested_bytes = geometry.input_bytes,
        },
        .{
            .binding_sha256 = bindings[1].output_sha256,
            .requested_bytes = geometry.output_bytes,
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
            "native Metal bounded two-slot execution plan",
        ),
        .required_device_class = .accelerator,
        .required_operation_profile_bits = profile,
        .required_operator_bits = device.profileOperatorBitsV1(profile),
        .required_element_type_bits = device.profileElementTypeBitsV1(profile),
        .required_numerical_policy_bits = device.profileNumericalPolicyBitsV1(profile),
        .required_feature_bits = device.FeatureBitsV1.allocation |
            device.FeatureBitsV1.dispatch |
            device.FeatureBitsV1.completion_fence |
            device.FeatureBitsV1.persistent_weights |
            device.FeatureBitsV1.allocated_bytes_observation |
            device.FeatureBitsV1.device_loss_signal,
        .largest_single_allocation_bytes = manifest.largest_charged_bytes,
        .total_device_bytes = manifest.total_charged_bytes,
        .queue_slots = 2,
        .fallback_policy = .forbidden,
    });
    const inventory = [1]device.DeviceInventoryEntryV1{
        inventory_entry,
    };
    const selected = try device.selectDeviceV1(
        requirement,
        &inventory,
    );
    return .{
        .inventory = inventory,
        .requirement = requirement,
        .selection = selected.receipt,
        .bindings = bindings,
        .entries = entries,
        .manifest = manifest,
    };
}

fn completePreSubmitRejection(
    coordinator: *tree_allocation.CoordinatorV1,
    adapter: *metal_allocation.MetalAllocationAdapterV1,
    backend: *engine.MetalBackend,
    lease: tree_allocation.LeaseTreeDeviceAllocationLeaseV1,
    roles: metal_allocation.MetalMatvecAllocationBindingsV1,
    packed_weights: []const u8,
    scales: []const f32,
    input: []const f32,
    output: []const f32,
    group_size: u32,
    in_features: u32,
    out_features: u32,
    expected_reason: metal_allocation
        .MetalMatvecPreSubmitRejectionReasonV1,
) !void {
    const attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            roles,
            @intCast(packed_weights.len),
            @intCast(scales.len),
            @intCast(input.len),
            @intCast(output.len),
            group_size,
            in_features,
            out_features,
        );
    const request =
        try adapter.prepareMatvecDispatchRequestV1(attempt);
    try testing.expectEqualDeep(
        request,
        try adapter.prepareMatvecDispatchRequestV1(attempt),
    );
    const pin = try coordinator.acquireDispatchPin(
        lease,
        adapter.dispatchInterface(),
        request.request_sha256,
    );
    const dispatch_count_before =
        backend.completedDispatchCount();
    const rejected =
        try adapter.rejectMatvecInt4BeforeSubmitObserved(
            lease,
            pin,
            roles,
            packed_weights,
            scales,
            input,
            output,
            group_size,
            in_features,
            out_features,
        );
    try testing.expectEqual(
        expected_reason,
        rejected.rejection.reason,
    );
    try testing.expectEqualDeep(
        request,
        rejected.rejection.request,
    );
    try metal_allocation
        .validateMetalMatvecPreSubmitRejectionForPinV1(
        rejected.rejection,
        pin,
        rejected.terminal,
    );
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );
    const completion = try coordinator.completeDispatchPin(
        pin,
        adapter.dispatchInterface(),
        rejected.terminal,
    );
    try tree_allocation.validateDispatchCompletionForPinV1(
        completion,
        pin,
        rejected.terminal,
    );
    try adapter.acknowledgeDispatchCompletion(completion);
    try testing.expectEqual(
        @as(usize, 0),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );
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

const MetalFaultArmWorker = struct {
    backend: *engine.MetalBackend,
    start: *std.atomic.Value(bool),
    plan: ?metal_fault_control.FaultPlanV1 = null,
    arm_error: ?metal_fault_control.Error = null,

    fn run(self: *@This()) void {
        while (!self.start.load(.acquire))
            std.atomic.spinLoopHint();
        self.plan =
            metal_fault_control
                .armNextCompletedAsCommandErrorV1(
                self.backend,
            ) catch |err| {
                self.arm_error = err;
                return;
            };
    }
};

const MetalRegisteredWaitWorker = struct {
    backend: *engine.MetalBackend,
    submission: engine.metal_backend.MetalAsyncSubmission,
    started: *std.atomic.Value(bool),
    finished: *std.atomic.Value(bool),
    completion: ?engine.metal_backend.MetalAsyncCompletion = null,
    wait_error: ?engine.metal_backend.MetalError = null,

    fn run(self: *@This()) void {
        self.started.store(true, .release);
        defer self.finished.store(true, .release);
        self.completion = self.backend.waitRegisteredDispatch(
            self.submission,
        ) catch |err| {
            self.wait_error = err;
            return;
        };
    }
};

const MetalAdapterWaitWorker = struct {
    adapter: *metal_allocation.MetalAllocationAdapterV1,
    lease: tree_allocation.LeaseTreeDeviceAllocationLeaseV1,
    pin: tree_allocation.LeaseTreeDispatchPinV1,
    ticket: metal_allocation.MetalAsyncDispatchTicketV1,
    output: []f32,
    started: *std.atomic.Value(bool),
    finished: *std.atomic.Value(bool),
    observation: ?metal_allocation.MetalAsyncDispatchPollV1 = null,
    wait_error: ?metal_allocation.Error = null,

    fn run(self: *@This()) void {
        self.started.store(true, .release);
        defer self.finished.store(true, .release);
        self.observation =
            self.adapter.waitMatvecInt4AsyncObserved(
                self.lease,
                self.pin,
                self.ticket,
                self.output,
            ) catch |err| {
                self.wait_error = err;
                return;
            };
    }
};

/// Keep cleanup bound to the live mutable backend rather than a deferred
/// receiver value.
const MetalBackendCleanup = struct {
    backend: *engine.MetalBackend,

    fn run(self: @This()) void {
        self.backend.deinit();
    }
};

const SettlementReplayDispatchAdapter = struct {
    inner: tree_allocation.DispatchAdapterV1,
    bank: *resource.Bank,
    backend: *engine.MetalBackend,
    expected_bank_permit: ?resource.LeasePinPermitV1 = null,
    confirmation_calls: u64 = 0,
    bank_consumed_before_native_finalize: bool = false,
    native_finalized_before_retry: bool = false,
    reject_first_confirmation: bool = true,

    fn interface(self: *@This()) tree_allocation.DispatchAdapterV1 {
        return .{
            .context = self,
            .dispatch_authority_sha256 = self.inner.dispatch_authority_sha256,
            .queue_authority_sha256 = self.inner.queue_authority_sha256,
            .reserve_dispatch_intent_fn = reserveDispatchIntent,
            .abort_dispatch_intent_fn = abortDispatchIntent,
            .validate_terminal_fn = validateTerminal,
            .confirm_settlement_fn = confirmSettlement,
        };
    }

    fn reserveDispatchIntent(
        context: *anyopaque,
        intent: tree_allocation.DispatchPinIntentV1,
    ) tree_allocation.DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.reserve_dispatch_intent_fn(
            self.inner.context,
            intent,
        );
    }

    fn abortDispatchIntent(
        context: *anyopaque,
        intent: tree_allocation.DispatchPinIntentV1,
    ) tree_allocation.DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.abort_dispatch_intent_fn(
            self.inner.context,
            intent,
        );
    }

    fn validateTerminal(
        context: *anyopaque,
        terminal: tree_allocation.DispatchTerminalEvidenceV1,
    ) tree_allocation.DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.validate_terminal_fn(
            self.inner.context,
            terminal,
        );
    }

    fn confirmSettlement(
        context: *anyopaque,
        pin: tree_allocation.LeaseTreeDispatchPinV1,
        terminal: tree_allocation.DispatchTerminalEvidenceV1,
        completion: tree_allocation.LeaseTreeDispatchCompletionV1,
        bank_permit: resource.LeasePinPermitV1,
        bank_completion: resource.LeasePinCompletionV1,
    ) tree_allocation.DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const first_confirmation =
            self.reject_first_confirmation;
        if (first_confirmation) {
            const expected_permit =
                self.expected_bank_permit orelse
                return error.InvalidSettlementEvidence;
            const bank_permit_consumed = blk: {
                self.bank.validateLeasePin(
                    bank_permit,
                ) catch |err| {
                    break :blk err ==
                        resource.Error.StaleReservation;
                };
                break :blk false;
            };
            const native_commands =
                self.backend.nativeLiveCommandCount() catch
                    return error.Unavailable;
            self.bank_consumed_before_native_finalize =
                std.meta.eql(
                    expected_permit,
                    bank_permit,
                ) and
                bank_permit_consumed and
                native_commands == 1;
        }
        try self.inner.confirm_settlement_fn(
            self.inner.context,
            pin,
            terminal,
            completion,
            bank_permit,
            bank_completion,
        );
        self.confirmation_calls += 1;
        if (first_confirmation) {
            self.native_finalized_before_retry =
                (self.backend.nativeLiveCommandCount() catch
                    return error.Unavailable) == 0;
            self.reject_first_confirmation = false;
            return error.InvalidSettlementEvidence;
        }
    }
};

const NativeCancelAtBoundary = struct {
    boundary: u64,

    fn callback(context: *anyopaque, boundary: u64) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return boundary == self.boundary;
    }

    fn probe(self: *@This()) allocation.CancellationProbeV1 {
        return .{
            .context = self,
            .cancelled_fn = callback,
        };
    }
};

const NativeTreeObserverAdapter = struct {
    inner: allocation.AdapterV1,
    bank: *resource.Bank,
    expected_device_bytes: u64,
    allocation_count: usize,
    expect_free_authorized: bool = true,
    reject_next_free: bool = false,
    ordering_violation: bool = false,
    free_attempts: u64 = 0,
    free_calls: u64 = 0,

    fn interface(self: *@This()) allocation.AdapterV1 {
        return .{
            .context = self,
            .authority = self.inner.authority,
            .quote_fn = quoteCallback,
            .allocate_fn = allocateCallback,
            .free_fn = freeCallback,
        };
    }

    fn quoteCallback(
        context: *anyopaque,
        binding_sha256: allocation.Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.quote_fn(
            self.inner.context,
            binding_sha256,
            requested_bytes,
        );
    }

    fn allocateCallback(
        context: *anyopaque,
        call: allocation.AllocationCallV1,
    ) allocation.CallbackError!allocation.BackendObjectV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.allocate_fn(self.inner.context, call);
    }

    fn freeCallback(
        context: *anyopaque,
        object: allocation.BackendObjectV1,
    ) allocation.CallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.free_attempts += 1;
        const snapshot = self.bank.snapshotV3() catch {
            self.ordering_violation = true;
            return allocation.CallbackError.Unavailable;
        };
        if (snapshot.used.device_bytes != self.expected_device_bytes)
            self.ordering_violation = true;
        if (self.expect_free_authorized) {
            if (snapshot.free_authorized_allocations !=
                self.allocation_count)
                self.ordering_violation = true;
        } else if (snapshot.reserved_unmaterialized_allocations !=
            self.allocation_count)
            self.ordering_violation = true;
        if (self.reject_next_free) {
            self.reject_next_free = false;
            return allocation.CallbackError.Unavailable;
        }
        try self.inner.free_fn(self.inner.context, object);
        self.free_calls += 1;
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
    const lifecycle_inventory =
        [_]device.DeviceInventoryEntryV1{inventory_entry};
    const lifecycle_claim =
        try metal_lifecycle.observeInitialLifecycleV1(
            &backend,
            inventory_entry,
            &lifecycle_inventory,
        );
    const lifecycle_observation = lifecycle_claim.observation;
    try testing.expectEqual(
        lifecycle.ObservationSourceV1.initial_membership,
        lifecycle_observation.source,
    );
    try testing.expectEqual(
        lifecycle.EvidenceClassV1.native,
        lifecycle_observation.evidence_class,
    );
    try testing.expectEqual(
        device.InventoryStateV1.present,
        lifecycle_observation.observed_state,
    );
    const initial_cursor: lifecycle.SourceCursorV1 = .{
        .source_instance_sha256 = lifecycle_observation.source_instance_sha256,
        .last_sequence = 0,
    };
    try lifecycle.validateObservationV1(
        lifecycle_observation,
        inventory_entry,
        &lifecycle_inventory,
        initial_cursor,
    );
    try testing.expectEqualDeep(
        lifecycle_claim.advanced_cursor,
        try lifecycle.validateAndAdvanceObservationV1(
            lifecycle_observation,
            inventory_entry,
            &lifecycle_inventory,
            initial_cursor,
        ),
    );
    const readable_after_claim =
        try backend.deviceLifecycleSnapshot();
    try testing.expectEqual(
        lifecycle_observation.source_sequence,
        readable_after_claim.event_sequence,
    );
    try testing.expectError(
        lifecycle.Error.StaleObservation,
        metal_lifecycle.observeInitialLifecycleV1(
            &backend,
            inventory_entry,
            &lifecycle_inventory,
        ),
    );
    try testing.expectEqualDeep(
        readable_after_claim,
        try backend.deviceLifecycleSnapshot(),
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

test "real Metal buffers compose with LeaseTree free permits" {
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    defer backend.deinit();
    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            &backend,
            111,
            0,
            1 * 1024 * 1024,
        );
    var native_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}} ** 3;
    var adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            inventory_entry,
            211,
            0x4d65_7461_6c54_7265,
            &native_slots,
        );
    const fixture = try makeFixture(&adapter, inventory_entry);
    try testing.expectEqual(
        @as(u64, 8_000),
        fixture.manifest.total_charged_bytes,
    );

    var bank_slots = [_]resource.Slot{.{}};
    var tree_roots = [_]resource.LeaseTreeRootSlot{.{}};
    var tree_nodes = [_]resource.LeaseNodeSlot{.{}} ** 4;
    var bank = try resource.Bank.initWithLeaseTreeStorage(
        &bank_slots,
        &tree_roots,
        &tree_nodes,
        .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = fixture.manifest.total_charged_bytes,
            .queue_slots = 1,
        },
        411,
    );
    const parent = try bank.commit(
        try bank.reserve(511, .{
            .capsule_bytes = 64,
            .queue_slots = 1,
        }),
    );
    const opened = try bank.openLeaseTree(
        parent,
        0x4d65_7461_6c54_7265,
        0x4d65_7461_6c41_7574,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    const scoped = try bank.openLeaseScope(
        opened,
        0x4d65_7461_6c53_636f,
        0x4d65_7461_6c54_656e,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    var tree = scoped.tree;
    var session_byte: u8 = 0;
    const session_id = @intFromPtr(&session_byte);
    var publication_sequence: u64 = 0;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        301,
        session_id,
    );
    var coordinator_objects =
        [_]tree_allocation.CoordinatorObjectSlotV1{.{}} ** 3;
    var coordinator: tree_allocation.CoordinatorV1 = .{};
    try coordinator.init(
        611,
        &bank,
        &tree,
        scoped.scope,
        301,
        session_id,
        &publication_sequence,
        &coordinator_objects,
    );
    const request = try makeRequest(&adapter, parent, fixture);
    var observed_adapter = NativeTreeObserverAdapter{
        .inner = adapter.interface(),
        .bank = &bank,
        .expected_device_bytes = fixture.manifest.total_charged_bytes,
        .allocation_count = fixture.entries.len,
    };

    var first_generations: [3]u64 = undefined;
    var first_lease: tree_allocation.LeaseTreeDeviceAllocationLeaseV1 = undefined;
    for (0..2) |cycle| {
        const admission = try coordinator.admit(
            observed_adapter.interface(),
            request,
            fixture.selection,
            fixture.requirement,
            &fixture.inventory,
            parent,
            fixture.manifest,
            &fixture.entries,
        );
        try tree_allocation.validateAdmissionV1(admission);
        var bank_snapshot = try bank.snapshotV3();
        try testing.expectEqual(
            fixture.manifest.total_charged_bytes,
            bank_snapshot.used.device_bytes,
        );
        try testing.expectEqual(
            @as(usize, 3),
            bank_snapshot.reserved_unmaterialized_allocations,
        );
        try testing.expectEqual(
            fixture.manifest.total_charged_bytes,
            tree.current.device_bytes,
        );
        try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());

        const materialized = try coordinator.materialize(
            admission,
            observed_adapter.interface(),
            .{},
        );
        const lease = switch (materialized) {
            .active => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try tree_allocation.validateLeaseV1(lease);
        if (cycle == 0) first_lease = lease;
        bank_snapshot = try bank.snapshotV3();
        try testing.expectEqual(
            @as(usize, 0),
            bank_snapshot.reserved_unmaterialized_allocations,
        );
        try testing.expectEqual(
            @as(usize, 3),
            bank_snapshot.live_allocations,
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
                fixture.entries[ordinal].requested_bytes,
                observation.buffer_length_bytes,
            );
            try testing.expect(
                observation.resource_allocated_size_bytes >=
                    observation.buffer_length_bytes,
            );
            try testing.expectEqual(
                adapter.snapshot().device_registry_id,
                observation.device_registry_id,
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

        const released = try coordinator.release(
            lease,
            observed_adapter.interface(),
        );
        const terminal = switch (released) {
            .terminal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try tree_allocation.validateTerminalReceiptV1(terminal);
        try testing.expectEqual(
            allocation.TerminalOutcomeV1.released,
            terminal.outcome,
        );
        try testing.expect(terminal.terminal_tree.current.isZero());
        bank_snapshot = try bank.snapshotV3();
        try testing.expectEqual(
            @as(u64, 0),
            bank_snapshot.used.device_bytes,
        );
        try testing.expectEqual(
            @as(usize, 0),
            bank_snapshot.free_authorized_allocations,
        );
        try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
        try testing.expectEqual(
            @as(u64, 0),
            try backend.nativeLiveBufferCount(),
        );
        try adapter.validateEmpty();
    }

    const cancelled_admission = try coordinator.admit(
        observed_adapter.interface(),
        request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    observed_adapter.expect_free_authorized = false;
    var cancel = NativeCancelAtBoundary{ .boundary = 2 };
    const cancelled = try coordinator.materialize(
        cancelled_admission,
        observed_adapter.interface(),
        cancel.probe(),
    );
    const cancel_terminal = switch (cancelled) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try tree_allocation.validateTerminalReceiptV1(
        cancel_terminal,
    );
    try testing.expectEqual(
        allocation.TerminalOutcomeV1.cancelled,
        cancel_terminal.outcome,
    );
    try testing.expectEqual(
        @as(u64, 0),
        (try bank.snapshotV3()).used.device_bytes,
    );
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try adapter.validateEmpty();
    try testing.expectError(
        tree_allocation.Error.InvalidTransition,
        coordinator.release(
            first_lease,
            observed_adapter.interface(),
        ),
    );
    const final_snapshot = adapter.snapshot();
    try testing.expectEqual(@as(u64, 8), final_snapshot.allocate_calls);
    try testing.expectEqual(@as(u64, 8), final_snapshot.free_calls);
    // The cancellation wave is released without copying observations.
    try testing.expectEqual(@as(u64, 6), final_snapshot.inspect_calls);
    try testing.expectEqual(@as(u64, 8), observed_adapter.free_calls);
    try testing.expect(!observed_adapter.ordering_violation);
    try bank.closePublicationSession(
        parent,
        301,
        session_id,
        publication_sequence,
    );
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
    try testing.expect((try bank.snapshot()).used.isZero());
}

test "fault-only synthetic loss retires real Metal references with recovery" {
    if (comptime !metal_fault_control.enabled)
        return error.SkipZigTest;
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    defer backend.deinit();
    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            &backend,
            113,
            0,
            1 * 1024 * 1024,
        );
    var native_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}} ** 3;
    var adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            inventory_entry,
            213,
            0x4c6f_7373_5265_7469,
            &native_slots,
        );
    const fixture = try makeFixture(&adapter, inventory_entry);

    var bank_slots = [_]resource.Slot{.{}};
    var tree_roots = [_]resource.LeaseTreeRootSlot{.{}};
    var tree_nodes = [_]resource.LeaseNodeSlot{.{}} ** 4;
    var bank = try resource.Bank.initWithLeaseTreeStorage(
        &bank_slots,
        &tree_roots,
        &tree_nodes,
        .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = fixture.manifest.total_charged_bytes,
            .queue_slots = 1,
        },
        413,
    );
    const parent = try bank.commit(
        try bank.reserve(513, .{
            .capsule_bytes = 64,
            .queue_slots = 1,
        }),
    );
    const opened = try bank.openLeaseTree(
        parent,
        0x4c6f_7373_526f_6f74,
        0x4c6f_7373_4175_7468,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    const scoped = try bank.openLeaseScope(
        opened,
        0x4c6f_7373_5363_6f70,
        0x4c6f_7373_5465_6e74,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    var tree = scoped.tree;
    var session_byte: u8 = 0;
    const session_id = @intFromPtr(&session_byte);
    var publication_sequence: u64 = 0;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        301,
        session_id,
    );
    var coordinator_objects =
        [_]tree_allocation.CoordinatorObjectSlotV1{.{}} ** 3;
    var coordinator: tree_allocation.CoordinatorV1 = .{};
    try coordinator.init(
        613,
        &bank,
        &tree,
        scoped.scope,
        301,
        session_id,
        &publication_sequence,
        &coordinator_objects,
    );
    const request = try makeRequest(&adapter, parent, fixture);
    var observed_adapter = NativeTreeObserverAdapter{
        .inner = adapter.interface(),
        .bank = &bank,
        .expected_device_bytes = fixture.manifest.total_charged_bytes,
        .allocation_count = fixture.entries.len,
    };
    const admission = try coordinator.admit(
        observed_adapter.interface(),
        request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const materialized = try coordinator.materialize(
        admission,
        observed_adapter.interface(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(u64, 3), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 3),
        try backend.nativeLiveBufferCount(),
    );
    const retained_native_token = native_slots[0].native_token;
    try testing.expect(!retained_native_token.isZero());

    const source_cursor: lifecycle.SourceCursorV1 = .{
        .source_instance_sha256 = digest(
            "fault-only Metal loss source instance",
        ),
        .last_sequence = 0,
    };
    const observation = try lifecycle.makeObservationV1(
        inventory_entry,
        &fixture.inventory,
        source_cursor.source_instance_sha256,
        1,
        .test_injected,
        digest("fault-only Metal loss evidence"),
        0,
        0,
        0,
    );
    const successor_entry = try lifecycle.makeSuccessorEntryV1(
        observation,
        inventory_entry,
        &fixture.inventory,
        source_cursor,
        inventory_entry.discovery_epoch + 1,
    );
    const transition = try lifecycle.makeTransitionReceiptV1(
        observation,
        inventory_entry,
        &fixture.inventory,
        successor_entry,
        source_cursor,
    );
    var copied_adapter = adapter;
    try testing.expectError(
        metal_allocation.Error.InvalidConfiguration,
        copied_adapter.lossRetirementAdapterChallengeV1(
            &coordinator,
            observed_adapter.interface(),
            observation,
            lease,
        ),
    );
    var forged_object_set_lease = lease;
    forged_object_set_lease.backend_object_set_sha256 =
        digest("forged loss backend object set");
    forged_object_set_lease.lease_sha256 =
        tree_allocation.leaseRootV1(forged_object_set_lease);
    try testing.expectError(
        tree_allocation.Error.InvalidTransition,
        adapter.lossRetirementAdapterChallengeV1(
            &coordinator,
            observed_adapter.interface(),
            observation,
            forged_object_set_lease,
        ),
    );
    var forged_leaf_set_lease = lease;
    forged_leaf_set_lease.allocation_leaf_set_sha256 =
        digest("forged loss allocation leaf set");
    forged_leaf_set_lease.lease_sha256 =
        tree_allocation.leaseRootV1(forged_leaf_set_lease);
    try testing.expectError(
        tree_allocation.Error.InvalidTransition,
        adapter.lossRetirementAdapterChallengeV1(
            &coordinator,
            observed_adapter.interface(),
            observation,
            forged_leaf_set_lease,
        ),
    );
    var forged_request_lease = lease;
    forged_request_lease.request_sha256 =
        digest("forged loss allocation request");
    forged_request_lease.lease_sha256 =
        tree_allocation.leaseRootV1(forged_request_lease);
    try testing.expectError(
        tree_allocation.Error.InvalidTransition,
        adapter.lossRetirementAdapterChallengeV1(
            &coordinator,
            observed_adapter.interface(),
            observation,
            forged_request_lease,
        ),
    );
    try testing.expectEqual(@as(u64, 3), backend.liveBufferCount());
    try testing.expectEqual(@as(u64, 0), adapter.snapshot().free_calls);

    const adapter_challenge =
        try adapter.lossRetirementAdapterChallengeV1(
            &coordinator,
            observed_adapter.interface(),
            observation,
            lease,
        );
    const plan = try retirement.makeLossRetirementPlanV1(
        observation,
        transition,
        source_cursor,
        fixture.requirement,
        fixture.selection,
        &fixture.inventory,
        inventory_entry,
        successor_entry,
        adapter.authority,
        lease,
        1,
        adapter_challenge,
    );
    const forged_leaf_plan =
        try retirement.makeLossRetirementPlanV1(
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            adapter.authority,
            forged_leaf_set_lease,
            1,
            adapter_challenge,
        );
    try testing.expectError(
        tree_allocation.Error.InvalidTransition,
        adapter.armSyntheticLossRetirementForTestV1(
            &coordinator,
            observed_adapter.interface(),
            forged_leaf_plan,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            forged_leaf_set_lease,
        ),
    );
    try testing.expectError(
        retirement.Error.ProductionEvidenceRequired,
        adapter.armLossRetirementV1(
            &coordinator,
            observed_adapter.interface(),
            plan,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            lease,
        ),
    );

    const geometry = try metal_allocation.makeMatvecGeometryV1(
        8,
        64,
        37,
    );
    const prepared_attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            .{
                .packed_weights_sha256 = digest("loss prepared packed"),
                .scales_sha256 = digest("loss prepared scales"),
                .input_sha256 = digest("loss prepared input"),
                .output_sha256 = digest("loss prepared output"),
            },
            geometry.packed_bytes,
            geometry.scale_count,
            geometry.input_count,
            geometry.output_count,
            geometry.group_size,
            geometry.in_features,
            geometry.out_features,
        );
    const prepared =
        try adapter.prepareMatvecDispatchRequestV1(
            prepared_attempt,
        );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.armSyntheticLossRetirementForTestV1(
            &coordinator,
            observed_adapter.interface(),
            plan,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            lease,
        ),
    );
    try adapter.cancelPreparedMatvecDispatchRequestV1(prepared);

    try adapter.armSyntheticLossRetirementForTestV1(
        &coordinator,
        observed_adapter.interface(),
        plan,
        observation,
        transition,
        source_cursor,
        fixture.requirement,
        fixture.selection,
        &fixture.inventory,
        inventory_entry,
        successor_entry,
        lease,
    );
    try adapter.armSyntheticLossRetirementForTestV1(
        &coordinator,
        observed_adapter.interface(),
        plan,
        observation,
        transition,
        source_cursor,
        fixture.requirement,
        fixture.selection,
        &fixture.inventory,
        inventory_entry,
        successor_entry,
        lease,
    );
    try testing.expectError(
        engine.metal_backend.MetalError.DeviceLost,
        backend.inspectBufferAllocation(retained_native_token),
    );
    try testing.expectError(
        engine.metal_backend.MetalError.DeviceLost,
        backend.createBufferAllocation(64),
    );
    try testing.expectEqual(@as(u64, 0), backend.liveWeightCount());
    const inspect_calls_after_arm =
        adapter.snapshot().inspect_calls;
    var forbidden_observations =
        [_]metal_allocation.MetalAllocationObservationV1{.{}} ** 3;
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.copyLiveObservations(&forbidden_observations),
    );
    try testing.expectEqual(
        inspect_calls_after_arm,
        adapter.snapshot().inspect_calls,
    );

    observed_adapter.reject_next_free = true;
    const first_release = try coordinator.release(
        lease,
        observed_adapter.interface(),
    );
    const recovery = switch (first_release) {
        .recovery_required => |value| value,
        .terminal => return error.TestUnexpectedResult,
    };
    try tree_allocation.validateRecoveryV1(recovery);
    try testing.expectEqual(
        tree_allocation.RecoveryPhaseV1.free_authorized,
        recovery.phase,
    );
    try testing.expectEqual(@as(u64, 1), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveBufferCount(),
    );
    try testing.expectEqual(@as(u64, 3), observed_adapter.free_attempts);
    try testing.expectEqual(@as(u64, 2), observed_adapter.free_calls);
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.copyLiveObservations(&forbidden_observations),
    );
    try testing.expectEqual(
        inspect_calls_after_arm,
        adapter.snapshot().inspect_calls,
    );

    const retried = try coordinator.retryRecovery(
        recovery,
        observed_adapter.interface(),
    );
    const terminal = switch (retried) {
        .terminal => |value| value,
        .recovery_required => return error.TestUnexpectedResult,
    };
    const receipt = try adapter.completeLossRetirementV1(
        plan,
        terminal,
    );
    try retirement.validateLossRetirementReceiptV1(
        receipt,
        plan,
        terminal,
    );
    try testing.expectEqual(plan.allocation_count, receipt.reference_release_count);
    try testing.expectEqual(@as(u64, 0), receipt.physical_reclaim_observed);
    try testing.expectEqual(
        plan.materialized_bytes,
        receipt.returned_logical_device_bytes,
    );
    try testing.expectEqualDeep(
        receipt,
        try adapter.completeLossRetirementV1(plan, terminal),
    );
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(@as(u64, 4), observed_adapter.free_attempts);
    try testing.expectEqual(@as(u64, 3), observed_adapter.free_calls);
    try testing.expect(!observed_adapter.ordering_violation);
    try adapter.validateEmpty();

    try bank.closePublicationSession(
        parent,
        301,
        session_id,
        publication_sequence,
    );
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
    try testing.expect((try bank.snapshot()).used.isZero());
}

fn runRealMetalDispatchLifecycle(
    comptime include_injected_fault: bool,
) !void {
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    const allocator = testing.allocator;
    const group_size: usize = 8;
    const in_features: usize = 64;
    const out_features: usize = 37;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    const backend_cleanup: MetalBackendCleanup = .{
        .backend = &backend,
    };
    defer backend_cleanup.run();
    const retirement_telemetry_before =
        try initialDispatchRetirementTelemetry(&backend);
    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            &backend,
            112,
            0,
            1 * 1024 * 1024,
        );
    var native_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}} ** 4;
    var adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            inventory_entry,
            212,
            0x4d65_7461_6c44_7370,
            &native_slots,
        );
    const fixture = try makeDispatchFixture(
        &adapter,
        inventory_entry,
    );
    try testing.expectEqual(
        @as(u64, 2_772),
        fixture.manifest.total_charged_bytes,
    );

    var bank_slots = [_]resource.Slot{.{}};
    var tree_roots = [_]resource.LeaseTreeRootSlot{.{}};
    var tree_nodes = [_]resource.LeaseNodeSlot{.{}} ** 5;
    var pin_slots = [_]resource.LeasePinSlotV1{.{}};
    var bank = try resource.Bank.initWithLeaseTreePinStorage(
        &bank_slots,
        &tree_roots,
        &tree_nodes,
        &pin_slots,
        .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = fixture.manifest.total_charged_bytes,
            .queue_slots = 1,
        },
        412,
    );
    const parent = try bank.commit(
        try bank.reserve(512, .{
            .capsule_bytes = 64,
            .queue_slots = 1,
        }),
    );
    const opened = try bank.openLeaseTree(
        parent,
        0x4d65_7461_6c44_7370,
        0x4d65_7461_6c44_4175,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    const scoped = try bank.openLeaseScope(
        opened,
        0x4d65_7461_6c44_5363,
        0x4d65_7461_6c44_546e,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    var tree = scoped.tree;
    var session_byte: u8 = 0;
    const session_id = @intFromPtr(&session_byte);
    var publication_sequence: u64 = 0;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        302,
        session_id,
    );
    var coordinator_objects =
        [_]tree_allocation.CoordinatorObjectSlotV1{.{}} ** 4;
    var coordinator_dispatches =
        [_]tree_allocation.CoordinatorDispatchSlotV1{.{}};
    var coordinator: tree_allocation.CoordinatorV1 = .{};
    try coordinator.initWithDispatchStorage(
        612,
        &bank,
        &tree,
        scoped.scope,
        302,
        session_id,
        &publication_sequence,
        &coordinator_objects,
        &coordinator_dispatches,
    );
    const request = try allocation.makeRequestV1(
        302,
        digest("native Metal pinned dispatch owner"),
        adapter.authority,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const admission = try coordinator.admit(
        adapter.interface(),
        request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const materialized = try coordinator.materialize(
        admission,
        adapter.interface(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(u64, 4), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 4),
        try backend.nativeLiveBufferCount(),
    );

    var rng = std.Random.DefaultPrng.init(0x474c_4143_4945_52);
    var weights: [in_features * out_features]f32 =
        undefined;
    var input: [in_features]f32 = undefined;
    for (&weights) |*value|
        value.* =
            (rng.random().float(f32) * 2 - 1) * 0.25;
    for (&input) |*value|
        value.* = rng.random().float(f32) * 2 - 1;
    const quantized = try engine.core.quant.quantize(
        f32,
        allocator,
        &weights,
        .int4,
        group_size,
    );
    defer {
        allocator.free(quantized.packed_bytes);
        allocator.free(quantized.scales);
    }
    var input_tensor = try engine.core.tensor.fromF32(
        allocator,
        &.{ 1, in_features },
        &input,
    );
    defer input_tensor.deinit();
    var cpu_output = try engine.core.tensor.zerosF32(
        allocator,
        &.{ 1, out_features },
    );
    defer cpu_output.deinit();
    try engine.int4_matmul.linearInt4OnTheFly(
        input_tensor,
        quantized.packed_bytes,
        quantized.scales,
        &.{},
        cpu_output,
        out_features,
        in_features,
        group_size,
    );
    var gpu_output = [_]f32{0} ** out_features;
    const dispatch_count_before =
        backend.completedDispatchCount();

    const rejected_output = gpu_output[0 .. out_features - 1];
    const rejected_attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings,
            @intCast(quantized.packed_bytes.len),
            @intCast(quantized.scales.len),
            @intCast(input.len),
            @intCast(rejected_output.len),
            group_size,
            in_features,
            out_features,
        );
    const cancelled_request =
        try adapter.prepareMatvecDispatchRequestV1(
            rejected_attempt,
        );
    const allocation_interface = adapter.interface();
    try testing.expectError(
        allocation.CallbackError.Unavailable,
        allocation_interface.allocate_fn(
            allocation_interface.context,
            .{},
        ),
    );
    try testing.expectError(
        allocation.CallbackError.Unavailable,
        allocation_interface.free_fn(
            allocation_interface.context,
            .{},
        ),
    );
    try adapter.cancelPreparedMatvecDispatchRequestV1(
        cancelled_request,
    );
    try adapter.cancelPreparedMatvecDispatchRequestV1(
        cancelled_request,
    );
    const rejected_request =
        try adapter.prepareMatvecDispatchRequestV1(
            rejected_attempt,
        );
    try testing.expect(
        rejected_request.request_generation >
            cancelled_request.request_generation,
    );
    try testing.expect(!device.digestEqual(
        rejected_request.request_sha256,
        cancelled_request.request_sha256,
    ));
    try testing.expectEqualDeep(
        rejected_request,
        try adapter.prepareMatvecDispatchRequestV1(
            rejected_attempt,
        ),
    );
    const rejected_pin = try coordinator.acquireDispatchPin(
        lease,
        adapter.dispatchInterface(),
        rejected_request.request_sha256,
    );
    try tree_allocation.validateDispatchPinV1(rejected_pin);
    const allocation_snapshot_before_release =
        adapter.snapshot();
    try testing.expectError(
        tree_allocation.Error.DispatchInFlight,
        coordinator.release(
            lease,
            adapter.interface(),
        ),
    );
    try testing.expectEqualDeep(
        allocation_snapshot_before_release,
        adapter.snapshot(),
    );

    // A structurally valid public terminal has no authority until the exact
    // adapter records the matching deterministic pre-submit failure.
    const unarmed_terminal =
        try tree_allocation.makeDispatchTerminalV1(
            rejected_pin,
            .rejected_before_submit,
            allocation.zero_digest,
            allocation.zero_digest,
            allocation.zero_digest,
        );
    try testing.expectError(
        tree_allocation.Error.InvalidDispatchTerminal,
        coordinator.completeDispatchPin(
            rejected_pin,
            adapter.dispatchInterface(),
            unarmed_terminal,
        ),
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try coordinator.snapshot()).active_dispatches,
    );

    const rejected =
        try adapter.rejectMatvecInt4BeforeSubmitObserved(
            lease,
            rejected_pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            rejected_output,
            group_size,
            in_features,
            out_features,
        );
    try testing.expectEqual(
        metal_allocation
            .MetalMatvecPreSubmitRejectionReasonV1
            .invalid_host_lengths,
        rejected.rejection.reason,
    );
    try testing.expectEqualDeep(
        rejected_request,
        rejected.rejection.request,
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.cancelPreparedMatvecDispatchRequestV1(
            rejected_request,
        ),
    );
    try metal_allocation
        .validateMetalMatvecPreSubmitRejectionForPinV1(
        rejected.rejection,
        rejected_pin,
        rejected.terminal,
    );
    var reason_substitution = rejected.rejection;
    reason_substitution.reason = .invalid_geometry;
    reason_substitution.rejection_sha256 =
        metal_allocation
            .metalMatvecPreSubmitRejectionRootV1(
            reason_substitution,
        );
    try testing.expectError(
        metal_allocation.Error.InvalidDispatchEvidence,
        metal_allocation
            .validateMetalMatvecPreSubmitRejectionForPinV1(
            reason_substitution,
            rejected_pin,
            rejected.terminal,
        ),
    );
    var request_substitution = rejected.rejection;
    request_substitution.request =
        try metal_allocation.makeMetalMatvecDispatchRequestV1(
            rejected_request.request_generation + 1,
            rejected_request.dispatch_authority_sha256,
            rejected_request.queue_authority_sha256,
            rejected_request.attempt,
        );
    request_substitution.rejection_sha256 =
        metal_allocation
            .metalMatvecPreSubmitRejectionRootV1(
            request_substitution,
        );
    try metal_allocation
        .validateMetalMatvecPreSubmitRejectionV1(
        request_substitution,
    );
    try testing.expectError(
        metal_allocation.Error.InvalidDispatchEvidence,
        metal_allocation
            .validateMetalMatvecPreSubmitRejectionForPinV1(
            request_substitution,
            rejected_pin,
            rejected.terminal,
        ),
    );
    const cancelled_substitution =
        try tree_allocation.makeDispatchTerminalV1(
            rejected_pin,
            .cancelled_before_submit,
            allocation.zero_digest,
            allocation.zero_digest,
            allocation.zero_digest,
        );
    try testing.expectError(
        tree_allocation.Error.InvalidDispatchTerminal,
        coordinator.completeDispatchPin(
            rejected_pin,
            adapter.dispatchInterface(),
            cancelled_substitution,
        ),
    );
    try testing.expect(rejected.terminal.outcome ==
        .rejected_before_submit);
    try testing.expect(device.digestEqual(
        rejected.terminal.submission_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        rejected.terminal.backend_completion_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        rejected.terminal.output_sha256,
        allocation.zero_digest,
    ));
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );
    const dispatch_interface = adapter.dispatchInterface();
    try dispatch_interface.validate_terminal_fn(
        dispatch_interface.context,
        rejected.terminal,
    );
    try testing.expectError(
        metal_allocation.Error.InvalidDispatchEvidence,
        adapter.acknowledgeDispatchCompletion(.{}),
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.prepareMatvecDispatchRequestV1(
            rejected_attempt,
        ),
    );
    const rejection_replay =
        try adapter.rejectMatvecInt4BeforeSubmitObserved(
            lease,
            rejected_pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            rejected_output,
            group_size,
            in_features,
            out_features,
        );
    try testing.expectEqualDeep(rejected, rejection_replay);
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.rejectMatvecInt4BeforeSubmitObserved(
            lease,
            rejected_pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            &gpu_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.dispatchMatvecInt4Observed(
            lease,
            rejected_pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            &gpu_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectError(
        tree_allocation.Error.DispatchInFlight,
        coordinator.release(
            lease,
            adapter.interface(),
        ),
    );
    const rejection_completion =
        try coordinator.completeDispatchPin(
            rejected_pin,
            adapter.dispatchInterface(),
            rejected.terminal,
        );
    try tree_allocation.validateDispatchCompletionForPinV1(
        rejection_completion,
        rejected_pin,
        rejected.terminal,
    );
    // The private settlement callback finalized A atomically, so B can be
    // prepared before the compatibility acknowledgement of A.
    const next_attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings,
            @intCast(quantized.packed_bytes.len),
            @intCast(quantized.scales.len),
            @intCast(input.len),
            @intCast(gpu_output.len),
            0,
            in_features,
            out_features,
        );
    const next_request =
        try adapter.prepareMatvecDispatchRequestV1(
            next_attempt,
        );
    try testing.expect(
        next_request.request_generation >
            rejected_request.request_generation,
    );
    try adapter.acknowledgeDispatchCompletion(
        rejection_completion,
    );
    // Exact acknowledgement replay is harmless, but the consumed pin cannot
    // authorize another rejection.
    try adapter.acknowledgeDispatchCompletion(
        rejection_completion,
    );
    try testing.expectError(
        metal_allocation.Error.StaleObject,
        adapter.rejectMatvecInt4BeforeSubmitObserved(
            lease,
            rejected_pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            rejected_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );

    try completePreSubmitRejection(
        &coordinator,
        &adapter,
        &backend,
        lease,
        fixture.bindings,
        quantized.packed_bytes,
        quantized.scales,
        &input,
        &gpu_output,
        0,
        in_features,
        out_features,
        .invalid_geometry,
    );
    var duplicate_roles = fixture.bindings;
    duplicate_roles.output_sha256 =
        duplicate_roles.input_sha256;
    const duplicate_attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            duplicate_roles,
            @intCast(quantized.packed_bytes.len),
            @intCast(quantized.scales.len),
            @intCast(input.len),
            @intCast(gpu_output.len),
            group_size,
            in_features,
            out_features,
        );
    const duplicate_request =
        try adapter.prepareMatvecDispatchRequestV1(
            duplicate_attempt,
        );
    try testing.expect(
        duplicate_request.request_generation >
            rejected_request.request_generation,
    );
    const parallel_rejected_request =
        try adapter.prepareMatvecDispatchRequestV1(
            rejected_attempt,
        );
    try testing.expect(
        parallel_rejected_request.request_generation >
            duplicate_request.request_generation,
    );
    try adapter.cancelPreparedMatvecDispatchRequestV1(
        parallel_rejected_request,
    );
    // A has settled and two distinct requests can now stage independently.
    // The old A pin cannot replay its attempt through either terminal path.
    try testing.expectError(
        metal_allocation.Error.InvalidDispatchEvidence,
        adapter.rejectMatvecInt4BeforeSubmitObserved(
            lease,
            rejected_pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            rejected_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectError(
        metal_allocation.Error.InvalidDispatchEvidence,
        adapter.dispatchMatvecInt4Observed(
            lease,
            rejected_pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            &gpu_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    try completePreSubmitRejection(
        &coordinator,
        &adapter,
        &backend,
        lease,
        duplicate_roles,
        quantized.packed_bytes,
        quantized.scales,
        &input,
        &gpu_output,
        group_size,
        in_features,
        out_features,
        .invalid_role_bindings,
    );
    var foreign_role = fixture.bindings;
    foreign_role.output_sha256 =
        digest("native Metal dispatch foreign output role");
    try completePreSubmitRejection(
        &coordinator,
        &adapter,
        &backend,
        lease,
        foreign_role,
        quantized.packed_bytes,
        quantized.scales,
        &input,
        &gpu_output,
        group_size,
        in_features,
        out_features,
        .invalid_role_mapping,
    );

    const dispatch_attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings,
            @intCast(quantized.packed_bytes.len),
            @intCast(quantized.scales.len),
            @intCast(input.len),
            @intCast(gpu_output.len),
            group_size,
            in_features,
            out_features,
        );
    const cancellation_request =
        try adapter.prepareMatvecDispatchRequestV1(
            dispatch_attempt,
        );
    const cancellation_pin =
        try coordinator.acquireDispatchPin(
            lease,
            adapter.dispatchInterface(),
            cancellation_request.request_sha256,
        );
    try testing.expectError(
        metal_allocation.Error.DispatchPreflightPassed,
        adapter.rejectMatvecInt4BeforeSubmitObserved(
            lease,
            cancellation_pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            &gpu_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.cancelPreparedMatvecDispatchRequestV1(
            cancellation_request,
        ),
    );

    // Cancellation must not depend on a live device revalidation. Injected
    // device-identity drift would fail the normal dispatch inspection path,
    // but the exact sealed request/intent/pin can still be abandoned without
    // constructing or submitting a command buffer.
    const cancellation_terminal = cancellation: {
        const original_device_sha256 =
            adapter.device_sha256;
        adapter.device_sha256[0] ^= 1;
        defer adapter.device_sha256 =
            original_device_sha256;
        const first =
            try adapter.cancelMatvecBeforeSubmitObserved(
                lease,
                cancellation_pin,
            );
        const replay =
            try adapter.cancelMatvecBeforeSubmitObserved(
                lease,
                cancellation_pin,
            );
        try testing.expectEqualDeep(first, replay);
        break :cancellation first;
    };
    try testing.expect(
        cancellation_terminal.outcome ==
            .cancelled_before_submit,
    );
    try testing.expect(device.digestEqual(
        cancellation_terminal.submission_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        cancellation_terminal.backend_completion_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        cancellation_terminal.output_sha256,
        allocation.zero_digest,
    ));
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );
    const cancellation_completion =
        try coordinator.completeDispatchPin(
            cancellation_pin,
            adapter.dispatchInterface(),
            cancellation_terminal,
        );
    try tree_allocation.validateDispatchCompletionForPinV1(
        cancellation_completion,
        cancellation_pin,
        cancellation_terminal,
    );
    try adapter.acknowledgeDispatchCompletion(
        cancellation_completion,
    );
    try testing.expectEqual(
        @as(usize, 0),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );

    const dispatch_request =
        try adapter.prepareMatvecDispatchRequestV1(
            dispatch_attempt,
        );
    try testing.expectEqualDeep(
        dispatch_request,
        try adapter.prepareMatvecDispatchRequestV1(
            dispatch_attempt,
        ),
    );
    try testing.expect(
        dispatch_request.request_generation >
            cancellation_request.request_generation,
    );
    try testing.expectError(
        metal_allocation.Error.StaleObject,
        adapter.cancelMatvecBeforeSubmitObserved(
            lease,
            cancellation_pin,
        ),
    );
    const pin = try coordinator.acquireDispatchPin(
        lease,
        adapter.dispatchInterface(),
        dispatch_request.request_sha256,
    );
    try tree_allocation.validateDispatchPinV1(pin);
    try testing.expectError(
        tree_allocation.Error.DispatchInFlight,
        coordinator.release(
            lease,
            adapter.interface(),
        ),
    );
    try testing.expectEqual(
        fixture.manifest.total_charged_bytes,
        (try bank.snapshotV3()).used.device_bytes,
    );
    try testing.expectError(
        metal_allocation.Error.DispatchPreflightPassed,
        adapter.rejectMatvecInt4BeforeSubmitObserved(
            lease,
            pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            &gpu_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.prepareMatvecDispatchRequestV1(
            dispatch_attempt,
        ),
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.cancelPreparedMatvecDispatchRequestV1(
            dispatch_request,
        ),
    );
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );
    const output_before_async = gpu_output;
    const async_ticket =
        try adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            &gpu_output,
            group_size,
            in_features,
            out_features,
        );
    try metal_allocation.validateMetalAsyncDispatchTicketV1(
        async_ticket,
    );
    try testing.expectEqualDeep(
        async_ticket,
        try adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            &gpu_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectError(
        engine.metal_backend.MetalError.InvalidObservation,
        backend.destroyBufferAllocation(
            native_slots[0].native_token,
        ),
    );
    var changed_input = input;
    changed_input[0] += 0.25;
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &changed_input,
            &gpu_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    const first_poll =
        try adapter.pollMatvecInt4AsyncObserved(
            lease,
            pin,
            async_ticket,
            &gpu_output,
        );
    const dispatch_result = switch (first_poll) {
        .pending => blk: {
            try testing.expectEqualSlices(
                f32,
                &output_before_async,
                &gpu_output,
            );
            const waited =
                try adapter.waitMatvecInt4AsyncObserved(
                    lease,
                    pin,
                    async_ticket,
                    &gpu_output,
                );
            break :blk switch (waited) {
                .completed => |result| result,
                .pending, .quarantined => return error.TestUnexpectedResult,
            };
        },
        .completed => |result| result,
        .quarantined => return error.TestUnexpectedResult,
    };
    try testing.expect(
        adapter.currentAsyncDispatchQuarantine() == null,
    );
    try testing.expectError(
        metal_allocation.Error.DispatchUnresolved,
        adapter.reconcileTerminalCommandFailureObserved(
            lease,
            pin,
            async_ticket,
        ),
    );
    const replayed =
        try adapter.pollMatvecInt4AsyncObserved(
            lease,
            pin,
            async_ticket,
            &gpu_output,
        );
    switch (replayed) {
        .completed => |result| try testing.expectEqualDeep(
            dispatch_result,
            result,
        ),
        .pending, .quarantined => return error.TestUnexpectedResult,
    }
    try metal_allocation
        .validateMetalLeaseTreeDispatchPayloadV1(
        dispatch_result.observation,
        quantized.packed_bytes,
        quantized.scales,
        &input,
        &gpu_output,
    );
    try metal_allocation
        .validateMetalLeaseTreeDispatchObservationForPinV1(
        dispatch_result.observation,
        pin,
        dispatch_result.terminal,
    );
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.cancelMatvecBeforeSubmitObserved(
            lease,
            pin,
        ),
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.rejectMatvecInt4BeforeSubmitObserved(
            lease,
            pin,
            fixture.bindings,
            quantized.packed_bytes,
            quantized.scales,
            &input,
            rejected_output,
            group_size,
            in_features,
            out_features,
        ),
    );
    for (cpu_output.asF32(), gpu_output) |expected, actual|
        try testing.expectApproxEqAbs(expected, actual, 2e-5);

    const completion = try coordinator.completeDispatchPin(
        pin,
        adapter.dispatchInterface(),
        dispatch_result.terminal,
    );
    try testing.expectEqual(
        dispatch_count_before + 1,
        backend.completedDispatchCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expect(
        adapter.currentAsyncDispatchQuarantine() == null,
    );
    try tree_allocation.validateDispatchCompletionForPinV1(
        completion,
        pin,
        dispatch_result.terminal,
    );
    try adapter.acknowledgeDispatchCompletion(completion);
    try testing.expect(
        backend.compatibilityUnresolvedSubmission() == null,
    );
    // An ordinary exact completion is finalized through the normal command
    // path and must not be counted as callback-retirement activity.
    try expectDispatchRetirementTelemetry(
        &backend,
        retirement_telemetry_before,
    );

    var armed_loss_retirement_plan: ?retirement.LossRetirementPlanV1 = null;
    if (comptime include_injected_fault) {
        const lifecycle_snapshot_before_fault =
            try backend.deviceLifecycleSnapshot();
        const fault_request =
            try adapter.prepareMatvecDispatchRequestV1(
                dispatch_attempt,
            );
        var settlement_replay: SettlementReplayDispatchAdapter = .{
            .inner = adapter.dispatchInterface(),
            .bank = &bank,
            .backend = &backend,
        };
        const fault_dispatch_interface =
            settlement_replay.interface();
        const fault_pin = try coordinator.acquireDispatchPin(
            lease,
            fault_dispatch_interface,
            fault_request.request_sha256,
        );
        try tree_allocation.validateDispatchPinV1(fault_pin);
        const fault_bank_permit =
            coordinator_dispatches[0].bank_permit.?;
        settlement_replay.expected_bank_permit =
            fault_bank_permit;
        try bank.validateLeasePin(fault_bank_permit);

        // Two contenders race to arm one context-local next-command plan.
        // The native device monitor must linearize exactly one winner while
        // no global state or environment variable participates.
        var fault_start =
            std.atomic.Value(bool).init(false);
        var left_arm: MetalFaultArmWorker = .{
            .backend = &backend,
            .start = &fault_start,
        };
        var right_arm: MetalFaultArmWorker = .{
            .backend = &backend,
            .start = &fault_start,
        };
        const left_thread = try std.Thread.spawn(
            .{},
            MetalFaultArmWorker.run,
            .{&left_arm},
        );
        const right_thread = std.Thread.spawn(
            .{},
            MetalFaultArmWorker.run,
            .{&right_arm},
        ) catch |err| {
            fault_start.store(true, .release);
            left_thread.join();
            return err;
        };
        fault_start.store(true, .release);
        left_thread.join();
        right_thread.join();
        try testing.expect(
            (left_arm.plan == null) !=
                (right_arm.plan == null),
        );
        const fault_plan = if (left_arm.plan) |value|
            value
        else
            right_arm.plan.?;
        const rejected_arm_error =
            if (left_arm.arm_error) |value|
                value
            else
                right_arm.arm_error.?;
        try testing.expect(
            rejected_arm_error ==
                metal_fault_control.Error.PlanAlreadyArmed,
        );
        try metal_fault_control.validateFaultPlanV1(
            fault_plan,
        );

        var injected_output =
            [_]f32{-1_234.5} ** out_features;
        const injected_output_before = injected_output;
        const fault_ticket =
            try adapter.submitMatvecInt4AsyncObserved(
                lease,
                fault_pin,
                fixture.bindings,
                quantized.packed_bytes,
                quantized.scales,
                &input,
                &injected_output,
                group_size,
                in_features,
                out_features,
            );
        try metal_allocation.validateMetalAsyncDispatchTicketV1(
            fault_ticket,
        );
        try testing.expectEqual(
            @as(u64, 1),
            try backend.nativeLiveCommandCount(),
        );

        const fault_wait =
            try adapter.waitMatvecInt4AsyncObserved(
                lease,
                fault_pin,
                fault_ticket,
                &injected_output,
            );
        const quarantine = switch (fault_wait) {
            .quarantined => |value| value,
            .pending, .completed => return error.TestUnexpectedResult,
        };
        try testing.expectEqualSlices(
            f32,
            &injected_output_before,
            &injected_output,
        );
        try testing.expect(
            quarantine.reason == .terminal_command_error,
        );
        try testing.expect(
            quarantine.native_disposition ==
                .terminal_status_observed,
        );
        try testing.expectEqual(
            @as(u64, 1),
            quarantine.native_completion_observed,
        );
        try testing.expectEqual(
            engine.metal_backend.error_command_buffer_status,
            @as(u32, @intCast(
                quarantine.native_command_status,
            )),
        );
        try testing.expect(
            quarantine.error_domain_kind == .command_buffer,
        );
        try testing.expectEqual(
            @as(u64, @bitCast(
                fault_plan.injected_error_code,
            )),
            quarantine.error_code_bits,
        );

        const completion_facts =
            try metal_fault_control
                .completionFactsForBindingV1(
                &backend,
                fault_ticket.ticket_sha256,
            );
        try testing.expectEqual(
            fault_plan.plan_generation,
            completion_facts.plan_generation,
        );
        try testing.expectEqual(
            fault_plan.injected_error_code,
            completion_facts.injected_error_code,
        );
        try testing.expectEqual(
            lifecycle.command_buffer_device_removed_error,
            @as(u64, @bitCast(
                completion_facts.injected_error_code,
            )),
        );
        try testing.expectEqual(
            @as(u32, 1),
            completion_facts.fault_applied,
        );
        try testing.expect(
            completion_facts.physical.state == .completed,
        );
        try testing.expect(
            completion_facts.published.state == .@"error",
        );
        try testing.expectEqualDeep(
            lifecycle_snapshot_before_fault,
            try backend.deviceLifecycleSnapshot(),
        );
        try testing.expectEqual(
            @as(u64, 1),
            try backend.nativeLiveCommandCount(),
        );
        try testing.expectEqual(
            @as(usize, 1),
            (try coordinator.snapshot()).active_dispatches,
        );
        try testing.expectEqual(
            fixture.manifest.total_charged_bytes,
            (try bank.snapshotV3()).used.device_bytes,
        );
        try testing.expectError(
            tree_allocation.Error.DispatchInFlight,
            coordinator.release(
                lease,
                adapter.interface(),
            ),
        );

        const loss_source_cursor: lifecycle.SourceCursorV1 = .{
            .source_instance_sha256 = digest(
                "fault dispatch loss source instance",
            ),
            .last_sequence = 0,
        };
        const loss_observation = try lifecycle.makeObservationV1(
            inventory_entry,
            &fixture.inventory,
            loss_source_cursor.source_instance_sha256,
            1,
            .test_injected,
            digest("fault dispatch loss evidence"),
            0,
            0,
            0,
        );
        const loss_successor =
            try lifecycle.makeSuccessorEntryV1(
                loss_observation,
                inventory_entry,
                &fixture.inventory,
                loss_source_cursor,
                inventory_entry.discovery_epoch + 1,
            );
        const loss_transition =
            try lifecycle.makeTransitionReceiptV1(
                loss_observation,
                inventory_entry,
                &fixture.inventory,
                loss_successor,
                loss_source_cursor,
            );
        const reconciliation_challenge =
            try adapter
                .lossDispatchReconciliationAdapterChallengeV1(
                &coordinator,
                fault_dispatch_interface,
                loss_observation,
                lease,
                fault_pin,
                fault_ticket,
            );
        const reconciliation_retention =
            try loss_dispatch_reconciliation
                .makeLossDispatchRetentionV1(
                loss_observation.source,
                loss_observation.evidence_class,
                inventory_entry,
                lease,
                fault_pin,
                fault_ticket.submission_sha256,
                quarantine.quarantine_sha256,
                reconciliation_challenge,
            );
        const reconciliation_plan =
            try loss_dispatch_reconciliation
                .makeLossDispatchReconciliationPlanV1(
                loss_observation,
                loss_transition,
                loss_source_cursor,
                fixture.requirement,
                fixture.selection,
                &fixture.inventory,
                inventory_entry,
                loss_successor,
                reconciliation_retention,
                lease,
                fault_pin,
                1,
            );
        try testing.expectError(
            loss_dispatch_reconciliation
                .Error.ProductionEvidenceRequired,
            adapter.armLossDispatchReconciliationV1(
                &coordinator,
                fault_dispatch_interface,
                reconciliation_plan,
                reconciliation_retention,
                loss_observation,
                loss_transition,
                loss_source_cursor,
                fixture.requirement,
                fixture.selection,
                &fixture.inventory,
                inventory_entry,
                loss_successor,
                lease,
                fault_pin,
                fault_ticket,
            ),
        );
        const fault_terminal =
            try adapter
                .armSyntheticLossDispatchReconciliationForTestV1(
                &coordinator,
                fault_dispatch_interface,
                reconciliation_plan,
                reconciliation_retention,
                loss_observation,
                loss_transition,
                loss_source_cursor,
                fixture.requirement,
                fixture.selection,
                &fixture.inventory,
                inventory_entry,
                loss_successor,
                lease,
                fault_pin,
                fault_ticket,
            );
        try testing.expectEqualDeep(
            fault_terminal,
            try adapter
                .armSyntheticLossDispatchReconciliationForTestV1(
                &coordinator,
                fault_dispatch_interface,
                reconciliation_plan,
                reconciliation_retention,
                loss_observation,
                loss_transition,
                loss_source_cursor,
                fixture.requirement,
                fixture.selection,
                &fixture.inventory,
                inventory_entry,
                loss_successor,
                lease,
                fault_pin,
                fault_ticket,
            ),
        );
        try metal_allocation
            .validateMetalAsyncDispatchTerminalFailureV1(
            fault_terminal.failure,
            fault_terminal.terminal,
        );
        try testing.expect(
            fault_terminal.terminal.outcome ==
                .terminal_failure,
        );
        try testing.expect(
            !device.digestEqual(
                fault_terminal.terminal
                    .backend_completion_sha256,
                allocation.zero_digest,
            ),
        );
        try testing.expect(
            device.digestEqual(
                fault_terminal.terminal.output_sha256,
                allocation.zero_digest,
            ),
        );
        try testing.expectEqual(
            @as(u64, 1),
            try backend.nativeLiveCommandCount(),
        );
        try testing.expectEqual(
            @as(usize, 1),
            (try coordinator.snapshot()).active_dispatches,
        );
        try bank.validateLeasePin(fault_bank_permit);
        try testing.expectEqual(
            fixture.manifest.total_charged_bytes,
            (try bank.snapshotV3()).used.device_bytes,
        );
        try testing.expectEqualDeep(
            quarantine,
            adapter.currentAsyncDispatchQuarantine().?,
        );

        // The first confirmation models a lost acknowledgement after the
        // Bank pin was consumed and the exact native record was finalized.
        // The coordinator must retain settlement_pending and replay only the
        // private confirmation callback, never the Bank release.
        try testing.expectError(
            tree_allocation.Error.InvalidDispatchCompletion,
            coordinator.completeDispatchPin(
                fault_pin,
                fault_dispatch_interface,
                fault_terminal.terminal,
            ),
        );
        try testing.expectEqual(
            @as(u64, 1),
            settlement_replay.confirmation_calls,
        );
        try testing.expect(
            settlement_replay
                .bank_consumed_before_native_finalize,
        );
        try testing.expect(
            settlement_replay.native_finalized_before_retry,
        );
        try testing.expectEqual(
            dispatch_count_before + 2,
            backend.completedDispatchCount(),
        );
        try testing.expectEqual(
            @as(u64, 0),
            try backend.nativeLiveCommandCount(),
        );
        try testing.expect(
            backend.compatibilityUnresolvedSubmission() == null,
        );
        try testing.expectEqual(
            @as(usize, 1),
            (try coordinator.snapshot()).active_dispatches,
        );
        try testing.expectError(
            resource.Error.StaleReservation,
            bank.validateLeasePin(fault_bank_permit),
        );
        try testing.expect(
            adapter.currentAsyncDispatchQuarantine() == null,
        );
        try testing.expectError(
            metal_allocation.Error.StaleObject,
            adapter.completeLossDispatchReconciliationV1(
                reconciliation_plan,
                reconciliation_retention,
                .{},
            ),
        );
        try testing.expectError(
            tree_allocation.Error.DispatchInFlight,
            coordinator.release(
                lease,
                adapter.interface(),
            ),
        );

        const fault_completion =
            try coordinator.completeDispatchPin(
                fault_pin,
                fault_dispatch_interface,
                fault_terminal.terminal,
            );
        try tree_allocation.validateDispatchCompletionForPinV1(
            fault_completion,
            fault_pin,
            fault_terminal.terminal,
        );
        try testing.expect(
            fault_completion.outcome == .terminal_failure,
        );
        try testing.expect(
            device.digestEqual(
                fault_completion.output_sha256,
                allocation.zero_digest,
            ),
        );
        try testing.expectEqual(
            @as(u64, 2),
            settlement_replay.confirmation_calls,
        );
        try testing.expectEqual(
            dispatch_count_before + 2,
            backend.completedDispatchCount(),
        );
        try testing.expectEqual(
            @as(u64, 0),
            try backend.nativeLiveCommandCount(),
        );
        try testing.expectEqual(
            @as(usize, 0),
            (try coordinator.snapshot()).active_dispatches,
        );
        try testing.expect(
            adapter.currentAsyncDispatchQuarantine() == null,
        );
        const reconciliation_receipt =
            try adapter.completeLossDispatchReconciliationV1(
                reconciliation_plan,
                reconciliation_retention,
                fault_completion,
            );
        try loss_dispatch_reconciliation
            .validateLossDispatchReconciliationReceiptV1(
            reconciliation_receipt,
            reconciliation_plan,
            reconciliation_retention,
            inventory_entry,
            lease,
            fault_pin,
            fault_terminal.terminal,
            fault_completion,
        );
        try testing.expectEqualDeep(
            reconciliation_receipt,
            try adapter.completeLossDispatchReconciliationV1(
                reconciliation_plan,
                reconciliation_retention,
                fault_completion,
            ),
        );
        try testing.expectEqualDeep(
            reconciliation_receipt,
            (try adapter
                .currentLossDispatchReconciliationReceiptV1(
                reconciliation_plan,
                reconciliation_retention,
                fault_completion,
            )).?,
        );
        try testing.expectError(
            metal_fault_control.Error.FactsUnavailable,
            metal_fault_control
                .completionFactsForBindingV1(
                &backend,
                fault_ticket.ticket_sha256,
            ),
        );
        try adapter.acknowledgeDispatchCompletion(
            fault_completion,
        );
        try adapter.acknowledgeDispatchCompletion(
            fault_completion,
        );
        try testing.expectError(
            metal_allocation.Error.StaleObject,
            adapter.reconcileTerminalCommandFailureObserved(
                lease,
                fault_pin,
                fault_ticket,
            ),
        );
        try testing.expectError(
            metal_allocation.Error.StaleObject,
            adapter.pollMatvecInt4AsyncObserved(
                lease,
                fault_pin,
                fault_ticket,
                &injected_output,
            ),
        );
        try testing.expectError(
            tree_allocation.Error.InvalidDispatchPin,
            coordinator.completeDispatchPin(
                fault_pin,
                fault_dispatch_interface,
                fault_terminal.terminal,
            ),
        );

        const retirement_challenge =
            try adapter.lossRetirementAdapterChallengeV1(
                &coordinator,
                adapter.interface(),
                loss_observation,
                lease,
            );
        const retirement_plan =
            try retirement.makeLossRetirementPlanV1(
                loss_observation,
                loss_transition,
                loss_source_cursor,
                fixture.requirement,
                fixture.selection,
                &fixture.inventory,
                inventory_entry,
                loss_successor,
                adapter.authority,
                lease,
                1,
                retirement_challenge,
            );
        try adapter.armSyntheticLossRetirementForTestV1(
            &coordinator,
            adapter.interface(),
            retirement_plan,
            loss_observation,
            loss_transition,
            loss_source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            loss_successor,
            lease,
        );
        armed_loss_retirement_plan = retirement_plan;
    }

    // The optional command-error reconciliation above is Phase A, not the
    // callback-detached Phase B path, so it is telemetry-neutral as well.
    try expectDispatchRetirementTelemetry(
        &backend,
        retirement_telemetry_before,
    );

    const released = try coordinator.release(
        lease,
        adapter.interface(),
    );
    const terminal = switch (released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try tree_allocation.validateTerminalReceiptV1(terminal);
    try testing.expect(terminal.terminal_tree.current.isZero());
    if (armed_loss_retirement_plan) |plan| {
        const retirement_receipt =
            try adapter.completeLossRetirementV1(
                plan,
                terminal,
            );
        try retirement.validateLossRetirementReceiptV1(
            retirement_receipt,
            plan,
            terminal,
        );
        try testing.expectEqual(
            plan.allocation_count,
            retirement_receipt.reference_release_count,
        );
    }
    try testing.expectEqual(
        @as(u64, 0),
        (try bank.snapshotV3()).used.device_bytes,
    );
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expect(
        backend.compatibilityUnresolvedSubmission() == null,
    );
    try adapter.validateEmpty();

    try bank.closePublicationSession(
        parent,
        302,
        session_id,
        publication_sequence,
    );
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
    try testing.expect((try bank.snapshot()).used.isZero());
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expect(
        backend.compatibilityUnresolvedSubmission() == null,
    );
}

fn runBoundedTwoSlotMetalDispatchProof() !void {
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    const allocator = testing.allocator;
    const group_size: usize = 8;
    const in_features: usize = 64;
    const out_features: usize = 37;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    const backend_cleanup: MetalBackendCleanup = .{
        .backend = &backend,
    };
    defer backend_cleanup.run();
    const retirement_telemetry_before =
        try initialDispatchRetirementTelemetry(&backend);
    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            &backend,
            113,
            0,
            1 * 1024 * 1024,
        );
    var native_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}} ** 8;
    var adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            inventory_entry,
            213,
            0x4d65_7461_6c32_536c,
            &native_slots,
        );
    const fixture = try makeTwoSlotDispatchFixture(
        &adapter,
        inventory_entry,
    );
    try testing.expectEqual(
        @as(u64, 5_544),
        fixture.manifest.total_charged_bytes,
    );
    try testing.expectEqual(
        @as(u64, 2),
        fixture.requirement.queue_slots,
    );

    var bank_slots = [_]resource.Slot{.{}};
    var tree_roots = [_]resource.LeaseTreeRootSlot{.{}};
    var tree_nodes = [_]resource.LeaseNodeSlot{.{}} ** 9;
    var pin_slots = [_]resource.LeasePinSlotV1{.{}} ** 2;
    var bank = try resource.Bank.initWithLeaseTreePinStorage(
        &bank_slots,
        &tree_roots,
        &tree_nodes,
        &pin_slots,
        .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = fixture.manifest.total_charged_bytes,
            .queue_slots = 2,
        },
        413,
    );
    const parent = try bank.commit(
        try bank.reserve(513, .{
            .capsule_bytes = 64,
            .queue_slots = 2,
        }),
    );
    const opened = try bank.openLeaseTree(
        parent,
        0x4d65_7461_6c32_5472,
        0x4d65_7461_6c32_4175,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    const scoped = try bank.openLeaseScope(
        opened,
        0x4d65_7461_6c32_5363,
        0x4d65_7461_6c32_546e,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    var tree = scoped.tree;
    var session_byte: u8 = 0;
    const session_id = @intFromPtr(&session_byte);
    var publication_sequence: u64 = 0;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        303,
        session_id,
    );
    var coordinator_objects =
        [_]tree_allocation.CoordinatorObjectSlotV1{.{}} ** 8;
    var coordinator_dispatches =
        [_]tree_allocation.CoordinatorDispatchSlotV1{.{}} ** 2;
    var coordinator: tree_allocation.CoordinatorV1 = .{};
    try coordinator.initWithDispatchStorage(
        613,
        &bank,
        &tree,
        scoped.scope,
        303,
        session_id,
        &publication_sequence,
        &coordinator_objects,
        &coordinator_dispatches,
    );
    const request = try allocation.makeRequestV1(
        303,
        digest("native Metal bounded two-slot owner"),
        adapter.authority,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const admission = try coordinator.admit(
        adapter.interface(),
        request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const materialized = try coordinator.materialize(
        admission,
        adapter.interface(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(u64, 8), lease.allocation_count);
    try testing.expectEqual(@as(u64, 8), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 8),
        try backend.nativeLiveBufferCount(),
    );

    var rng = std.Random.DefaultPrng.init(0x5457_4f53_4c4f_5453);
    var weights: [in_features * out_features]f32 =
        undefined;
    var input_a: [in_features]f32 = undefined;
    var input_b: [in_features]f32 = undefined;
    for (&weights) |*value|
        value.* =
            (rng.random().float(f32) * 2 - 1) * 0.25;
    for (&input_a) |*value|
        value.* = rng.random().float(f32) * 2 - 1;
    for (&input_b) |*value|
        value.* = rng.random().float(f32) * 2 - 1;
    const quantized = try engine.core.quant.quantize(
        f32,
        allocator,
        &weights,
        .int4,
        group_size,
    );
    defer {
        allocator.free(quantized.packed_bytes);
        allocator.free(quantized.scales);
    }
    var input_tensor_a = try engine.core.tensor.fromF32(
        allocator,
        &.{ 1, in_features },
        &input_a,
    );
    defer input_tensor_a.deinit();
    var input_tensor_b = try engine.core.tensor.fromF32(
        allocator,
        &.{ 1, in_features },
        &input_b,
    );
    defer input_tensor_b.deinit();
    var cpu_output_a = try engine.core.tensor.zerosF32(
        allocator,
        &.{ 1, out_features },
    );
    defer cpu_output_a.deinit();
    var cpu_output_b = try engine.core.tensor.zerosF32(
        allocator,
        &.{ 1, out_features },
    );
    defer cpu_output_b.deinit();
    try engine.int4_matmul.linearInt4OnTheFly(
        input_tensor_a,
        quantized.packed_bytes,
        quantized.scales,
        &.{},
        cpu_output_a,
        out_features,
        in_features,
        group_size,
    );
    try engine.int4_matmul.linearInt4OnTheFly(
        input_tensor_b,
        quantized.packed_bytes,
        quantized.scales,
        &.{},
        cpu_output_b,
        out_features,
        in_features,
        group_size,
    );

    const output_sentinel: f32 = -8_765.25;
    const output_sentinel_values =
        [_]f32{output_sentinel} ** out_features;
    var gpu_output_a = output_sentinel_values;
    var gpu_output_b = output_sentinel_values;
    const dispatch_count_before =
        backend.completedDispatchCount();
    const attempt_a =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings[0],
            @intCast(quantized.packed_bytes.len),
            @intCast(quantized.scales.len),
            @intCast(input_a.len),
            @intCast(gpu_output_a.len),
            group_size,
            in_features,
            out_features,
        );
    const attempt_b =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings[1],
            @intCast(quantized.packed_bytes.len),
            @intCast(quantized.scales.len),
            @intCast(input_b.len),
            @intCast(gpu_output_b.len),
            group_size,
            in_features,
            out_features,
        );

    const request_a =
        try adapter.prepareMatvecDispatchRequestV1(attempt_a);
    const pin_a = try coordinator.acquireDispatchPin(
        lease,
        adapter.dispatchInterface(),
        request_a.request_sha256,
    );
    try tree_allocation.validateDispatchPinV1(pin_a);
    try testing.expectEqual(@as(u64, 8), pin_a.allocation_count);
    const ticket_a =
        try adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin_a,
            fixture.bindings[0],
            quantized.packed_bytes,
            quantized.scales,
            &input_a,
            &gpu_output_a,
            group_size,
            in_features,
            out_features,
        );
    try metal_allocation.validateMetalAsyncDispatchTicketV1(
        ticket_a,
    );
    try testing.expectEqual(@as(u64, 0), ticket_a.queue_slot);

    // B uses a disjoint four-buffer role set and is submitted before A is
    // observed or settled. This proves bounded native ownership only; it does
    // not claim physical parallel execution or a hardware completion order.
    const request_b =
        try adapter.prepareMatvecDispatchRequestV1(attempt_b);
    const pin_b = try coordinator.acquireDispatchPin(
        lease,
        adapter.dispatchInterface(),
        request_b.request_sha256,
    );
    try tree_allocation.validateDispatchPinV1(pin_b);
    try testing.expectEqual(@as(u64, 8), pin_b.allocation_count);
    const bank_permit_a =
        coordinator_dispatches[0].bank_permit.?;
    const bank_permit_b =
        coordinator_dispatches[1].bank_permit.?;
    try testing.expect(
        bank_permit_a.pin_slot_index !=
            bank_permit_b.pin_slot_index,
    );
    try bank.validateLeasePin(bank_permit_a);
    try bank.validateLeasePin(bank_permit_b);
    const ticket_b =
        try adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin_b,
            fixture.bindings[1],
            quantized.packed_bytes,
            quantized.scales,
            &input_b,
            &gpu_output_b,
            group_size,
            in_features,
            out_features,
        );
    try metal_allocation.validateMetalAsyncDispatchTicketV1(
        ticket_b,
    );
    try testing.expectEqual(@as(u64, 1), ticket_b.queue_slot);
    try testing.expect(
        ticket_a.queue_slot != ticket_b.queue_slot,
    );
    try testing.expect(
        ticket_a.ticket_generation !=
            ticket_b.ticket_generation,
    );
    try testing.expectEqual(
        @as(usize, 2),
        activeLeasePinCount(&pin_slots),
    );
    try testing.expectEqual(
        @as(usize, 2),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expectEqual(
        @as(u64, 2),
        try backend.nativeLiveCommandCount(),
    );
    const bank_at_two_pins = try bank.snapshotV4();
    try testing.expectEqual(
        @as(usize, 2),
        bank_at_two_pins.active_lease_pin_slots,
    );
    try testing.expectEqual(
        @as(usize, 2),
        bank_at_two_pins.peak_active_lease_pin_slots,
    );
    try testing.expectEqual(
        @as(u64, 2),
        bank_at_two_pins.lease_pin_acquisitions,
    );
    try testing.expectEqual(
        @as(u64, 0),
        bank_at_two_pins.lease_pin_completions,
    );
    try testing.expectEqual(
        @as(u64, 2),
        bank_at_two_pins.reserved_lease_pin_completion_generations,
    );
    try testing.expectEqual(
        @as(u64, 2),
        bank_at_two_pins.reserved_lease_pin_completion_structural_revisions,
    );

    // Exact submit replay returns the retained ticket and cannot create a
    // third native command record.
    try testing.expectEqualDeep(
        ticket_a,
        try adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin_a,
            fixture.bindings[0],
            quantized.packed_bytes,
            quantized.scales,
            &input_a,
            &gpu_output_a,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectEqualDeep(
        ticket_b,
        try adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin_b,
            fixture.bindings[1],
            quantized.packed_bytes,
            quantized.scales,
            &input_b,
            &gpu_output_b,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectEqual(
        @as(u64, 2),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );

    var third_bindings = fixture.bindings[0];
    third_bindings.output_sha256 = digest(
        "native Metal bounded two-slot third output",
    );
    const third_attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            third_bindings,
            @intCast(quantized.packed_bytes.len),
            @intCast(quantized.scales.len),
            @intCast(input_a.len),
            @intCast(gpu_output_a.len),
            group_size,
            in_features,
            out_features,
        );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.prepareMatvecDispatchRequestV1(
            third_attempt,
        ),
    );
    try testing.expectEqual(
        @as(u64, 2),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );

    const waited_a =
        try adapter.waitMatvecInt4AsyncObserved(
            lease,
            pin_a,
            ticket_a,
            &gpu_output_a,
        );
    const result_a = switch (waited_a) {
        .completed => |value| value,
        .pending, .quarantined => return error.TestUnexpectedResult,
    };
    try metal_allocation
        .validateMetalLeaseTreeDispatchPayloadV1(
        result_a.observation,
        quantized.packed_bytes,
        quantized.scales,
        &input_a,
        &gpu_output_a,
    );
    try metal_allocation
        .validateMetalLeaseTreeDispatchObservationForPinV1(
        result_a.observation,
        pin_a,
        result_a.terminal,
    );
    for (cpu_output_a.asF32(), gpu_output_a) |expected, actual|
        try testing.expectApproxEqAbs(expected, actual, 2e-5);

    const waited_b =
        try adapter.waitMatvecInt4AsyncObserved(
            lease,
            pin_b,
            ticket_b,
            &gpu_output_b,
        );
    const result_b = switch (waited_b) {
        .completed => |value| value,
        .pending, .quarantined => return error.TestUnexpectedResult,
    };
    try metal_allocation
        .validateMetalLeaseTreeDispatchPayloadV1(
        result_b.observation,
        quantized.packed_bytes,
        quantized.scales,
        &input_b,
        &gpu_output_b,
    );
    try metal_allocation
        .validateMetalLeaseTreeDispatchObservationForPinV1(
        result_b.observation,
        pin_b,
        result_b.terminal,
    );
    for (cpu_output_b.asF32(), gpu_output_b) |expected, actual|
        try testing.expectApproxEqAbs(expected, actual, 2e-5);
    try testing.expectEqual(
        @as(u64, 2),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        dispatch_count_before,
        backend.completedDispatchCount(),
    );

    // Both commands are now observed complete, but B settles first. Its exact
    // Bank permit and native record are consumed while A's terminal evidence,
    // command record, full-lease pin, and all eight buffers remain intact.
    const completion_b = try coordinator.completeDispatchPin(
        pin_b,
        adapter.dispatchInterface(),
        result_b.terminal,
    );
    try tree_allocation.validateDispatchCompletionForPinV1(
        completion_b,
        pin_b,
        result_b.terminal,
    );
    try adapter.acknowledgeDispatchCompletion(completion_b);
    try adapter.acknowledgeDispatchCompletion(completion_b);
    try testing.expectEqual(
        dispatch_count_before + 1,
        backend.completedDispatchCount(),
    );
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        @as(usize, 1),
        activeLeasePinCount(&pin_slots),
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try coordinator.snapshot()).active_dispatches,
    );
    const bank_after_b = try bank.snapshotV4();
    try testing.expectEqual(
        @as(usize, 1),
        bank_after_b.active_lease_pin_slots,
    );
    try testing.expectEqual(
        @as(usize, 2),
        bank_after_b.peak_active_lease_pin_slots,
    );
    try testing.expectEqual(
        @as(u64, 2),
        bank_after_b.lease_pin_acquisitions,
    );
    try testing.expectEqual(
        @as(u64, 1),
        bank_after_b.lease_pin_completions,
    );
    try testing.expectEqual(
        @as(u64, 1),
        bank_after_b.reserved_lease_pin_completion_generations,
    );
    try testing.expectEqual(
        @as(u64, 1),
        bank_after_b.reserved_lease_pin_completion_structural_revisions,
    );
    try bank.validateLeasePin(bank_permit_a);
    try testing.expectError(
        resource.Error.StaleReservation,
        bank.validateLeasePin(bank_permit_b),
    );
    try testing.expectEqual(@as(u64, 8), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 8),
        try backend.nativeLiveBufferCount(),
    );
    const completion_a = try coordinator.completeDispatchPin(
        pin_a,
        adapter.dispatchInterface(),
        result_a.terminal,
    );
    try tree_allocation.validateDispatchCompletionForPinV1(
        completion_a,
        pin_a,
        result_a.terminal,
    );
    try adapter.acknowledgeDispatchCompletion(completion_a);
    try adapter.acknowledgeDispatchCompletion(completion_a);
    try testing.expectEqual(
        dispatch_count_before + 2,
        backend.completedDispatchCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        @as(usize, 0),
        activeLeasePinCount(&pin_slots),
    );
    try testing.expectEqual(
        @as(usize, 0),
        (try coordinator.snapshot()).active_dispatches,
    );
    const bank_after_a = try bank.snapshotV4();
    try testing.expectEqual(
        @as(usize, 0),
        bank_after_a.active_lease_pin_slots,
    );
    try testing.expectEqual(
        @as(usize, 2),
        bank_after_a.peak_active_lease_pin_slots,
    );
    try testing.expectEqual(
        @as(u64, 2),
        bank_after_a.lease_pin_acquisitions,
    );
    try testing.expectEqual(
        @as(u64, 2),
        bank_after_a.lease_pin_completions,
    );
    try testing.expectEqual(
        @as(u64, 0),
        bank_after_a.reserved_lease_pin_completion_generations,
    );
    try testing.expectEqual(
        @as(u64, 0),
        bank_after_a.reserved_lease_pin_completion_structural_revisions,
    );
    try testing.expectError(
        resource.Error.StaleReservation,
        bank.validateLeasePin(bank_permit_a),
    );
    try testing.expectError(
        resource.Error.StaleReservation,
        bank.validateLeasePin(bank_permit_b),
    );

    // Reuse both logical adapter slots under the same eight-buffer lease.
    // Tombstones from round one remain available for exact acknowledgement,
    // but they are not live slot ownership. The new request, coordinator-pin,
    // and adapter-ticket generations fence each reused slot. These are
    // runtime ownership facts only and make no claim about physical GPU
    // concurrency.
    gpu_output_a = output_sentinel_values;
    gpu_output_b = output_sentinel_values;
    const request_a_round_two =
        try adapter.prepareMatvecDispatchRequestV1(attempt_a);
    try testing.expect(
        request_a_round_two.request_generation >
            request_b.request_generation,
    );
    const pin_a_round_two = try coordinator.acquireDispatchPin(
        lease,
        adapter.dispatchInterface(),
        request_a_round_two.request_sha256,
    );
    try tree_allocation.validateDispatchPinV1(pin_a_round_two);
    try testing.expect(
        pin_a_round_two.dispatch_generation >
            pin_b.dispatch_generation,
    );
    const ticket_a_round_two =
        try adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin_a_round_two,
            fixture.bindings[0],
            quantized.packed_bytes,
            quantized.scales,
            &input_a,
            &gpu_output_a,
            group_size,
            in_features,
            out_features,
        );
    try metal_allocation.validateMetalAsyncDispatchTicketV1(
        ticket_a_round_two,
    );
    try testing.expectEqual(
        ticket_a.queue_slot,
        ticket_a_round_two.queue_slot,
    );
    try testing.expectEqual(
        @as(u64, 0),
        ticket_a_round_two.queue_slot,
    );
    try testing.expect(
        ticket_a_round_two.ticket_generation >
            ticket_b.ticket_generation,
    );
    try testing.expect(
        ticket_a_round_two.dispatch_generation >
            ticket_b.dispatch_generation,
    );

    const request_b_round_two =
        try adapter.prepareMatvecDispatchRequestV1(attempt_b);
    try testing.expect(
        request_b_round_two.request_generation >
            request_a_round_two.request_generation,
    );
    const pin_b_round_two = try coordinator.acquireDispatchPin(
        lease,
        adapter.dispatchInterface(),
        request_b_round_two.request_sha256,
    );
    try tree_allocation.validateDispatchPinV1(pin_b_round_two);
    try testing.expect(
        pin_b_round_two.dispatch_generation >
            pin_a_round_two.dispatch_generation,
    );
    const ticket_b_round_two =
        try adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin_b_round_two,
            fixture.bindings[1],
            quantized.packed_bytes,
            quantized.scales,
            &input_b,
            &gpu_output_b,
            group_size,
            in_features,
            out_features,
        );
    try metal_allocation.validateMetalAsyncDispatchTicketV1(
        ticket_b_round_two,
    );
    try testing.expectEqual(
        ticket_b.queue_slot,
        ticket_b_round_two.queue_slot,
    );
    try testing.expectEqual(
        @as(u64, 1),
        ticket_b_round_two.queue_slot,
    );
    try testing.expect(
        ticket_b_round_two.ticket_generation >
            ticket_a_round_two.ticket_generation,
    );
    try testing.expect(
        ticket_b_round_two.dispatch_generation >
            ticket_a_round_two.dispatch_generation,
    );
    try testing.expectEqualDeep(
        ticket_a_round_two,
        adapter.currentAsyncDispatchTicketForQueueSlotV1(0).?,
    );
    try testing.expectEqualDeep(
        ticket_b_round_two,
        adapter.currentAsyncDispatchTicketForQueueSlotV1(1).?,
    );
    try testing.expectEqual(
        @as(u64, 2),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        @as(usize, 2),
        activeLeasePinCount(&pin_slots),
    );
    try testing.expectEqual(
        @as(usize, 2),
        (try coordinator.snapshot()).active_dispatches,
    );
    const bank_round_two_active = try bank.snapshotV4();
    try testing.expectEqual(
        @as(usize, 2),
        bank_round_two_active.active_lease_pin_slots,
    );
    try testing.expectEqual(
        @as(u64, 4),
        bank_round_two_active.lease_pin_acquisitions,
    );
    try testing.expectEqual(
        @as(u64, 2),
        bank_round_two_active.lease_pin_completions,
    );

    // A ticket retained from round one cannot observe or submit against the
    // newer dispatch generation occupying the same logical slot. Rejection
    // occurs before output publication or native command creation.
    var stale_output_a = output_sentinel_values;
    var stale_output_b = output_sentinel_values;
    try testing.expectError(
        metal_allocation.Error.InvalidDispatchEvidence,
        adapter.pollMatvecInt4AsyncObserved(
            lease,
            pin_a,
            ticket_a,
            &stale_output_a,
        ),
    );
    try testing.expectError(
        metal_allocation.Error.InvalidDispatchEvidence,
        adapter.pollMatvecInt4AsyncObserved(
            lease,
            pin_b,
            ticket_b,
            &stale_output_b,
        ),
    );
    try testing.expectEqualSlices(
        f32,
        output_sentinel_values[0..],
        stale_output_a[0..],
    );
    try testing.expectEqualSlices(
        f32,
        output_sentinel_values[0..],
        stale_output_b[0..],
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin_a,
            fixture.bindings[0],
            quantized.packed_bytes,
            quantized.scales,
            &input_a,
            &gpu_output_a,
            group_size,
            in_features,
            out_features,
        ),
    );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter.submitMatvecInt4AsyncObserved(
            lease,
            pin_b,
            fixture.bindings[1],
            quantized.packed_bytes,
            quantized.scales,
            &input_b,
            &gpu_output_b,
            group_size,
            in_features,
            out_features,
        ),
    );

    // Exact completion acknowledgement from round one remains an idempotent
    // tombstone lookup. It cannot finalize either new native command or
    // consume either new Bank pin.
    try adapter.acknowledgeDispatchCompletion(completion_a);
    try adapter.acknowledgeDispatchCompletion(completion_b);
    try testing.expectEqualDeep(
        ticket_a_round_two,
        adapter.currentAsyncDispatchTicketForQueueSlotV1(0).?,
    );
    try testing.expectEqualDeep(
        ticket_b_round_two,
        adapter.currentAsyncDispatchTicketForQueueSlotV1(1).?,
    );
    try testing.expectEqual(
        @as(u64, 2),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        dispatch_count_before + 2,
        backend.completedDispatchCount(),
    );
    try testing.expectEqual(
        @as(usize, 2),
        activeLeasePinCount(&pin_slots),
    );
    try testing.expectEqual(
        @as(usize, 2),
        (try coordinator.snapshot()).active_dispatches,
    );

    const waited_a_round_two =
        try adapter.waitMatvecInt4AsyncObserved(
            lease,
            pin_a_round_two,
            ticket_a_round_two,
            &gpu_output_a,
        );
    const result_a_round_two = switch (waited_a_round_two) {
        .completed => |value| value,
        .pending, .quarantined => return error.TestUnexpectedResult,
    };
    try metal_allocation
        .validateMetalLeaseTreeDispatchPayloadV1(
        result_a_round_two.observation,
        quantized.packed_bytes,
        quantized.scales,
        &input_a,
        &gpu_output_a,
    );
    try metal_allocation
        .validateMetalLeaseTreeDispatchObservationForPinV1(
        result_a_round_two.observation,
        pin_a_round_two,
        result_a_round_two.terminal,
    );
    for (cpu_output_a.asF32(), gpu_output_a) |expected, actual|
        try testing.expectApproxEqAbs(expected, actual, 2e-5);

    const waited_b_round_two =
        try adapter.waitMatvecInt4AsyncObserved(
            lease,
            pin_b_round_two,
            ticket_b_round_two,
            &gpu_output_b,
        );
    const result_b_round_two = switch (waited_b_round_two) {
        .completed => |value| value,
        .pending, .quarantined => return error.TestUnexpectedResult,
    };
    try metal_allocation
        .validateMetalLeaseTreeDispatchPayloadV1(
        result_b_round_two.observation,
        quantized.packed_bytes,
        quantized.scales,
        &input_b,
        &gpu_output_b,
    );
    try metal_allocation
        .validateMetalLeaseTreeDispatchObservationForPinV1(
        result_b_round_two.observation,
        pin_b_round_two,
        result_b_round_two.terminal,
    );
    for (cpu_output_b.asF32(), gpu_output_b) |expected, actual|
        try testing.expectApproxEqAbs(expected, actual, 2e-5);
    try testing.expectEqual(
        @as(u64, 2),
        try backend.nativeLiveCommandCount(),
    );

    const completion_a_round_two =
        try coordinator.completeDispatchPin(
            pin_a_round_two,
            adapter.dispatchInterface(),
            result_a_round_two.terminal,
        );
    try tree_allocation.validateDispatchCompletionForPinV1(
        completion_a_round_two,
        pin_a_round_two,
        result_a_round_two.terminal,
    );
    try adapter.acknowledgeDispatchCompletion(
        completion_a_round_two,
    );
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        @as(usize, 1),
        activeLeasePinCount(&pin_slots),
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try coordinator.snapshot()).active_dispatches,
    );

    const completion_b_round_two =
        try coordinator.completeDispatchPin(
            pin_b_round_two,
            adapter.dispatchInterface(),
            result_b_round_two.terminal,
        );
    try tree_allocation.validateDispatchCompletionForPinV1(
        completion_b_round_two,
        pin_b_round_two,
        result_b_round_two.terminal,
    );
    try adapter.acknowledgeDispatchCompletion(
        completion_b_round_two,
    );
    try testing.expectEqual(
        dispatch_count_before + 4,
        backend.completedDispatchCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        @as(usize, 0),
        activeLeasePinCount(&pin_slots),
    );
    try testing.expectEqual(
        @as(usize, 0),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expect(
        adapter.currentAsyncDispatchTicketForQueueSlotV1(0) == null,
    );
    try testing.expect(
        adapter.currentAsyncDispatchTicketForQueueSlotV1(1) == null,
    );
    const bank_round_two_settled = try bank.snapshotV4();
    try testing.expectEqual(
        @as(usize, 0),
        bank_round_two_settled.active_lease_pin_slots,
    );
    try testing.expectEqual(
        @as(usize, 2),
        bank_round_two_settled.peak_active_lease_pin_slots,
    );
    try testing.expectEqual(
        @as(u64, 4),
        bank_round_two_settled.lease_pin_acquisitions,
    );
    try testing.expectEqual(
        @as(u64, 4),
        bank_round_two_settled.lease_pin_completions,
    );
    try testing.expectEqual(
        @as(u64, 0),
        bank_round_two_settled
            .reserved_lease_pin_completion_generations,
    );
    try testing.expectEqual(
        @as(u64, 0),
        bank_round_two_settled
            .reserved_lease_pin_completion_structural_revisions,
    );
    try testing.expectEqual(@as(u64, 8), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 8),
        try backend.nativeLiveBufferCount(),
    );

    const released = try coordinator.release(
        lease,
        adapter.interface(),
    );
    const terminal = switch (released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try tree_allocation.validateTerminalReceiptV1(terminal);
    try testing.expect(terminal.terminal_tree.current.isZero());
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try adapter.validateEmpty();
    try expectDispatchRetirementTelemetry(
        &backend,
        retirement_telemetry_before,
    );

    try bank.closePublicationSession(
        parent,
        303,
        session_id,
        publication_sequence,
    );
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
    try testing.expect((try bank.snapshotV3()).used.isZero());
    try testing.expectEqual(
        @as(usize, 0),
        activeLeasePinCount(&pin_slots),
    );
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expect(
        backend.compatibilityUnresolvedSubmission() == null,
    );
}

test "real Metal dispatch pins exact LeaseTree buffers until completion" {
    try runRealMetalDispatchLifecycle(false);
}

test "bounded two-slot Metal dispatch settles out of order and reuses generation-fenced slots" {
    try runBoundedTwoSlotMetalDispatchProof();
}

test "fault-injected Metal terminal error settles after physical success" {
    if (comptime !metal_fault_control.enabled)
        return error.SkipZigTest;
    try runRealMetalDispatchLifecycle(true);
}

test "held Metal callback permits retirement and wait releases allocation mutex" {
    if (comptime !metal_fault_control.enabled)
        return error.SkipZigTest;
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    defer backend.deinit();
    var expected_retirement_telemetry =
        try initialDispatchRetirementTelemetry(&backend);

    // First wave: keep the completion handler before its callback gate while
    // waitRegisteredDispatch blocks on native publication. The waiter must
    // finish even while this thread owns the backend allocation mutex.
    const wait_tokens =
        try createHeldCallbackMatvecTokens(&backend);
    try metal_fault_control.armNextCompletionCallbackHold(
        &backend,
    );
    var wait_hold_active = true;
    defer if (wait_hold_active)
        metal_fault_control.releaseHeldCompletionCallback(
            &backend,
        ) catch {};
    const wait_binding = digest(
        "held callback allocation mutex wait binding",
    );
    const wait_submission = try submitHeldCallbackMatvec(
        &backend,
        wait_tokens,
        wait_binding,
    );
    try testing.expect(
        wait_submission.disposition == .submitted,
    );
    try metal_fault_control.waitForHeldCompletionCallback(
        &backend,
    );

    backend.allocation_mutex.lock();
    var allocation_mutex_locked = true;
    defer if (allocation_mutex_locked)
        backend.allocation_mutex.unlock();
    var wait_started = std.atomic.Value(bool).init(false);
    var wait_finished = std.atomic.Value(bool).init(false);
    var wait_worker: MetalRegisteredWaitWorker = .{
        .backend = &backend,
        .submission = wait_submission,
        .started = &wait_started,
        .finished = &wait_finished,
    };
    const wait_thread = try std.Thread.spawn(
        .{},
        MetalRegisteredWaitWorker.run,
        .{&wait_worker},
    );
    while (!wait_started.load(.acquire))
        std.atomic.spinLoopHint();
    try metal_fault_control.releaseHeldCompletionCallback(
        &backend,
    );
    wait_hold_active = false;

    var wait_timer = try std.time.Timer.start();
    while (!wait_finished.load(.acquire) and
        wait_timer.read() < 5 * std.time.ns_per_s)
        std.Thread.yield() catch {};
    const wait_finished_while_allocation_locked =
        wait_finished.load(.acquire);
    backend.allocation_mutex.unlock();
    allocation_mutex_locked = false;
    wait_thread.join();
    if (wait_worker.wait_error) |err| return err;
    const wait_completion =
        wait_worker.completion orelse
        return error.TestUnexpectedResult;
    try backend.finalizeRegisteredDispatch(
        wait_submission,
        wait_completion,
    );
    try destroyHeldCallbackMatvecTokens(
        &backend,
        wait_tokens,
    );
    try testing.expect(
        wait_finished_while_allocation_locked,
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    const completed_dispatches_before_retirement =
        backend.completedDispatchCount();

    // Second wave: physical completion reaches the deliberately held block,
    // but no callback projection exists yet. Prepare must freeze pending,
    // detach the gate, and preserve all native ownership until exact commit.
    const retirement_tokens =
        try createHeldCallbackMatvecTokens(&backend);
    try metal_fault_control.armNextCompletionCallbackHold(
        &backend,
    );
    var retirement_hold_active = true;
    defer if (retirement_hold_active)
        metal_fault_control.releaseHeldCompletionCallback(
            &backend,
        ) catch {};
    const retirement_binding = digest(
        "held callback exact retirement binding",
    );
    const retirement_submission =
        try submitHeldCallbackMatvec(
            &backend,
            retirement_tokens,
            retirement_binding,
        );
    try metal_fault_control.waitForHeldCompletionCallback(
        &backend,
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    const permit =
        try backend
            .prepareRegisteredDispatchRetirementForSyntheticLossTest(
            retirement_submission,
        );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.prepared_retirement_count += 1;
    expected_retirement_telemetry.live_prepared_retirement_count += 1;
    expected_retirement_telemetry.callback_detached_count += 1;
    expected_retirement_telemetry.completion_unobserved_prepare_count += 1;
    expected_retirement_telemetry.pending_prepare_count += 1;
    expected_retirement_telemetry.submitted_prepare_count += 1;
    expected_retirement_telemetry.synthetic_test_prepare_count += 1;
    expected_retirement_telemetry
        .highest_prepared_retirement_generation =
        permit.retirement_generation;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expect(
        permit.authorization_kind == .synthetic_test,
    );
    try testing.expectEqual(@as(u32, 0), permit.completion_observed);
    try testing.expect(permit.native_state == .pending);
    try testing.expectEqual(@as(i64, 0), permit.error_code);
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    // The exact live-record prepare is an ownership-neutral native replay.
    try testing.expectEqualDeep(
        permit,
        try metal_fault_control
            .prepareRegisteredDispatchRetirementForTest(
            &backend,
            retirement_submission,
        ),
    );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.prepare_replay_count += 1;
    expected_retirement_telemetry
        .prepare_live_record_replay_count += 1;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectError(
        engine.metal_backend.MetalError.InvalidObservation,
        backend.destroyBufferAllocation(retirement_tokens[0]),
    );

    try metal_fault_control
        .armNextDispatchRetirementCommitFailure(
        &backend,
    );
    try testing.expectError(
        engine.metal_backend.MetalError.InvalidObservation,
        backend.commitRegisteredDispatchRetirement(permit),
    );
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqualDeep(
        metal_fault_control.RetirementCommitFactsV1{
            .abi_version = metal_fault_control.retirement_commit_facts_abi,
            .commit_attempt_count = 1,
            .injected_failure_count = 1,
        },
        try metal_fault_control.dispatchRetirementCommitFacts(
            &backend,
        ),
    );
    // The injected final-boundary failure retains the same prepared record and
    // is deliberately absent from successful-operation telemetry.
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    const retirement_receipt =
        try backend.commitRegisteredDispatchRetirement(permit);
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.committed_retirement_count += 1;
    expected_retirement_telemetry.live_prepared_retirement_count -= 1;
    expected_retirement_telemetry.retired_native_command_count += 1;
    expected_retirement_telemetry
        .released_allocation_reference_count += 4;
    expected_retirement_telemetry.retained_tombstone_count += 1;
    expected_retirement_telemetry
        .highest_committed_retirement_generation =
        permit.retirement_generation;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    const replayed_retirement_receipt =
        try backend.commitRegisteredDispatchRetirement(permit);
    try testing.expectEqualDeep(
        retirement_receipt,
        replayed_retirement_receipt,
    );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.commit_replay_count += 1;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    // Preparing the same exact tombstoned command replays its frozen permit;
    // it cannot detach again or recreate live native ownership.
    try testing.expectEqualDeep(
        permit,
        try metal_fault_control
            .prepareRegisteredDispatchRetirementForTest(
            &backend,
            retirement_submission,
        ),
    );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.prepare_replay_count += 1;
    expected_retirement_telemetry
        .prepare_tombstone_replay_count += 1;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqualDeep(
        metal_fault_control.RetirementCommitFactsV1{
            .abi_version = metal_fault_control.retirement_commit_facts_abi,
            .commit_attempt_count = 3,
            .injected_failure_count = 1,
            .committed_retirement_count = 1,
            .replay_count = 1,
        },
        try metal_fault_control.dispatchRetirementCommitFacts(
            &backend,
        ),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try destroyHeldCallbackMatvecTokens(
        &backend,
        retirement_tokens,
    );
    try testing.expectEqual(@as(u64, 0), backend.liveBufferCount());
    try metal_fault_control.releaseHeldCompletionCallback(
        &backend,
    );
    retirement_hold_active = false;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    const recovery_token =
        try backend.createBufferAllocation(64);
    try backend.destroyBufferAllocation(recovery_token);
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
}

const PhaseBRetainedStateCase = enum {
    submission_ambiguous,
    completion_unknown,
    invalid_completion,
};

fn runPhaseBRetainedStateE2E(
    retained_case: PhaseBRetainedStateCase,
) !void {
    if (comptime !metal_fault_control.enabled)
        return error.SkipZigTest;
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    defer backend.deinit();
    var expected_retirement_telemetry =
        try initialDispatchRetirementTelemetry(&backend);
    const completed_dispatches_before_retirement =
        backend.completedDispatchCount();
    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            &backend,
            115,
            0,
            1 * 1024 * 1024,
        );
    var native_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}} ** 4;
    var adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            inventory_entry,
            215,
            0x4342_5265_744d_6174,
            &native_slots,
        );
    const fixture = try makeDispatchFixture(
        &adapter,
        inventory_entry,
    );

    var bank_slots = [_]resource.Slot{.{}};
    var tree_roots = [_]resource.LeaseTreeRootSlot{.{}};
    var tree_nodes = [_]resource.LeaseNodeSlot{.{}} ** 5;
    var pin_slots = [_]resource.LeasePinSlotV1{.{}};
    var bank = try resource.Bank.initWithLeaseTreePinStorage(
        &bank_slots,
        &tree_roots,
        &tree_nodes,
        &pin_slots,
        .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = fixture.manifest.total_charged_bytes,
            .queue_slots = 1,
        },
        415,
    );
    const parent = try bank.commit(
        try bank.reserve(515, .{
            .capsule_bytes = 64,
            .queue_slots = 1,
        }),
    );
    const opened = try bank.openLeaseTree(
        parent,
        0x4342_5265_744d_3254,
        0x4342_5265_744d_7574,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    const scoped = try bank.openLeaseScope(
        opened,
        0x4342_5265_744d_636f,
        0x4342_5265_744d_656e,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    var tree = scoped.tree;
    var session_byte: u8 = 0;
    const session_id = @intFromPtr(&session_byte);
    var publication_sequence: u64 = 0;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        305,
        session_id,
    );
    var coordinator_objects =
        [_]tree_allocation.CoordinatorObjectSlotV1{.{}} ** 4;
    var coordinator_dispatches =
        [_]tree_allocation.CoordinatorDispatchSlotV1{.{}};
    var coordinator: tree_allocation.CoordinatorV1 = .{};
    try coordinator.initWithDispatchStorage(
        615,
        &bank,
        &tree,
        scoped.scope,
        305,
        session_id,
        &publication_sequence,
        &coordinator_objects,
        &coordinator_dispatches,
    );
    const request = try allocation.makeRequestV1(
        305,
        digest("callback retirement retained-state matrix owner"),
        adapter.authority,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const admission = try coordinator.admit(
        adapter.interface(),
        request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const materialized = try coordinator.materialize(
        admission,
        adapter.interface(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(
        @as(u64, 4),
        backend.liveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 4),
        try backend.nativeLiveBufferCount(),
    );

    const packed_values =
        [_]u8{0} ** held_callback_packed_bytes;
    const scales =
        [_]f32{1.0} ** held_callback_scale_count;
    const input =
        [_]f32{0.25} ** held_callback_in_features;
    var output =
        [_]f32{-654.75} ** held_callback_out_features;
    const output_before = output;
    const attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings,
            packed_values.len,
            scales.len,
            input.len,
            output.len,
            held_callback_group_size,
            held_callback_in_features,
            held_callback_out_features,
        );
    const dispatch_request =
        try adapter.prepareMatvecDispatchRequestV1(attempt);
    var settlement_replay: SettlementReplayDispatchAdapter = .{
        .inner = adapter.dispatchInterface(),
        .bank = &bank,
        .backend = &backend,
    };
    const dispatch_interface = settlement_replay.interface();
    const pin = try coordinator.acquireDispatchPin(
        lease,
        dispatch_interface,
        dispatch_request.request_sha256,
    );
    try tree_allocation.validateDispatchPinV1(pin);
    const bank_permit =
        coordinator_dispatches[0].bank_permit.?;
    settlement_replay.expected_bank_permit = bank_permit;
    try bank.validateLeasePin(bank_permit);

    var callback_hold_active = false;
    defer if (callback_hold_active)
        metal_fault_control.releaseHeldCompletionCallback(
            &backend,
        ) catch {};
    const fault_plan = switch (retained_case) {
        .submission_ambiguous => blk: {
            try metal_fault_control.armNextCompletionCallbackHold(
                &backend,
            );
            callback_hold_active = true;
            break :blk try metal_fault_control
                .armNextRealCommitAsAmbiguousV1(
                &backend,
            );
        },
        .completion_unknown => try metal_fault_control
            .armNextCompletedAsUnknownV1(
            &backend,
        ),
        .invalid_completion => try metal_fault_control
            .armNextCompletedOutputReadRejectionV1(
            &backend,
        ),
    };
    try metal_fault_control.validateFaultPlanV1(fault_plan);

    const ticket = try adapter.submitMatvecInt4AsyncObserved(
        lease,
        pin,
        fixture.bindings,
        &packed_values,
        &scales,
        &input,
        &output,
        held_callback_group_size,
        held_callback_in_features,
        held_callback_out_features,
    );
    try metal_allocation.validateMetalAsyncDispatchTicketV1(
        ticket,
    );

    const observed = switch (retained_case) {
        .submission_ambiguous => blk: {
            try metal_fault_control.waitForHeldCompletionCallback(
                &backend,
            );
            break :blk try adapter.pollMatvecInt4AsyncObserved(
                lease,
                pin,
                ticket,
                &output,
            );
        },
        .completion_unknown, .invalid_completion => try adapter.waitMatvecInt4AsyncObserved(
            lease,
            pin,
            ticket,
            &output,
        ),
    };
    const quarantine = switch (observed) {
        .quarantined => |value| value,
        .pending, .completed => return error.TestUnexpectedResult,
    };
    try testing.expectEqualDeep(
        quarantine,
        adapter.currentAsyncDispatchQuarantine().?,
    );
    try testing.expectEqualSlices(
        f32,
        &output_before,
        &output,
    );
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    try bank.validateLeasePin(bank_permit);
    // Submission/completion classification retains native ownership but is not
    // itself retirement activity.
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    const expected_reason: metal_allocation
        .MetalAsyncDispatchQuarantineReasonV1 =
        switch (retained_case) {
            .submission_ambiguous => .submission_ambiguous,
            .completion_unknown => .completion_unknown,
            .invalid_completion => .invalid_completion,
        };
    const expected_adapter_disposition: metal_allocation
        .MetalAsyncNativeDispositionV1 =
        switch (retained_case) {
            .submission_ambiguous => .commit_started,
            .completion_unknown => .submitted,
            .invalid_completion => .terminal_status_observed,
        };
    const expected_status: u64 = switch (retained_case) {
        .submission_ambiguous => metal_allocation.async_native_command_status_unobserved,
        .completion_unknown, .invalid_completion => metal_allocation.async_native_command_status_completed,
    };
    const expected_completion_observed: u64 =
        switch (retained_case) {
            .submission_ambiguous => 0,
            .completion_unknown, .invalid_completion => 1,
        };
    const expected_adapter_error_domain: metal_allocation
        .MetalAsyncErrorDomainKindV1 =
        switch (retained_case) {
            .submission_ambiguous, .completion_unknown => .native_bridge,
            .invalid_completion => .completion_validation,
        };
    const expected_error_code: u64 = switch (retained_case) {
        .submission_ambiguous => metal_allocation.async_submission_ambiguous_adapter_code,
        .completion_unknown => 3,
        .invalid_completion => 6,
    };
    try testing.expect(
        quarantine.reason == expected_reason,
    );
    try testing.expect(
        quarantine.native_disposition ==
            expected_adapter_disposition,
    );
    try testing.expectEqual(
        expected_status,
        quarantine.native_command_status,
    );
    try testing.expectEqual(
        expected_completion_observed,
        quarantine.native_completion_observed,
    );
    try testing.expect(
        quarantine.error_domain_kind ==
            expected_adapter_error_domain,
    );
    try testing.expectEqual(
        expected_error_code,
        quarantine.error_code_bits,
    );
    try testing.expect(
        !device.digestEqual(
            quarantine.quarantine_sha256,
            allocation.zero_digest,
        ),
    );

    const fault_facts =
        try metal_fault_control.completionFactsForBindingV2(
            &backend,
            ticket.ticket_sha256,
        );
    try testing.expectEqual(
        fault_plan.plan_generation,
        fault_facts.plan_generation,
    );
    try testing.expectEqual(
        fault_plan.kind,
        fault_facts.kind,
    );
    try testing.expectEqual(
        @as(u32, 1),
        fault_facts.fault_applied,
    );
    try testing.expectEqual(
        @as(u32, 1),
        fault_facts.commit_returned_normally,
    );
    try testing.expectEqual(
        @as(u32, 0),
        fault_facts.commit_exception_observed,
    );
    try testing.expect(
        fault_facts.physical_submission.disposition ==
            .submitted,
    );
    const expected_published_disposition: engine.metal_backend.MetalAsyncSubmissionDisposition =
        if (retained_case == .submission_ambiguous)
            .submitted_or_ambiguous
        else
            .submitted;
    try testing.expect(
        fault_facts.published_submission.disposition ==
            expected_published_disposition,
    );
    try testing.expectEqual(
        @as(u32, if (retained_case ==
            .submission_ambiguous) 1 else 0),
        fault_facts.submission_overlay_applied,
    );
    switch (retained_case) {
        .submission_ambiguous => {
            try testing.expectEqual(
                @as(u32, 0),
                fault_facts.callback_snapshot_observed,
            );
            try testing.expectEqual(
                @as(u32, 0),
                fault_facts.completion_overlay_applied,
            );
            try testing.expectEqual(
                @as(u32, 0),
                fault_facts.output_read_rejection_applied,
            );
            try testing.expect(std.mem.allEqual(
                u8,
                std.mem.asBytes(&fault_facts.physical),
                0,
            ));
            try testing.expect(std.mem.allEqual(
                u8,
                std.mem.asBytes(&fault_facts.published),
                0,
            ));
        },
        .completion_unknown => {
            try testing.expectEqual(
                @as(u32, 1),
                fault_facts.callback_snapshot_observed,
            );
            try testing.expectEqual(
                @as(u32, 1),
                fault_facts.completion_overlay_applied,
            );
            try testing.expectEqual(
                @as(u32, 0),
                fault_facts.output_read_rejection_applied,
            );
            try testing.expect(
                fault_facts.physical.state == .completed,
            );
            try testing.expectEqual(
                engine.metal_backend.completed_command_buffer_status,
                fault_facts.physical.command_status,
            );
            try testing.expectEqual(
                @as(u32, 0),
                fault_facts.physical.callback_fault,
            );
            try testing.expect(
                fault_facts.published.state == .unknown,
            );
            try testing.expectEqual(
                engine.metal_backend.completed_command_buffer_status,
                fault_facts.published.command_status,
            );
            try testing.expectEqual(
                @as(u32, 1),
                fault_facts.published.callback_fault,
            );
        },
        .invalid_completion => {
            try testing.expectEqual(
                @as(u32, 1),
                fault_facts.callback_snapshot_observed,
            );
            try testing.expectEqual(
                @as(u32, 0),
                fault_facts.completion_overlay_applied,
            );
            try testing.expectEqual(
                @as(u32, 1),
                fault_facts.output_read_rejection_applied,
            );
            try testing.expectEqual(
                @as(u64, 1),
                fault_facts.output_read_rejection_count,
            );
            try testing.expectEqualDeep(
                fault_facts.physical,
                fault_facts.published,
            );
            try testing.expect(
                fault_facts.physical.state == .completed,
            );
            try testing.expectEqual(
                @as(u32, 0),
                fault_facts.physical.callback_fault,
            );
        },
    }
    if (retained_case == .submission_ambiguous) {
        // The token and binding are exact, but the caller-visible physical
        // copy has the wrong disposition. Native registry state must reject
        // it without detaching the callback or weakening the later adapter
        // retirement authority.
        try testing.expectError(
            metal_fault_control.Error.RetirementUnavailable,
            metal_fault_control
                .prepareRegisteredDispatchRetirementForTest(
                &backend,
                fault_facts.physical_submission,
            ),
        );
        try testing.expectEqual(
            @as(u64, 1),
            try backend.nativeLiveCommandCount(),
        );
        try expectDispatchRetirementTelemetry(
            &backend,
            expected_retirement_telemetry,
        );
    }

    const source_cursor: lifecycle.SourceCursorV1 = .{
        .source_instance_sha256 = digest(
            "callback retirement retained-state synthetic source",
        ),
        .last_sequence = 0,
    };
    const observation = try lifecycle.makeObservationV1(
        inventory_entry,
        &fixture.inventory,
        source_cursor.source_instance_sha256,
        1,
        .test_injected,
        digest(
            "callback retirement retained-state synthetic evidence",
        ),
        0,
        0,
        0,
    );
    const successor_entry = try lifecycle.makeSuccessorEntryV1(
        observation,
        inventory_entry,
        &fixture.inventory,
        source_cursor,
        inventory_entry.discovery_epoch + 1,
    );
    const transition = try lifecycle.makeTransitionReceiptV1(
        observation,
        inventory_entry,
        &fixture.inventory,
        successor_entry,
        source_cursor,
    );
    const adapter_challenge =
        try adapter
            .lossDispatchCallbackRetirementAdapterChallengeV1(
            &coordinator,
            dispatch_interface,
            observation,
            lease,
            pin,
            ticket,
        );
    const expected_retained_state: loss_dispatch_callback_retirement
        .LossDispatchCallbackRetainedStateV1 =
        switch (retained_case) {
            .submission_ambiguous => .submission_ambiguous,
            .completion_unknown => .completion_unknown,
            .invalid_completion => .invalid_completion,
        };
    const expected_retained_disposition: loss_dispatch_callback_retirement
        .LossDispatchCallbackNativeDispositionV1 =
        switch (retained_case) {
            .submission_ambiguous => .commit_started,
            .completion_unknown => .submitted,
            .invalid_completion => .terminal_status_observed,
        };
    const expected_retained_error_domain: loss_dispatch_callback_retirement
        .LossDispatchCallbackErrorDomainKindV1 =
        switch (retained_case) {
            .submission_ambiguous, .completion_unknown => .native_bridge,
            .invalid_completion => .completion_validation,
        };
    const retention =
        try loss_dispatch_callback_retirement
            .makeLossDispatchCallbackRetentionV1(
            expected_retained_state,
            expected_retained_disposition,
            expected_status,
            expected_completion_observed,
            expected_retained_error_domain,
            expected_error_code,
            inventory_entry,
            lease,
            pin,
            ticket.ticket_sha256,
            ticket.submission_sha256,
            quarantine.quarantine_sha256,
            adapter_challenge,
        );
    const plan =
        try loss_dispatch_callback_retirement
            .makeLossDispatchCallbackRetirementPlanV1(
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            retention,
            lease,
            pin,
            1,
        );
    const retirement_result =
        try adapter
            .armSyntheticLossDispatchCallbackRetirementForTestV1(
            &coordinator,
            dispatch_interface,
            plan,
            retention,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            lease,
            pin,
            ticket,
        );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.prepared_retirement_count += 1;
    expected_retirement_telemetry.live_prepared_retirement_count += 1;
    expected_retirement_telemetry.callback_detached_count += 1;
    expected_retirement_telemetry.synthetic_test_prepare_count += 1;
    expected_retirement_telemetry
        .highest_prepared_retirement_generation =
        retirement_result.fence.native_retirement_generation;
    switch (retained_case) {
        .submission_ambiguous => {
            expected_retirement_telemetry
                .completion_unobserved_prepare_count += 1;
            expected_retirement_telemetry.pending_prepare_count += 1;
            expected_retirement_telemetry
                .submitted_or_ambiguous_prepare_count += 1;
        },
        .completion_unknown => {
            expected_retirement_telemetry
                .completion_observed_prepare_count += 1;
            expected_retirement_telemetry.unknown_prepare_count += 1;
            expected_retirement_telemetry.submitted_prepare_count += 1;
        },
        .invalid_completion => {
            // The adapter classifies the rejected output read as invalid;
            // native telemetry faithfully retains the underlying completed
            // callback snapshot without relabelling that native state.
            expected_retirement_telemetry
                .completion_observed_prepare_count += 1;
            expected_retirement_telemetry.completed_prepare_count += 1;
            expected_retirement_telemetry.submitted_prepare_count += 1;
        },
    }
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    // Exact adapter replay is served by its retained permit and does not
    // re-enter the native prepare boundary.
    try testing.expectEqualDeep(
        retirement_result,
        try adapter
            .armSyntheticLossDispatchCallbackRetirementForTestV1(
            &coordinator,
            dispatch_interface,
            plan,
            retention,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            lease,
            pin,
            ticket,
        ),
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    // The same native submission does cross the native boundary and is
    // classified as one live-record prepare replay.
    const native_permit =
        try metal_fault_control
            .prepareRegisteredDispatchRetirementForTest(
            &backend,
            fault_facts.published_submission,
        );
    try testing.expectEqual(
        retirement_result.fence.native_retirement_generation,
        native_permit.retirement_generation,
    );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.prepare_replay_count += 1;
    expected_retirement_telemetry
        .prepare_live_record_replay_count += 1;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try loss_dispatch_callback_retirement
        .validateLossDispatchCallbackFenceV1(
        retirement_result.fence,
        plan,
        retention,
    );
    try testing.expect(
        retirement_result.fence.retained_state ==
            expected_retained_state,
    );
    try testing.expectEqual(
        @as(u64, 1),
        retirement_result.fence.native_callback_detached,
    );
    try testing.expectEqual(
        @as(u64, 1),
        retirement_result.fence.native_record_retained,
    );
    try testing.expectEqual(
        expected_completion_observed,
        retirement_result.fence.native_completion_observed,
    );
    try testing.expectEqual(
        if (retained_case == .submission_ambiguous)
            @as(u64, 0)
        else
            metal_allocation.async_native_command_status_completed,
        retirement_result.fence.native_command_status,
    );
    try testing.expect(
        retirement_result.fence.native_error_domain_kind ==
            .none,
    );
    try testing.expectEqual(
        @as(u64, 0),
        retirement_result.fence.native_error_code_bits,
    );
    if (retained_case == .submission_ambiguous) {
        try testing.expect(device.digestEqual(
            retirement_result.fence.callback_snapshot_sha256,
            allocation.zero_digest,
        ));
    } else {
        try testing.expect(!device.digestEqual(
            retirement_result.fence.callback_snapshot_sha256,
            allocation.zero_digest,
        ));
    }
    try testing.expect(
        retirement_result.terminal.outcome ==
            .ownership_retired_after_device_loss,
    );
    try testing.expect(device.digestEqual(
        retirement_result.terminal.submission_sha256,
        ticket.submission_sha256,
    ));
    try testing.expect(device.digestEqual(
        retirement_result.terminal.output_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        retirement_result.fence.output_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expectEqualSlices(
        f32,
        &output_before,
        &output,
    );
    try bank.validateLeasePin(bank_permit);
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );

    // Consume the Bank permit, then fail the first native commit at its final
    // boundary. The prepared record and every telemetry counter must remain
    // unchanged so the exact settlement can be retried.
    try metal_fault_control
        .armNextDispatchRetirementCommitFailure(
        &backend,
    );
    try testing.expectError(
        tree_allocation.Error.InvalidDispatchCompletion,
        coordinator.completeDispatchPin(
            pin,
            dispatch_interface,
            retirement_result.terminal,
        ),
    );
    try testing.expectEqual(
        @as(u64, 0),
        settlement_replay.confirmation_calls,
    );
    try testing.expect(
        settlement_replay.bank_consumed_before_native_finalize,
    );
    try testing.expect(
        !settlement_replay.native_finalized_before_retry,
    );
    try testing.expectError(
        resource.Error.StaleReservation,
        bank.validateLeasePin(bank_permit),
    );
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqualDeep(
        fault_facts,
        try metal_fault_control.completionFactsForBindingV2(
            &backend,
            ticket.ticket_sha256,
        ),
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expectEqualDeep(
        metal_fault_control.RetirementCommitFactsV1{
            .abi_version = metal_fault_control.retirement_commit_facts_abi,
            .commit_attempt_count = 1,
            .injected_failure_count = 1,
        },
        try metal_fault_control.dispatchRetirementCommitFacts(
            &backend,
        ),
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );
    try testing.expectEqualSlices(
        f32,
        &output_before,
        &output,
    );

    // The retry commits the one retained native record, but the wrapper then
    // rejects the private acknowledgement. This isolates a successful native
    // commit from the later adapter-local coordinator replay.
    try testing.expectError(
        tree_allocation.Error.InvalidDispatchCompletion,
        coordinator.completeDispatchPin(
            pin,
            dispatch_interface,
            retirement_result.terminal,
        ),
    );
    try testing.expectEqual(
        @as(u64, 1),
        settlement_replay.confirmation_calls,
    );
    try testing.expect(
        settlement_replay.native_finalized_before_retry,
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqualDeep(
        metal_fault_control.RetirementCommitFactsV1{
            .abi_version = metal_fault_control.retirement_commit_facts_abi,
            .commit_attempt_count = 2,
            .injected_failure_count = 1,
            .committed_retirement_count = 1,
        },
        try metal_fault_control.dispatchRetirementCommitFacts(
            &backend,
        ),
    );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.committed_retirement_count += 1;
    expected_retirement_telemetry.live_prepared_retirement_count -= 1;
    expected_retirement_telemetry.retired_native_command_count += 1;
    expected_retirement_telemetry
        .released_allocation_reference_count += 4;
    expected_retirement_telemetry.retained_tombstone_count += 1;
    expected_retirement_telemetry
        .highest_committed_retirement_generation =
        native_permit.retirement_generation;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    const native_replay_receipt =
        try backend.commitRegisteredDispatchRetirement(
            native_permit,
        );
    try engine.metal_backend
        .validateMetalRegisteredDispatchRetirementReceipt(
        native_replay_receipt,
        native_permit,
    );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.commit_replay_count += 1;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqualDeep(
        native_permit,
        try metal_fault_control
            .prepareRegisteredDispatchRetirementForTest(
            &backend,
            fault_facts.published_submission,
        ),
    );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.prepare_replay_count += 1;
    expected_retirement_telemetry
        .prepare_tombstone_replay_count += 1;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );

    // Only the private adapter confirmation is replayed here. Native commit
    // telemetry and native fault-control facts must remain unchanged.
    const completion = try coordinator.completeDispatchPin(
        pin,
        dispatch_interface,
        retirement_result.terminal,
    );
    try tree_allocation.validateDispatchCompletionForPinV1(
        completion,
        pin,
        retirement_result.terminal,
    );
    try testing.expect(
        completion.outcome ==
            .ownership_retired_after_device_loss,
    );
    try testing.expect(device.digestEqual(
        completion.output_sha256,
        allocation.zero_digest,
    ));
    try testing.expectEqual(
        @as(u64, 2),
        settlement_replay.confirmation_calls,
    );
    try testing.expectEqual(
        @as(usize, 0),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expectEqualDeep(
        fault_facts,
        try metal_fault_control.completionFactsForBindingV2(
            &backend,
            ticket.ticket_sha256,
        ),
    );
    try testing.expectEqualDeep(
        metal_fault_control.RetirementCommitFactsV1{
            .abi_version = metal_fault_control.retirement_commit_facts_abi,
            .commit_attempt_count = 3,
            .injected_failure_count = 1,
            .committed_retirement_count = 1,
            .replay_count = 1,
        },
        try metal_fault_control.dispatchRetirementCommitFacts(
            &backend,
        ),
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    const receipt =
        try adapter.completeLossDispatchCallbackRetirementV1(
            plan,
            retention,
            completion,
        );
    try loss_dispatch_callback_retirement
        .validateLossDispatchCallbackRetirementReceiptV1(
        receipt,
        plan,
        retention,
        retirement_result.fence,
        inventory_entry,
        lease,
        pin,
        retirement_result.terminal,
        completion,
    );
    try testing.expect(
        receipt.retained_state == expected_retained_state,
    );
    try testing.expectEqual(
        @as(u64, 1),
        receipt.released_dispatch_pin_count,
    );
    try testing.expectEqual(
        @as(u64, 1),
        receipt.retired_native_command_count,
    );
    try testing.expectEqual(
        @as(u64, 1),
        receipt.detached_native_callback_count,
    );
    try testing.expect(device.digestEqual(
        receipt.output_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        receipt.migration_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        receipt.reset_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        receipt.physical_reclaim_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expectEqualDeep(
        receipt,
        try adapter.completeLossDispatchCallbackRetirementV1(
            plan,
            retention,
            completion,
        ),
    );
    try testing.expectEqualDeep(
        receipt,
        (try adapter
            .currentLossDispatchCallbackRetirementReceiptV1(
            plan,
            retention,
            completion,
        )).?,
    );
    try adapter.acknowledgeDispatchCompletion(completion);
    try adapter.acknowledgeDispatchCompletion(completion);
    // Public receipt and acknowledgement replays are adapter-local.
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    try testing.expectEqualSlices(
        f32,
        &output_before,
        &output,
    );
    try testing.expectEqual(
        fixture.manifest.total_charged_bytes,
        (try bank.snapshotV3()).used.device_bytes,
    );
    try testing.expectEqual(
        @as(u64, 4),
        backend.liveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 4),
        try backend.nativeLiveBufferCount(),
    );
    _ = try backend.inspectBufferAllocation(
        native_slots[0].native_token,
    );

    if (callback_hold_active) {
        try metal_fault_control.releaseHeldCompletionCallback(
            &backend,
        );
        callback_hold_active = false;
    }
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    const released = try coordinator.release(
        lease,
        adapter.interface(),
    );
    const allocation_terminal = switch (released) {
        .terminal => |value| value,
        .recovery_required => return error.TestUnexpectedResult,
    };
    try tree_allocation.validateTerminalReceiptV1(
        allocation_terminal,
    );
    try testing.expectEqual(
        @as(u64, 0),
        (try bank.snapshotV3()).used.device_bytes,
    );
    try testing.expectEqual(
        @as(u64, 0),
        backend.liveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try adapter.validateEmpty();
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    const recovery_token =
        try backend.createBufferAllocation(64);
    try backend.destroyBufferAllocation(recovery_token);
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );

    try bank.closePublicationSession(
        parent,
        305,
        session_id,
        publication_sequence,
    );
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
    try testing.expect((try bank.snapshot()).used.isZero());
}

test "Phase-B callback retirement settles native submission-ambiguous dispatch" {
    try runPhaseBRetainedStateE2E(.submission_ambiguous);
}

test "Phase-B callback retirement settles native completion-unknown dispatch" {
    try runPhaseBRetainedStateE2E(.completion_unknown);
}

test "Phase-B callback retirement settles native invalid-completion dispatch" {
    try runPhaseBRetainedStateE2E(.invalid_completion);
}

test "synthetic loss settles pending adapter dispatch through callback retirement" {
    if (comptime !metal_fault_control.enabled)
        return error.SkipZigTest;
    if (!config.metal_enabled)
        return error.NativeMetalAllocationRequiresMetal;

    var backend = try engine.MetalBackend.init(
        engine.metal_library_path,
    );
    defer backend.deinit();
    var expected_retirement_telemetry =
        try initialDispatchRetirementTelemetry(&backend);
    const completed_dispatches_before_retirement =
        backend.completedDispatchCount();
    const inventory_entry =
        try metal_allocation.makeAllocationInventoryEntryV1(
            &backend,
            114,
            0,
            1 * 1024 * 1024,
        );
    var native_slots =
        [_]metal_allocation.MetalAllocationSlotV1{.{}} ** 4;
    var adapter =
        try metal_allocation.MetalAllocationAdapterV1.init(
            &backend,
            inventory_entry,
            214,
            0x4342_5265_7469_7265,
            &native_slots,
        );
    const fixture = try makeDispatchFixture(
        &adapter,
        inventory_entry,
    );

    var bank_slots = [_]resource.Slot{.{}};
    var tree_roots = [_]resource.LeaseTreeRootSlot{.{}};
    var tree_nodes = [_]resource.LeaseNodeSlot{.{}} ** 5;
    var pin_slots = [_]resource.LeasePinSlotV1{.{}};
    var bank = try resource.Bank.initWithLeaseTreePinStorage(
        &bank_slots,
        &tree_roots,
        &tree_nodes,
        &pin_slots,
        .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = fixture.manifest.total_charged_bytes,
            .queue_slots = 1,
        },
        414,
    );
    const parent = try bank.commit(
        try bank.reserve(514, .{
            .capsule_bytes = 64,
            .queue_slots = 1,
        }),
    );
    const opened = try bank.openLeaseTree(
        parent,
        0x4342_5265_7445_3254,
        0x4342_5265_7441_7574,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    const scoped = try bank.openLeaseScope(
        opened,
        0x4342_5265_7453_636f,
        0x4342_5265_7454_656e,
        .{
            .device_bytes = fixture.manifest.total_charged_bytes,
        },
    );
    var tree = scoped.tree;
    var session_byte: u8 = 0;
    const session_id = @intFromPtr(&session_byte);
    var publication_sequence: u64 = 0;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        304,
        session_id,
    );
    var coordinator_objects =
        [_]tree_allocation.CoordinatorObjectSlotV1{.{}} ** 4;
    var coordinator_dispatches =
        [_]tree_allocation.CoordinatorDispatchSlotV1{.{}};
    var coordinator: tree_allocation.CoordinatorV1 = .{};
    try coordinator.initWithDispatchStorage(
        614,
        &bank,
        &tree,
        scoped.scope,
        304,
        session_id,
        &publication_sequence,
        &coordinator_objects,
        &coordinator_dispatches,
    );
    const request = try allocation.makeRequestV1(
        304,
        digest("callback retirement allocation owner"),
        adapter.authority,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const admission = try coordinator.admit(
        adapter.interface(),
        request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const materialized = try coordinator.materialize(
        admission,
        adapter.interface(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(
        @as(u64, 4),
        backend.liveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 4),
        try backend.nativeLiveBufferCount(),
    );

    const packed_values =
        [_]u8{0} ** held_callback_packed_bytes;
    const scales =
        [_]f32{1.0} ** held_callback_scale_count;
    const input =
        [_]f32{0.25} ** held_callback_in_features;
    var output =
        [_]f32{-987.25} ** held_callback_out_features;
    const output_before = output;
    const attempt =
        try metal_allocation.makeMetalMatvecPreSubmitAttemptV1(
            fixture.bindings,
            packed_values.len,
            scales.len,
            input.len,
            output.len,
            held_callback_group_size,
            held_callback_in_features,
            held_callback_out_features,
        );
    const dispatch_request =
        try adapter.prepareMatvecDispatchRequestV1(attempt);
    const pin = try coordinator.acquireDispatchPin(
        lease,
        adapter.dispatchInterface(),
        dispatch_request.request_sha256,
    );
    try tree_allocation.validateDispatchPinV1(pin);
    const bank_permit =
        coordinator_dispatches[0].bank_permit.?;
    try bank.validateLeasePin(bank_permit);

    // The command executes on Metal, but its completed handler remains before
    // the callback gate. The adapter therefore still owns an exact pending
    // dispatch with no callback-published completion or output.
    try metal_fault_control.armNextCompletionCallbackHold(
        &backend,
    );
    var callback_hold_active = true;
    defer if (callback_hold_active)
        metal_fault_control.releaseHeldCompletionCallback(
            &backend,
        ) catch {};
    const ticket = try adapter.submitMatvecInt4AsyncObserved(
        lease,
        pin,
        fixture.bindings,
        &packed_values,
        &scales,
        &input,
        &output,
        held_callback_group_size,
        held_callback_in_features,
        held_callback_out_features,
    );
    try metal_allocation.validateMetalAsyncDispatchTicketV1(
        ticket,
    );
    try metal_fault_control.waitForHeldCompletionCallback(
        &backend,
    );
    try testing.expectEqualSlices(
        f32,
        &output_before,
        &output,
    );
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expectEqual(
        fixture.manifest.total_charged_bytes,
        (try bank.snapshotV3()).used.device_bytes,
    );
    // A physically finished command whose callback is still held has not
    // entered callback-retirement. Telemetry and ordinary completion facts
    // therefore remain at their context baseline.
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    // Exercise the public adapter wait path, not merely the native backend
    // helper. The fault shim confirms that the worker has copied the command
    // and publication group and is blocked outside both adapter/backend
    // ownership mutexes before this thread begins Phase-B retirement.
    var adapter_wait_started =
        std.atomic.Value(bool).init(false);
    var adapter_wait_finished =
        std.atomic.Value(bool).init(false);
    var adapter_wait_worker: MetalAdapterWaitWorker = .{
        .adapter = &adapter,
        .lease = lease,
        .pin = pin,
        .ticket = ticket,
        .output = &output,
        .started = &adapter_wait_started,
        .finished = &adapter_wait_finished,
    };
    const adapter_wait_thread = try std.Thread.spawn(
        .{},
        MetalAdapterWaitWorker.run,
        .{&adapter_wait_worker},
    );
    var adapter_wait_joined = false;
    defer if (!adapter_wait_joined) {
        if (callback_hold_active) {
            metal_fault_control.releaseHeldCompletionCallback(
                &backend,
            ) catch {};
            callback_hold_active = false;
        }
        adapter_wait_thread.join();
    };
    try metal_fault_control.waitForRegisteredDispatchWaiter(
        &backend,
    );
    try testing.expect(
        adapter_wait_started.load(.acquire),
    );
    try testing.expect(
        !adapter_wait_finished.load(.acquire),
    );

    const source_cursor: lifecycle.SourceCursorV1 = .{
        .source_instance_sha256 = digest(
            "callback retirement synthetic loss source",
        ),
        .last_sequence = 0,
    };
    const observation = try lifecycle.makeObservationV1(
        inventory_entry,
        &fixture.inventory,
        source_cursor.source_instance_sha256,
        1,
        .test_injected,
        digest("callback retirement synthetic loss evidence"),
        0,
        0,
        0,
    );
    const successor_entry = try lifecycle.makeSuccessorEntryV1(
        observation,
        inventory_entry,
        &fixture.inventory,
        source_cursor,
        inventory_entry.discovery_epoch + 1,
    );
    const transition = try lifecycle.makeTransitionReceiptV1(
        observation,
        inventory_entry,
        &fixture.inventory,
        successor_entry,
        source_cursor,
    );
    const adapter_challenge =
        try adapter
            .lossDispatchCallbackRetirementAdapterChallengeV1(
            &coordinator,
            adapter.dispatchInterface(),
            observation,
            lease,
            pin,
            ticket,
        );
    const retention =
        try loss_dispatch_callback_retirement
            .makeLossDispatchCallbackRetentionV1(
            .pending,
            .submitted,
            0,
            0,
            .none,
            0,
            inventory_entry,
            lease,
            pin,
            ticket.ticket_sha256,
            ticket.submission_sha256,
            allocation.zero_digest,
            adapter_challenge,
        );
    const plan =
        try loss_dispatch_callback_retirement
            .makeLossDispatchCallbackRetirementPlanV1(
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            retention,
            lease,
            pin,
            1,
        );
    try testing.expectError(
        loss_dispatch_callback_retirement
            .Error.ProductionEvidenceRequired,
        adapter.armLossDispatchCallbackRetirementV1(
            &coordinator,
            adapter.dispatchInterface(),
            plan,
            retention,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            lease,
            pin,
            ticket,
        ),
    );

    // A separately sealed but foreign retention is structurally valid and
    // cannot substitute for the adapter-derived challenge.
    const foreign_retention =
        try loss_dispatch_callback_retirement
            .makeLossDispatchCallbackRetentionV1(
            .pending,
            .submitted,
            0,
            0,
            .none,
            0,
            inventory_entry,
            lease,
            pin,
            ticket.ticket_sha256,
            ticket.submission_sha256,
            allocation.zero_digest,
            digest("foreign callback retirement challenge"),
        );
    const foreign_plan =
        try loss_dispatch_callback_retirement
            .makeLossDispatchCallbackRetirementPlanV1(
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            foreign_retention,
            lease,
            pin,
            1,
        );
    try testing.expectError(
        tree_allocation.Error.InvalidDispatchReconciliationBinding,
        adapter
            .armSyntheticLossDispatchCallbackRetirementForTestV1(
            &coordinator,
            adapter.dispatchInterface(),
            foreign_plan,
            foreign_retention,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            lease,
            pin,
            ticket,
        ),
    );

    const retirement_result =
        try adapter
            .armSyntheticLossDispatchCallbackRetirementForTestV1(
            &coordinator,
            adapter.dispatchInterface(),
            plan,
            retention,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            lease,
            pin,
            ticket,
        );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.prepared_retirement_count += 1;
    expected_retirement_telemetry.live_prepared_retirement_count += 1;
    expected_retirement_telemetry.callback_detached_count += 1;
    expected_retirement_telemetry.completion_unobserved_prepare_count += 1;
    expected_retirement_telemetry.pending_prepare_count += 1;
    expected_retirement_telemetry.submitted_prepare_count += 1;
    expected_retirement_telemetry.synthetic_test_prepare_count += 1;
    expected_retirement_telemetry
        .highest_prepared_retirement_generation =
        retirement_result.fence.native_retirement_generation;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqualDeep(
        retirement_result,
        try adapter
            .armSyntheticLossDispatchCallbackRetirementForTestV1(
            &coordinator,
            adapter.dispatchInterface(),
            plan,
            retention,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            lease,
            pin,
            ticket,
        ),
    );
    // This replay is resolved by the adapter's retained permit and never
    // crosses the native prepare boundary.
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try loss_dispatch_callback_retirement
        .validateLossDispatchCallbackFenceV1(
        retirement_result.fence,
        plan,
        retention,
    );
    try testing.expect(
        retirement_result.fence.state ==
            .detached_pending_settlement,
    );
    try testing.expectEqual(
        @as(u64, 1),
        retirement_result.fence.native_callback_detached,
    );
    try testing.expectEqual(
        @as(u64, 1),
        retirement_result.fence.native_record_retained,
    );
    try testing.expectEqual(
        @as(u64, 0),
        retirement_result.fence.native_completion_observed,
    );
    try testing.expect(
        retirement_result.terminal.outcome ==
            .ownership_retired_after_device_loss,
    );
    try testing.expect(device.digestEqual(
        retirement_result.terminal.submission_sha256,
        ticket.submission_sha256,
    ));
    try testing.expect(device.digestEqual(
        retirement_result.terminal.backend_completion_sha256,
        retirement_result.fence.backend_terminal_sha256,
    ));
    try testing.expect(device.digestEqual(
        retirement_result.terminal.output_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        retirement_result.fence.output_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expectEqualSlices(
        f32,
        &output_before,
        &output,
    );
    try bank.validateLeasePin(bank_permit);
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );

    const next_plan =
        try loss_dispatch_callback_retirement
            .makeLossDispatchCallbackRetirementPlanV1(
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            retention,
            lease,
            pin,
            2,
        );
    try testing.expectError(
        metal_allocation.Error.DispatchBusy,
        adapter
            .armSyntheticLossDispatchCallbackRetirementForTestV1(
            &coordinator,
            adapter.dispatchInterface(),
            next_plan,
            retention,
            observation,
            transition,
            source_cursor,
            fixture.requirement,
            fixture.selection,
            &fixture.inventory,
            inventory_entry,
            successor_entry,
            lease,
            pin,
            ticket,
        ),
    );
    const substituted_terminal =
        try tree_allocation.makeDispatchTerminalV1(
            pin,
            .ownership_retired_after_device_loss,
            ticket.submission_sha256,
            digest("foreign callback retirement terminal"),
            allocation.zero_digest,
        );
    try testing.expectError(
        tree_allocation.Error.InvalidDispatchTerminal,
        coordinator.completeDispatchPin(
            pin,
            adapter.dispatchInterface(),
            substituted_terminal,
        ),
    );
    try bank.validateLeasePin(bank_permit);
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );

    try metal_fault_control
        .armNextDispatchRetirementCommitFailure(
        &backend,
    );
    try testing.expectError(
        tree_allocation.Error.InvalidDispatchCompletion,
        coordinator.completeDispatchPin(
            pin,
            adapter.dispatchInterface(),
            retirement_result.terminal,
        ),
    );
    try testing.expectError(
        resource.Error.StaleReservation,
        bank.validateLeasePin(bank_permit),
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expectEqual(
        @as(u64, 1),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqualSlices(
        f32,
        &output_before,
        &output,
    );
    try testing.expect(
        !adapter_wait_finished.load(.acquire),
    );
    try testing.expectEqualDeep(
        metal_fault_control.RetirementCommitFactsV1{
            .abi_version = metal_fault_control.retirement_commit_facts_abi,
            .commit_attempt_count = 1,
            .injected_failure_count = 1,
        },
        try metal_fault_control.dispatchRetirementCommitFacts(
            &backend,
        ),
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    const completion = try coordinator.completeDispatchPin(
        pin,
        adapter.dispatchInterface(),
        retirement_result.terminal,
    );
    try tree_allocation.validateDispatchCompletionForPinV1(
        completion,
        pin,
        retirement_result.terminal,
    );
    try testing.expect(
        completion.outcome ==
            .ownership_retired_after_device_loss,
    );
    try testing.expect(device.digestEqual(
        completion.output_sha256,
        allocation.zero_digest,
    ));
    try testing.expectError(
        resource.Error.StaleReservation,
        bank.validateLeasePin(bank_permit),
    );
    try testing.expectEqual(
        @as(usize, 0),
        (try coordinator.snapshot()).active_dispatches,
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveCommandCount(),
    );
    try testing.expectEqualDeep(
        metal_fault_control.RetirementCommitFactsV1{
            .abi_version = metal_fault_control.retirement_commit_facts_abi,
            .commit_attempt_count = 2,
            .injected_failure_count = 1,
            .committed_retirement_count = 1,
        },
        try metal_fault_control.dispatchRetirementCommitFacts(
            &backend,
        ),
    );
    expected_retirement_telemetry.snapshot_sequence += 1;
    expected_retirement_telemetry.committed_retirement_count += 1;
    expected_retirement_telemetry.live_prepared_retirement_count -= 1;
    expected_retirement_telemetry.retired_native_command_count += 1;
    expected_retirement_telemetry
        .released_allocation_reference_count += 4;
    expected_retirement_telemetry.retained_tombstone_count += 1;
    expected_retirement_telemetry
        .highest_committed_retirement_generation =
        retirement_result.fence.native_retirement_generation;
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );
    try testing.expect(
        !adapter_wait_finished.load(.acquire),
    );
    try testing.expectError(
        tree_allocation.Error.InvalidDispatchPin,
        coordinator.completeDispatchPin(
            pin,
            adapter.dispatchInterface(),
            retirement_result.terminal,
        ),
    );

    const receipt =
        try adapter.completeLossDispatchCallbackRetirementV1(
            plan,
            retention,
            completion,
        );
    try loss_dispatch_callback_retirement
        .validateLossDispatchCallbackRetirementReceiptV1(
        receipt,
        plan,
        retention,
        retirement_result.fence,
        inventory_entry,
        lease,
        pin,
        retirement_result.terminal,
        completion,
    );
    try testing.expectEqual(@as(u64, 1), receipt.released_dispatch_pin_count);
    try testing.expectEqual(@as(u64, 1), receipt.retired_native_command_count);
    try testing.expectEqual(@as(u64, 1), receipt.detached_native_callback_count);
    try testing.expect(device.digestEqual(
        receipt.output_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        receipt.migration_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        receipt.reset_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expect(device.digestEqual(
        receipt.physical_reclaim_authority_sha256,
        allocation.zero_digest,
    ));
    try testing.expectEqualDeep(
        receipt,
        try adapter.completeLossDispatchCallbackRetirementV1(
            plan,
            retention,
            completion,
        ),
    );
    try testing.expectEqualDeep(
        receipt,
        (try adapter
            .currentLossDispatchCallbackRetirementReceiptV1(
            plan,
            retention,
            completion,
        )).?,
    );
    // Receipt replay is adapter-local and must not invoke native retirement
    // again after the one exact unlink.
    try testing.expectEqualDeep(
        metal_fault_control.RetirementCommitFactsV1{
            .abi_version = metal_fault_control.retirement_commit_facts_abi,
            .commit_attempt_count = 2,
            .injected_failure_count = 1,
            .committed_retirement_count = 1,
        },
        try metal_fault_control.dispatchRetirementCommitFacts(
            &backend,
        ),
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    var foreign_completion = completion;
    foreign_completion.completion_sha256[0] ^= 1;
    try testing.expectError(
        metal_allocation.Error.StaleObject,
        adapter.currentLossDispatchCallbackRetirementReceiptV1(
            plan,
            retention,
            foreign_completion,
        ),
    );
    try adapter.acknowledgeDispatchCompletion(completion);
    try adapter.acknowledgeDispatchCompletion(completion);
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );

    // Dispatch ownership is gone, but allocation ownership and its Bank
    // charge are deliberately still live until the separate lease release.
    try testing.expectEqualSlices(
        f32,
        &output_before,
        &output,
    );
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );
    try testing.expectEqual(
        fixture.manifest.total_charged_bytes,
        (try bank.snapshotV3()).used.device_bytes,
    );
    try testing.expectEqual(
        @as(u64, 4),
        backend.liveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 4),
        try backend.nativeLiveBufferCount(),
    );
    _ = try backend.inspectBufferAllocation(
        native_slots[0].native_token,
    );

    try metal_fault_control.releaseHeldCompletionCallback(
        &backend,
    );
    callback_hold_active = false;
    var adapter_wait_timer = try std.time.Timer.start();
    while (!adapter_wait_finished.load(.acquire) and
        adapter_wait_timer.read() < 5 * std.time.ns_per_s)
        std.Thread.yield() catch {};
    try testing.expect(
        adapter_wait_finished.load(.acquire),
    );
    adapter_wait_thread.join();
    adapter_wait_joined = true;
    try testing.expect(
        adapter_wait_worker.observation == null,
    );
    try testing.expect(
        adapter_wait_worker.wait_error != null,
    );
    try testing.expect(
        adapter_wait_worker.wait_error.? ==
            metal_allocation.Error.StaleObject,
    );
    try testing.expectEqualSlices(
        f32,
        &output_before,
        &output,
    );

    const released = try coordinator.release(
        lease,
        adapter.interface(),
    );
    const allocation_terminal = switch (released) {
        .terminal => |value| value,
        .recovery_required => return error.TestUnexpectedResult,
    };
    try tree_allocation.validateTerminalReceiptV1(
        allocation_terminal,
    );
    try testing.expectEqual(
        @as(u64, 0),
        (try bank.snapshotV3()).used.device_bytes,
    );
    try testing.expectEqual(
        @as(u64, 0),
        backend.liveBufferCount(),
    );
    try testing.expectEqual(
        @as(u64, 0),
        try backend.nativeLiveBufferCount(),
    );
    try adapter.validateEmpty();
    try expectDispatchRetirementTelemetry(
        &backend,
        expected_retirement_telemetry,
    );
    try testing.expectEqual(
        completed_dispatches_before_retirement,
        backend.completedDispatchCount(),
    );

    try bank.closePublicationSession(
        parent,
        304,
        session_id,
        publication_sequence,
    );
    try bank.closeLeaseTree(tree);
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
