//! Native Metal adapter for the portable device-allocation lease.
//!
//! The portable V1 charge is the exact logical `MTLBuffer.length` returned by
//! a direct Shared resource. `MTLResource.allocatedSize` is retained as a
//! separate per-object native observation because Metal exposes it only after
//! creation. Neither value is relabelled as residency, and device-wide
//! `currentAllocatedSize` is never used to infer object ownership.

const std = @import("std");
const core = @import("core");
const config = @import("config");
const metal = @import("backend.zig");
const native = @import("native_observer.zig");

const metal_enabled = if (@hasDecl(config, "metal_enabled"))
    config.metal_enabled
else
    false;

pub const allocation = core.device_allocation_lease;
pub const lease_tree = core.device_allocation_lease_tree;
pub const device = core.device_capability_contract;
pub const Digest = allocation.Digest;

pub const adapter_abi: u64 = 0x474d_4141_0000_0001;
pub const observation_abi: u64 = 0x474d_414f_0000_0001;
pub const dispatch_observation_abi: u64 =
    0x474d_444f_0000_0001;

const authority_domain =
    "glacier-metal-allocation-authority-v1\x00";
const object_identity_domain =
    "glacier-metal-allocation-object-identity-v1\x00";
const observation_domain =
    "glacier-metal-allocation-observation-v1\x00";
const dispatch_authority_domain =
    "glacier-metal-dispatch-authority-v1\x00";
const queue_authority_domain =
    "glacier-metal-dispatch-queue-authority-v1\x00";
const dispatch_geometry_domain =
    "glacier-metal-dispatch-geometry-v1\x00";
const dispatch_roles_domain =
    "glacier-metal-dispatch-roles-v1\x00";
const dispatch_packed_input_domain =
    "glacier-metal-dispatch-packed-input-v1\x00";
const dispatch_scales_input_domain =
    "glacier-metal-dispatch-scales-input-v1\x00";
const dispatch_vector_input_domain =
    "glacier-metal-dispatch-vector-input-v1\x00";
const dispatch_output_domain =
    "glacier-metal-dispatch-output-v1\x00";
const dispatch_submission_domain =
    "glacier-metal-dispatch-submission-v1\x00";
const dispatch_telemetry_domain =
    "glacier-metal-dispatch-telemetry-v1\x00";
const dispatch_backend_completion_domain =
    "glacier-metal-dispatch-backend-completion-v1\x00";
const dispatch_observation_domain =
    "glacier-metal-dispatch-observation-v1\x00";
const completed_command_buffer_status: u32 = 4;
const supported_profile =
    device.OperationProfileBitsV1.matvec_int4_f32_bounded;
const supported_features =
    device.FeatureBitsV1.allocation |
    device.FeatureBitsV1.dispatch |
    device.FeatureBitsV1.completion_fence |
    device.FeatureBitsV1.persistent_weights |
    device.FeatureBitsV1.allocated_bytes_observation;

pub const Error =
    allocation.Error ||
    lease_tree.Error ||
    device.Error ||
    metal.MetalError ||
    error{
        InvalidConfiguration,
        InvalidDevice,
        InvalidObservation,
        InvalidDispatchEvidence,
        DispatchBusy,
        DispatchUnresolved,
        StaleObject,
        BufferTooSmall,
    };

/// Semantic binding identities for the four exact live allocations consumed
/// by one registered-buffer INT4 matvec. Digests are role labels, never
/// native handles, GPU addresses, or allocation permits.
pub const MetalMatvecAllocationBindingsV1 = struct {
    packed_weights_sha256: Digest = allocation.zero_digest,
    scales_sha256: Digest = allocation.zero_digest,
    input_sha256: Digest = allocation.zero_digest,
    output_sha256: Digest = allocation.zero_digest,
};

/// Canonical geometry derived before the backend is allowed to submit.
pub const MetalMatvecGeometryV1 = struct {
    group_size: u32 = 0,
    in_features: u32 = 0,
    out_features: u32 = 0,
    reserved: u32 = 0,
    packed_bytes: u64 = 0,
    scale_count: u64 = 0,
    scales_bytes: u64 = 0,
    input_count: u64 = 0,
    input_bytes: u64 = 0,
    output_count: u64 = 0,
    output_bytes: u64 = 0,
    geometry_sha256: Digest = allocation.zero_digest,
};

/// Pointer-free binding of semantic roles to the exact four backend objects.
/// Native registry tokens stay private inside the adapter.
pub const MetalMatvecRoleEvidenceV1 = struct {
    bindings: MetalMatvecAllocationBindingsV1 = .{},
    packed_weights_object_sha256: Digest = allocation.zero_digest,
    scales_object_sha256: Digest = allocation.zero_digest,
    input_object_sha256: Digest = allocation.zero_digest,
    output_object_sha256: Digest = allocation.zero_digest,
    roles_sha256: Digest = allocation.zero_digest,
};

/// Sealed evidence from one physically completed registered-buffer dispatch.
/// This is composition evidence, not authentication or a residency claim.
pub const MetalLeaseTreeDispatchObservationV1 = struct {
    abi_version: u64 = dispatch_observation_abi,
    outcome: lease_tree.DispatchTerminalOutcomeV1 = .succeeded,
    dispatch_generation: u64 = 0,
    allocation_count: u64 = 0,
    materialized_bytes: u64 = 0,
    authority_sha256: Digest = allocation.zero_digest,
    admission_sha256: Digest = allocation.zero_digest,
    lease_sha256: Digest = allocation.zero_digest,
    backend_object_set_sha256: Digest = allocation.zero_digest,
    pin_sha256: Digest = allocation.zero_digest,
    dispatch_request_sha256: Digest = allocation.zero_digest,
    dispatch_authority_sha256: Digest = allocation.zero_digest,
    queue_authority_sha256: Digest = allocation.zero_digest,
    geometry: MetalMatvecGeometryV1 = .{},
    roles: MetalMatvecRoleEvidenceV1 = .{},
    packed_weights_input_sha256: Digest = allocation.zero_digest,
    scales_input_sha256: Digest = allocation.zero_digest,
    vector_input_sha256: Digest = allocation.zero_digest,
    submission_sha256: Digest = allocation.zero_digest,
    telemetry: metal.MetalDispatchTelemetry = .{
        .current_allocated_before = 0,
        .current_allocated_after = 0,
        .gpu_start_time_bits = 0,
        .gpu_end_time_bits = 0,
        .gpu_duration_nanoseconds = 0,
        .command_status = 0,
    },
    telemetry_sha256: Digest = allocation.zero_digest,
    backend_completion_sha256: Digest = allocation.zero_digest,
    output_sha256: Digest = allocation.zero_digest,
    terminal_sha256: Digest = allocation.zero_digest,
    observation_sha256: Digest = allocation.zero_digest,
};

pub const MetalLeaseTreeDispatchResultV1 = struct {
    observation: MetalLeaseTreeDispatchObservationV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
};

const AuthorizedDispatchTerminalV1 = struct {
    pin: lease_tree.LeaseTreeDispatchPinV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
    observation: MetalLeaseTreeDispatchObservationV1,
};

const ValidatedMatvecDispatchSetV1 = struct {
    tokens: [4]metal.MetalBufferToken,
    evidence: MetalMatvecRoleEvidenceV1,
};

/// Pointer-free direct evidence for one currently live native allocation.
/// `charged_resource_bytes` is logical resource accounting.
/// `resource_allocated_size_bytes` is the direct Metal per-resource
/// observation and is not a residency or reclaim-completion claim.
pub const MetalAllocationObservationV1 = struct {
    abi_version: u64 = observation_abi,
    authority_sha256: Digest = allocation.zero_digest,
    admission_sha256: Digest = allocation.zero_digest,
    allocation_call_sha256: Digest = allocation.zero_digest,
    binding_sha256: Digest = allocation.zero_digest,
    backend_object_sha256: Digest = allocation.zero_digest,
    object_sha256: Digest = allocation.zero_digest,
    adapter_slot_index: u32 = 0,
    reserved: u32 = 0,
    backend_object_generation: u64 = 0,
    ordinal: u64 = 0,
    device_registry_id: u64 = 0,
    requested_bytes: u64 = 0,
    charged_resource_bytes: u64 = 0,
    buffer_length_bytes: u64 = 0,
    resource_allocated_size_bytes: u64 = 0,
    storage_mode: u32 = 0,
    cpu_cache_mode: u32 = 0,
    observation_sha256: Digest = allocation.zero_digest,
};

/// Caller-owned private storage. Native pointers never enter a receipt,
/// manifest, observation, or snapshot.
pub const MetalAllocationSlotV1 = struct {
    live: bool = false,
    generation: u64 = 0,
    call: allocation.AllocationCallV1 = .{},
    object: allocation.BackendObjectV1 = .{},
    native_token: metal.MetalBufferToken = .{},
    native_info: metal.MetalBufferInfo = .{},
};

pub const MetalAllocationSnapshotV1 = struct {
    authority_epoch: u64,
    adapter_instance: u64,
    device_registry_id: u64,
    used_resource_bytes: u64,
    observed_allocated_size_bytes: u64,
    live_objects: usize,
    materialized_leases: usize,
    allocate_calls: u64,
    free_calls: u64,
    inspect_calls: u64,
};

fn expectedAllocationCapabilityV1(
    info: metal.MetalDeviceInfo,
    limits: metal.MetalAllocationLimits,
    max_total_resource_bytes: u64,
) Error!device.DeviceCapabilityV1 {
    if (limits.device_registry_id != info.registry_id or
        limits.resource_granularity != 1 or
        limits.storage_mode != metal.shared_storage_mode or
        limits.cpu_cache_mode != metal.default_cpu_cache_mode or
        info.recommended_max_working_set_size == 0 or
        max_total_resource_bytes == 0 or
        max_total_resource_bytes >
            info.recommended_max_working_set_size)
        return Error.InvalidDevice;
    const maximum_single = @min(
        limits.max_buffer_length,
        max_total_resource_bytes,
    );
    if (maximum_single == 0) return Error.InvalidDevice;
    return device.sealCapabilityV1(.{
        .backend_kind = .metal,
        .device_class = .accelerator,
        .operation_profile_bits = supported_profile,
        .operator_bits = device.profileOperatorBitsV1(supported_profile),
        .element_type_bits = device.profileElementTypeBitsV1(supported_profile),
        .numerical_policy_bits = device.profileNumericalPolicyBitsV1(supported_profile),
        .feature_bits = supported_features,
        .max_single_allocation_bytes = maximum_single,
        .max_total_device_bytes = max_total_resource_bytes,
        .max_queue_slots = 1,
        .backend_sha256 = native.contract.digestV1(
            "Metal.framework direct Shared allocation backend/v1",
        ),
        .device_sha256 = native.deviceIdentityV1(info),
        .driver_sha256 = device.zero_digest,
        .placement_sha256 = native.placementIdentityV1(info),
    });
}

/// Build one bounded Metal inventory entry for allocation-aware execution.
/// The caller chooses a logical resource budget no larger than Metal's
/// recommended working-set context. Allocation may still fail and remains a
/// fallible operation; this is a compatibility ceiling, not a memory promise.
pub fn makeAllocationInventoryEntryV1(
    backend: *metal.MetalBackend,
    discovery_epoch: u64,
    policy_rank: u64,
    max_total_resource_bytes: u64,
) Error!device.DeviceInventoryEntryV1 {
    if (comptime !metal_enabled)
        return metal.MetalError.Unavailable;
    if (discovery_epoch == 0 or max_total_resource_bytes == 0)
        return Error.InvalidConfiguration;
    try backend.requireInt4MatvecSupport();
    const info = try backend.deviceInfo();
    const limits = try backend.allocationLimits();
    const capability = try expectedAllocationCapabilityV1(
        info,
        limits,
        max_total_resource_bytes,
    );
    return device.sealInventoryEntryV1(.{
        .discovery_epoch = discovery_epoch,
        .policy_rank = policy_rank,
        .state = .present,
        .capability = capability,
    });
}

/// Same-process adapter over one exact MetalBackend context.
///
/// Once `interface()` exposes this address, do not copy or move the value.
/// Every live lease must be released before the backend is deinitialized.
pub const MetalAllocationAdapterV1 = struct {
    backend: *metal.MetalBackend,
    authority: allocation.AllocationAuthorityV1,
    slots: []MetalAllocationSlotV1,
    limits: metal.MetalAllocationLimits,
    device_sha256: Digest,
    placement_sha256: Digest,
    adapter_nonce: u64,
    adapter_identity: metal.MetalAllocationAdapterIdentity,
    dispatch_authority_sha256: Digest,
    queue_authority_sha256: Digest,
    next_generation: u64 = 1,
    used_resource_bytes: u64 = 0,
    observed_allocated_size_bytes: u64 = 0,
    active_admission_sha256: Digest = allocation.zero_digest,
    dispatch_unresolved: bool = false,
    authorized_terminal: ?AuthorizedDispatchTerminalV1 = null,
    terminal_validation_observed: bool = false,
    allocate_calls: u64 = 0,
    free_calls: u64 = 0,
    inspect_calls: u64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        backend: *metal.MetalBackend,
        selected: device.DeviceInventoryEntryV1,
        authority_epoch: u64,
        adapter_nonce: u64,
        slots: []MetalAllocationSlotV1,
    ) Error!MetalAllocationAdapterV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        if (authority_epoch == 0 or adapter_nonce == 0 or
            slots.len == 0 or
            slots.len > allocation.maximum_allocations)
            return Error.InvalidConfiguration;
        try device.validateInventoryEntryV1(selected);
        try backend.requireInt4MatvecSupport();
        const info = try backend.deviceInfo();
        const limits = try backend.allocationLimits();
        const capability = selected.capability;
        const expected_device = native.deviceIdentityV1(info);
        const expected_placement = native.placementIdentityV1(info);
        const expected_capability =
            expectedAllocationCapabilityV1(
                info,
                limits,
                capability.max_total_device_bytes,
            ) catch return Error.InvalidDevice;
        const expected_selected =
            device.sealInventoryEntryV1(.{
                .discovery_epoch = selected.discovery_epoch,
                .policy_rank = selected.policy_rank,
                .state = .present,
                .capability = expected_capability,
            }) catch return Error.InvalidDevice;
        if (!std.meta.eql(selected, expected_selected) or
            !device.digestEqual(
                capability.device_sha256,
                expected_device,
            ) or
            !device.digestEqual(
                capability.placement_sha256,
                expected_placement,
            ))
            return Error.InvalidDevice;
        for (slots) |*slot| slot.* = .{};
        const adapter_identity =
            try backend.claimAllocationAdapterIdentity();
        const backend_authority_sha256 = backendAuthorityRootV1(
            authority_epoch,
            adapter_nonce,
            adapter_identity,
            selected,
            limits,
        );
        const authority = try allocation.makeAuthorityV1(
            authority_epoch,
            1,
            @intCast(slots.len),
            limits.resource_granularity,
            selected,
            backend_authority_sha256,
        );
        const dispatch_authority_sha256 =
            dispatchAuthorityRootV1(
                authority,
                adapter_nonce,
                adapter_identity,
                limits,
            );
        const queue_authority_sha256 = queueAuthorityRootV1(
            dispatch_authority_sha256,
            adapter_identity,
            limits,
        );
        if (digestIsZero(dispatch_authority_sha256) or
            digestIsZero(queue_authority_sha256) or
            device.digestEqual(
                dispatch_authority_sha256,
                queue_authority_sha256,
            ))
            return Error.InvalidConfiguration;
        return .{
            .backend = backend,
            .authority = authority,
            .slots = slots,
            .limits = limits,
            .device_sha256 = expected_device,
            .placement_sha256 = expected_placement,
            .adapter_nonce = adapter_nonce,
            .adapter_identity = adapter_identity,
            .dispatch_authority_sha256 = dispatch_authority_sha256,
            .queue_authority_sha256 = queue_authority_sha256,
        };
    }

    pub fn interface(
        self: *MetalAllocationAdapterV1,
    ) allocation.AdapterV1 {
        return .{
            .context = self,
            .authority = self.authority,
            .quote_fn = quoteCallback,
            .allocate_fn = allocateCallback,
            .free_fn = freeCallback,
        };
    }

    /// Bind a LeaseTree dispatch pin to this exact native adapter and its
    /// single serial Metal queue. The callback validates, but never clears,
    /// the private terminal authorization.
    pub fn dispatchInterface(
        self: *MetalAllocationAdapterV1,
    ) lease_tree.DispatchAdapterV1 {
        return .{
            .context = self,
            .dispatch_authority_sha256 = self.dispatch_authority_sha256,
            .queue_authority_sha256 = self.queue_authority_sha256,
            .validate_terminal_fn = validateDispatchTerminalCallback,
        };
    }

    pub fn quote(
        self: *MetalAllocationAdapterV1,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        return quoteCallback(
            self,
            binding_sha256,
            requested_bytes,
        );
    }

    /// Submit one synchronous INT4 matvec through the exact four allocations
    /// named by `roles`. The caller must first acquire `pin` from the
    /// LeaseTree coordinator using `dispatchInterface()`.
    ///
    /// Once native submission is attempted, any ambiguous backend error keeps
    /// the adapter blocked: no new dispatch or free is permitted because the
    /// queue may still reference the registered buffers. A successful call
    /// returns terminal evidence but keeps the same block until
    /// `acknowledgeDispatchCompletion()` validates the coordinator result.
    pub fn dispatchMatvecInt4Observed(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        roles: MetalMatvecAllocationBindingsV1,
        packed_weights: []const u8,
        scales: []const f32,
        input: []const f32,
        output: []f32,
        group_size: u32,
        in_features: u32,
        out_features: u32,
    ) Error!MetalLeaseTreeDispatchResultV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed)
            return Error.DispatchBusy;

        const geometry = try makeMatvecGeometryV1(
            group_size,
            in_features,
            out_features,
        );
        if (@as(u64, @intCast(packed_weights.len)) !=
            geometry.packed_bytes or
            @as(u64, @intCast(scales.len)) !=
                geometry.scale_count or
            @as(u64, @intCast(input.len)) !=
                geometry.input_count or
            @as(u64, @intCast(output.len)) !=
                geometry.output_count)
            return Error.InvalidDispatchEvidence;

        const selected = try self.validateDispatchSetUnlocked(
            lease,
            pin,
            roles,
            geometry,
        );
        const packed_input_sha256 =
            matvecPackedWeightsInputRootV1(packed_weights);
        const scales_input_sha256 =
            matvecScalesInputRootV1(scales);
        const vector_input_sha256 =
            matvecVectorInputRootV1(input);
        if (digestIsZero(packed_input_sha256) or
            digestIsZero(scales_input_sha256) or
            digestIsZero(vector_input_sha256))
            return Error.InvalidDispatchEvidence;

        var observation: MetalLeaseTreeDispatchObservationV1 = .{
            .dispatch_generation = pin.dispatch_generation,
            .allocation_count = pin.allocation_count,
            .materialized_bytes = pin.pinned_device_bytes,
            .authority_sha256 = pin.authority_sha256,
            .admission_sha256 = pin.admission_sha256,
            .lease_sha256 = pin.lease_sha256,
            .backend_object_set_sha256 = pin.backend_object_set_sha256,
            .pin_sha256 = pin.pin_sha256,
            .dispatch_request_sha256 = pin.dispatch_request_sha256,
            .dispatch_authority_sha256 = pin.dispatch_authority_sha256,
            .queue_authority_sha256 = pin.queue_authority_sha256,
            .geometry = geometry,
            .roles = selected.evidence,
            .packed_weights_input_sha256 = packed_input_sha256,
            .scales_input_sha256 = scales_input_sha256,
            .vector_input_sha256 = vector_input_sha256,
        };
        observation.submission_sha256 =
            dispatchSubmissionRootV1(observation);
        if (digestIsZero(observation.submission_sha256))
            return Error.InvalidDispatchEvidence;

        // From this point on, an error can no longer prove that native queue
        // ownership was never established. Leave the adapter blocked.
        self.dispatch_unresolved = true;
        const telemetry =
            try self.backend.matvecInt4RegisteredBuffersObserved(
                selected.tokens[0],
                selected.tokens[1],
                selected.tokens[2],
                selected.tokens[3],
                packed_weights,
                scales,
                input,
                output,
                group_size,
                in_features,
                out_features,
            );
        if (!device.digestEqual(
            packed_input_sha256,
            matvecPackedWeightsInputRootV1(packed_weights),
        ) or !device.digestEqual(
            scales_input_sha256,
            matvecScalesInputRootV1(scales),
        ) or !device.digestEqual(
            vector_input_sha256,
            matvecVectorInputRootV1(input),
        ))
            return Error.InvalidDispatchEvidence;

        observation.telemetry = telemetry;
        observation.telemetry_sha256 =
            dispatchTelemetryRootV1(telemetry);
        observation.backend_completion_sha256 =
            dispatchBackendCompletionRootV1(
                observation.submission_sha256,
                observation.telemetry_sha256,
            );
        observation.output_sha256 =
            matvecOutputRootV1(output);
        const terminal = lease_tree.makeDispatchTerminalV1(
            pin,
            .succeeded,
            observation.submission_sha256,
            observation.backend_completion_sha256,
            observation.output_sha256,
        ) catch return Error.InvalidDispatchEvidence;
        observation.terminal_sha256 =
            terminal.terminal_sha256;
        observation.observation_sha256 =
            metalDispatchObservationRootV1(observation);
        validateMetalLeaseTreeDispatchPayloadV1(
            observation,
            packed_weights,
            scales,
            input,
            output,
        ) catch return Error.InvalidDispatchEvidence;
        validateMetalLeaseTreeDispatchObservationForPinV1(
            observation,
            pin,
            terminal,
        ) catch return Error.InvalidDispatchEvidence;
        self.authorized_terminal = .{
            .pin = pin,
            .terminal = terminal,
            .observation = observation,
        };
        return .{
            .observation = observation,
            .terminal = terminal,
        };
    }

    /// Clear native queue ownership only after the coordinator has consumed
    /// the exact private Bank pin and returned its matching completion.
    pub fn acknowledgeDispatchCompletion(
        self: *MetalAllocationAdapterV1,
        completion: lease_tree.LeaseTreeDispatchCompletionV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const authorized = self.authorized_terminal orelse
            return Error.DispatchUnresolved;
        lease_tree.validateDispatchCompletionForPinV1(
            completion,
            authorized.pin,
            authorized.terminal,
        ) catch return Error.InvalidDispatchEvidence;
        validateMetalLeaseTreeDispatchObservationForPinV1(
            authorized.observation,
            authorized.pin,
            authorized.terminal,
        ) catch return Error.InvalidDispatchEvidence;
        if (!self.dispatch_unresolved or
            !self.terminal_validation_observed)
            return Error.InvalidDispatchEvidence;
        self.authorized_terminal = null;
        self.dispatch_unresolved = false;
        self.terminal_validation_observed = false;
    }

    pub fn snapshot(
        self: *MetalAllocationAdapterV1,
    ) MetalAllocationSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var live_objects: usize = 0;
        for (self.slots) |slot| if (slot.live) {
            live_objects += 1;
        };
        return .{
            .authority_epoch = self.authority.authority_epoch,
            .adapter_instance = self.adapter_identity.adapter_instance,
            .device_registry_id = self.limits.device_registry_id,
            .used_resource_bytes = self.used_resource_bytes,
            .observed_allocated_size_bytes = self.observed_allocated_size_bytes,
            .live_objects = live_objects,
            .materialized_leases = @intFromBool(
                !digestIsZero(self.active_admission_sha256),
            ),
            .allocate_calls = self.allocate_calls,
            .free_calls = self.free_calls,
            .inspect_calls = self.inspect_calls,
        };
    }

    /// Copy current per-object evidence in allocation-call ordinal order.
    /// The returned values contain no Objective-C pointer or GPU address.
    pub fn copyLiveObservations(
        self: *MetalAllocationAdapterV1,
        out: []MetalAllocationObservationV1,
    ) Error!usize {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();
        var live_count: usize = 0;
        for (self.slots) |slot| if (slot.live) {
            live_count += 1;
        };
        if (out.len < live_count) return Error.BufferTooSmall;
        var copied: usize = 0;
        for (0..allocation.maximum_allocations) |ordinal| {
            for (self.slots, 0..) |*slot, slot_index| {
                if (!slot.live or slot.call.ordinal != ordinal)
                    continue;
                if (slot.native_token.isZero())
                    return Error.InvalidObservation;
                const info = self.backend.inspectBufferAllocation(
                    slot.native_token,
                ) catch return Error.InvalidObservation;
                if (!std.meta.eql(info, slot.native_info))
                    return Error.InvalidObservation;
                out[copied] = makeObservationV1(
                    self.authority,
                    @intCast(slot_index),
                    slot.*,
                    info,
                );
                try validateObservationV1(
                    out[copied],
                    self.authority,
                    self.limits.device_registry_id,
                );
                copied += 1;
                self.inspect_calls +|= 1;
            }
        }
        if (copied != live_count) return Error.InvalidObservation;
        return copied;
    }

    fn validateDispatchSetUnlocked(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        bindings: MetalMatvecAllocationBindingsV1,
        geometry: MetalMatvecGeometryV1,
    ) Error!ValidatedMatvecDispatchSetV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try lease_tree.validateLeaseV1(lease);
        try lease_tree.validateDispatchPinV1(pin);
        try validateMatvecGeometryV1(geometry);
        try validateMatvecBindingsV1(bindings);
        if (lease.allocation_count != 4 or
            pin.allocation_count != 4 or
            !device.digestEqual(
                lease.authority_sha256,
                self.authority.authority_sha256,
            ) or !device.digestEqual(
            pin.authority_sha256,
            self.authority.authority_sha256,
        ) or lease.coordinator_epoch !=
            pin.coordinator_epoch or
            lease.generation != pin.allocation_generation or
            !device.digestEqual(
                lease.request_sha256,
                pin.request_sha256,
            ) or !device.digestEqual(
            lease.admission_sha256,
            pin.admission_sha256,
        ) or !device.digestEqual(
            lease.lease_sha256,
            pin.lease_sha256,
        ) or !device.digestEqual(
            lease.parent_receipt_sha256,
            pin.parent_receipt_sha256,
        ) or !device.digestEqual(
            lease.allocation_leaf_set_sha256,
            pin.allocation_leaf_set_sha256,
        ) or !device.digestEqual(
            lease.backend_object_set_sha256,
            pin.backend_object_set_sha256,
        ) or lease.materialized_bytes !=
            pin.pinned_device_bytes or
            !std.meta.eql(lease.scope, pin.scope) or
            lease.materialized_tree.tree_key !=
                pin.pinned_tree.tree_key or
            lease.materialized_tree.identity_generation !=
                pin.pinned_tree.identity_generation or
            !std.meta.eql(
                lease.materialized_tree.parent,
                pin.pinned_tree.parent,
            ) or !device.digestEqual(
            pin.dispatch_authority_sha256,
            self.dispatch_authority_sha256,
        ) or !device.digestEqual(
            pin.queue_authority_sha256,
            self.queue_authority_sha256,
        ))
            return Error.InvalidDispatchEvidence;
        const fresh_limits = try self.backend.allocationLimits();
        const fresh_device_info = try self.backend.deviceInfo();
        try self.backend.requireInt4MatvecSupport();
        if (!std.meta.eql(fresh_limits, self.limits) or
            !device.digestEqual(
                native.deviceIdentityV1(fresh_device_info),
                self.device_sha256,
            ) or !device.digestEqual(
            native.placementIdentityV1(fresh_device_info),
            self.placement_sha256,
        ))
            return Error.InvalidDispatchEvidence;

        var calls: [allocation.maximum_allocations]allocation.AllocationCallV1 = undefined;
        var objects: [allocation.maximum_allocations]allocation.BackendObjectV1 = undefined;
        var seen =
            [_]bool{false} ** allocation.maximum_allocations;
        var live_count: u64 = 0;
        var live_bytes: u64 = 0;
        for (self.slots, 0..) |slot, slot_index| {
            if (!slot.live) {
                if (!std.meta.eql(
                    slot,
                    MetalAllocationSlotV1{},
                ))
                    return Error.InvalidDispatchEvidence;
                continue;
            }
            try allocation.validateAllocationCallV1(slot.call);
            try allocation.validateBackendObjectV1(
                slot.object,
                slot.call,
            );
            if (slot.native_token.isZero() or
                slot.generation == 0 or
                slot.generation !=
                    slot.object.backend_object_generation or
                slot.call.ordinal >= lease.allocation_count or
                !std.mem.eql(
                    u64,
                    &slot.native_token.context_nonce,
                    &self.adapter_identity.context_nonce,
                ) or !device.digestEqual(
                slot.object.backend_object_sha256,
                objectIdentityV1(
                    self.authority,
                    self.limits.device_registry_id,
                    @intCast(slot_index),
                    slot.generation,
                    slot.call.call_sha256,
                ),
            ) or
                !device.digestEqual(
                    slot.call.authority_sha256,
                    self.authority.authority_sha256,
                ) or !device.digestEqual(
                slot.call.admission_sha256,
                lease.admission_sha256,
            ))
                return Error.InvalidDispatchEvidence;
            const ordinal: usize =
                @intCast(slot.call.ordinal);
            if (seen[ordinal])
                return Error.InvalidDispatchEvidence;
            const fresh_info =
                try self.backend.inspectBufferAllocation(
                    slot.native_token,
                );
            if (!std.meta.eql(fresh_info, slot.native_info) or
                fresh_info.device_registry_id !=
                    self.limits.device_registry_id or
                fresh_info.resource_length !=
                    slot.object.allocated_bytes)
                return Error.InvalidDispatchEvidence;
            seen[ordinal] = true;
            calls[ordinal] = slot.call;
            objects[ordinal] = slot.object;
            live_count += 1;
            live_bytes = std.math.add(
                u64,
                live_bytes,
                slot.object.allocated_bytes,
            ) catch return Error.InvalidDispatchEvidence;
        }
        if (live_count != lease.allocation_count or
            live_bytes != lease.materialized_bytes or
            live_bytes != self.used_resource_bytes or
            !device.digestEqual(
                self.active_admission_sha256,
                lease.admission_sha256,
            ))
            return Error.InvalidDispatchEvidence;
        for (seen[0..@intCast(live_count)]) |present| {
            if (!present)
                return Error.InvalidDispatchEvidence;
        }
        const object_set =
            try allocation.makeObjectSetForAdmissionRootV1(
                lease.admission_sha256,
                self.authority.authority_sha256,
                lease.allocation_count,
                lease.materialized_bytes,
                calls[0..@intCast(live_count)],
                objects[0..@intCast(live_count)],
            );
        if (!device.digestEqual(
            object_set.object_set_sha256,
            lease.backend_object_set_sha256,
        ))
            return Error.InvalidDispatchEvidence;

        const role_bindings = [_]Digest{
            bindings.packed_weights_sha256,
            bindings.scales_sha256,
            bindings.input_sha256,
            bindings.output_sha256,
        };
        const expected_lengths = [_]u64{
            geometry.packed_bytes,
            geometry.scales_bytes,
            geometry.input_bytes,
            geometry.output_bytes,
        };
        var tokens: [4]metal.MetalBufferToken = undefined;
        var role_objects: [4]Digest = undefined;
        for (
            role_bindings,
            expected_lengths,
            0..,
        ) |binding_sha256, expected_length, role_index| {
            var found: ?usize = null;
            for (self.slots, 0..) |slot, slot_index| {
                if (slot.live and device.digestEqual(
                    slot.call.binding_sha256,
                    binding_sha256,
                )) {
                    if (found != null)
                        return Error.InvalidDispatchEvidence;
                    found = slot_index;
                }
            }
            const slot = self.slots[
                found orelse
                    return Error.InvalidDispatchEvidence
            ];
            if (slot.call.requested_bytes != expected_length or
                slot.call.charged_bytes != expected_length or
                slot.object.allocated_bytes != expected_length or
                slot.native_info.resource_length != expected_length)
                return Error.InvalidDispatchEvidence;
            tokens[role_index] = slot.native_token;
            role_objects[role_index] = slot.object.object_sha256;
        }
        for (tokens, 0..) |token, index| {
            for (tokens[0..index]) |prior| {
                if (std.meta.eql(token, prior))
                    return Error.InvalidDispatchEvidence;
            }
        }
        var evidence: MetalMatvecRoleEvidenceV1 = .{
            .bindings = bindings,
            .packed_weights_object_sha256 = role_objects[0],
            .scales_object_sha256 = role_objects[1],
            .input_object_sha256 = role_objects[2],
            .output_object_sha256 = role_objects[3],
        };
        evidence.roles_sha256 =
            matvecRoleEvidenceRootV1(evidence);
        try validateMatvecRoleEvidenceV1(evidence);
        return .{
            .tokens = tokens,
            .evidence = evidence,
        };
    }

    pub fn validateEmpty(
        self: *MetalAllocationAdapterV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.used_resource_bytes != 0 or
            self.observed_allocated_size_bytes != 0 or
            !digestIsZero(self.active_admission_sha256) or
            self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed)
            return Error.InvalidConfiguration;
        for (self.slots) |slot| if (slot.live or
            !slot.native_token.isZero())
            return Error.InvalidConfiguration;
    }

    fn validateDispatchTerminalCallback(
        context: *anyopaque,
        terminal: lease_tree.DispatchTerminalEvidenceV1,
    ) lease_tree.DispatchCallbackError!void {
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        const authorized = self.authorized_terminal orelse
            return lease_tree.DispatchCallbackError
                .InvalidTerminalEvidence;
        if (!self.dispatch_unresolved or
            !std.meta.eql(terminal, authorized.terminal))
            return lease_tree.DispatchCallbackError
                .InvalidTerminalEvidence;
        validateMetalLeaseTreeDispatchObservationForPinV1(
            authorized.observation,
            authorized.pin,
            terminal,
        ) catch return lease_tree.DispatchCallbackError
            .InvalidTerminalEvidence;
        self.terminal_validation_observed = true;
    }

    fn quoteCallback(
        context: *anyopaque,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.quoteUnlocked(
            binding_sha256,
            requested_bytes,
        );
    }

    fn quoteUnlocked(
        self: *MetalAllocationAdapterV1,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        if (digestIsZero(binding_sha256) or
            requested_bytes == 0)
            return allocation.CallbackError.InvalidRequest;
        if (requested_bytes >
            self.authority.max_single_allocation_bytes or
            requested_bytes > self.limits.max_buffer_length)
            return allocation.CallbackError.CapacityExceeded;
        // Direct MTLBuffer.length is the exact requested byte count. Physical
        // occupied size is observed only after allocation and is not charged
        // through this V1 logical-resource contract.
        return allocation.makeQuoteV1(
            self.authority,
            binding_sha256,
            requested_bytes,
            requested_bytes,
        ) catch return allocation.CallbackError.InvalidRequest;
    }

    fn allocateCallback(
        context: *anyopaque,
        call: allocation.AllocationCallV1,
    ) allocation.CallbackError!allocation.BackendObjectV1 {
        if (comptime !metal_enabled)
            return allocation.CallbackError.Unavailable;
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed)
            return allocation.CallbackError.Unavailable;
        allocation.validateAllocationCallV1(call) catch
            return allocation.CallbackError.InvalidRequest;
        if (!device.digestEqual(
            call.authority_sha256,
            self.authority.authority_sha256,
        )) return allocation.CallbackError.InvalidRequest;
        const replayed_quote = try self.quoteUnlocked(
            call.binding_sha256,
            call.requested_bytes,
        );
        if (call.charged_bytes != replayed_quote.charged_bytes or
            !device.digestEqual(
                call.quote_sha256,
                replayed_quote.quote_sha256,
            ))
            return allocation.CallbackError.InvalidRequest;
        if (!digestIsZero(self.active_admission_sha256) and
            !device.digestEqual(
                self.active_admission_sha256,
                call.admission_sha256,
            ))
            return allocation.CallbackError.CapacityExceeded;
        for (self.slots) |slot| {
            if (slot.live and
                device.digestEqual(
                    slot.call.admission_sha256,
                    call.admission_sha256,
                ) and slot.call.ordinal == call.ordinal)
                return allocation.CallbackError.StaleObject;
        }
        const fresh_limits = self.backend.allocationLimits() catch
            return allocation.CallbackError.Unavailable;
        const fresh_info = self.backend.deviceInfo() catch
            return allocation.CallbackError.Unavailable;
        self.backend.requireInt4MatvecSupport() catch
            return allocation.CallbackError.Unavailable;
        if (!std.meta.eql(fresh_limits, self.limits) or
            !device.digestEqual(
                native.deviceIdentityV1(fresh_info),
                self.device_sha256,
            ) or
            !device.digestEqual(
                native.placementIdentityV1(fresh_info),
                self.placement_sha256,
            ))
            return allocation.CallbackError.Unavailable;
        const next_used = std.math.add(
            u64,
            self.used_resource_bytes,
            call.charged_bytes,
        ) catch return allocation.CallbackError.CapacityExceeded;
        if (next_used > self.authority.max_total_device_bytes)
            return allocation.CallbackError.CapacityExceeded;
        var free_slot: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (!slot.live and slot.native_token.isZero()) {
                free_slot = index;
                break;
            }
        }
        const slot_index = free_slot orelse
            return allocation.CallbackError.CapacityExceeded;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return allocation.CallbackError.Unavailable;

        self.allocate_calls +|= 1;
        const native_token = self.backend.createBufferAllocation(
            call.requested_bytes,
        ) catch return allocation.CallbackError.CapacityExceeded;
        errdefer self.backend.destroyBufferAllocation(
            native_token,
        ) catch @panic(
            "Metal adapter could not roll back a fresh native token",
        );
        const native_info = self.backend.inspectBufferAllocation(
            native_token,
        ) catch return allocation.CallbackError.Unavailable;
        if (native_info.device_registry_id !=
            self.limits.device_registry_id or
            native_info.requested_length != call.requested_bytes or
            native_info.resource_length != call.charged_bytes)
            return allocation.CallbackError.InvalidRequest;
        const next_observed = std.math.add(
            u64,
            self.observed_allocated_size_bytes,
            native_info.allocated_size,
        ) catch return allocation.CallbackError.CapacityExceeded;

        const generation = self.next_generation;
        const identity = objectIdentityV1(
            self.authority,
            self.limits.device_registry_id,
            @intCast(slot_index),
            generation,
            call.call_sha256,
        );
        var object: allocation.BackendObjectV1 = .{
            .allocation_call_sha256 = call.call_sha256,
            .binding_sha256 = call.binding_sha256,
            .backend_object_sha256 = identity,
            .backend_object_generation = generation,
            .allocated_bytes = native_info.resource_length,
        };
        object.object_sha256 =
            allocation.backendObjectRootV1(object);
        allocation.validateBackendObjectV1(object, call) catch
            return allocation.CallbackError.InvalidRequest;

        self.slots[slot_index] = .{
            .live = true,
            .generation = generation,
            .call = call,
            .object = object,
            .native_token = native_token,
            .native_info = native_info,
        };
        self.next_generation += 1;
        self.used_resource_bytes = next_used;
        self.observed_allocated_size_bytes = next_observed;
        self.active_admission_sha256 = call.admission_sha256;
        return object;
    }

    fn freeCallback(
        context: *anyopaque,
        object: allocation.BackendObjectV1,
    ) allocation.CallbackError!void {
        if (comptime !metal_enabled)
            return allocation.CallbackError.Unavailable;
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        // Core completion releases the Bank pin before the caller can return
        // it here for acknowledgement. Retain native ownership across that
        // narrow handoff so a premature LeaseTree release cannot free a
        // command buffer's exact registered resources.
        if (self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed)
            return allocation.CallbackError.Unavailable;
        self.free_calls +|= 1;

        var found: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (slot.live and
                slot.generation ==
                    object.backend_object_generation and
                std.meta.eql(slot.object, object))
            {
                found = index;
                break;
            }
        }
        const index = found orelse
            return allocation.CallbackError.StaleObject;
        const slot = &self.slots[index];
        allocation.validateBackendObjectV1(
            object,
            slot.call,
        ) catch return allocation.CallbackError.InvalidRequest;
        const native_token = slot.native_token;
        if (native_token.isZero())
            return allocation.CallbackError.Unavailable;
        const inspected = self.backend.inspectBufferAllocation(
            native_token,
        ) catch return allocation.CallbackError.Unavailable;
        if (!std.meta.eql(inspected, slot.native_info))
            return allocation.CallbackError.Unavailable;

        // Objective-C strong-reference release is synchronous and non-failing.
        // This proves adapter ownership relinquishment, not driver reclamation
        // or physical residency change.
        self.backend.destroyBufferAllocation(native_token) catch
            return allocation.CallbackError.Unavailable;
        self.used_resource_bytes -= slot.call.charged_bytes;
        self.observed_allocated_size_bytes -=
            slot.native_info.allocated_size;
        slot.* = .{};
        var any_live = false;
        for (self.slots) |candidate| if (candidate.live) {
            any_live = true;
            break;
        };
        if (!any_live)
            self.active_admission_sha256 = allocation.zero_digest;
    }
};

pub fn makeMatvecGeometryV1(
    group_size: u32,
    in_features: u32,
    out_features: u32,
) Error!MetalMatvecGeometryV1 {
    if (group_size == 0 or
        !std.math.isPowerOfTwo(group_size) or
        in_features == 0 or out_features == 0)
        return Error.InvalidDispatchEvidence;
    const elements =
        @as(u64, in_features) * @as(u64, out_features);
    if (elements > std.math.maxInt(u32))
        return Error.InvalidDispatchEvidence;
    const scale_count =
        (elements + @as(u64, group_size) - 1) /
        @as(u64, group_size);
    var result: MetalMatvecGeometryV1 = .{
        .group_size = group_size,
        .in_features = in_features,
        .out_features = out_features,
        .packed_bytes = (elements + 1) / 2,
        .scale_count = scale_count,
        .scales_bytes = scale_count * @sizeOf(f32),
        .input_count = in_features,
        .input_bytes = @as(u64, in_features) * @sizeOf(f32),
        .output_count = out_features,
        .output_bytes = @as(u64, out_features) * @sizeOf(f32),
    };
    result.geometry_sha256 = matvecGeometryRootV1(result);
    try validateMatvecGeometryV1(result);
    return result;
}

pub fn validateMatvecGeometryV1(
    geometry: MetalMatvecGeometryV1,
) Error!void {
    if (geometry.group_size == 0 or
        !std.math.isPowerOfTwo(geometry.group_size) or
        geometry.in_features == 0 or
        geometry.out_features == 0 or
        geometry.reserved != 0)
        return Error.InvalidDispatchEvidence;
    const elements =
        @as(u64, geometry.in_features) *
        @as(u64, geometry.out_features);
    if (elements > std.math.maxInt(u32))
        return Error.InvalidDispatchEvidence;
    const scale_count =
        (elements + @as(u64, geometry.group_size) - 1) /
        @as(u64, geometry.group_size);
    if (geometry.packed_bytes != (elements + 1) / 2 or
        geometry.scale_count != scale_count or
        geometry.scales_bytes !=
            scale_count * @sizeOf(f32) or
        geometry.input_count != geometry.in_features or
        geometry.input_bytes !=
            @as(u64, geometry.in_features) *
                @sizeOf(f32) or
        geometry.output_count != geometry.out_features or
        geometry.output_bytes !=
            @as(u64, geometry.out_features) *
                @sizeOf(f32) or
        digestIsZero(geometry.geometry_sha256) or
        !device.digestEqual(
            geometry.geometry_sha256,
            matvecGeometryRootV1(geometry),
        ))
        return Error.InvalidDispatchEvidence;
}

pub fn matvecGeometryRootV1(
    geometry: MetalMatvecGeometryV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_geometry_domain);
    hashU64(&hash, dispatch_observation_abi);
    hashU64(&hash, geometry.group_size);
    hashU64(&hash, geometry.in_features);
    hashU64(&hash, geometry.out_features);
    hashU64(&hash, geometry.reserved);
    hashU64(&hash, geometry.packed_bytes);
    hashU64(&hash, geometry.scale_count);
    hashU64(&hash, geometry.scales_bytes);
    hashU64(&hash, geometry.input_count);
    hashU64(&hash, geometry.input_bytes);
    hashU64(&hash, geometry.output_count);
    hashU64(&hash, geometry.output_bytes);
    return finish(&hash);
}

pub fn validateMatvecBindingsV1(
    bindings: MetalMatvecAllocationBindingsV1,
) Error!void {
    const values = [_]Digest{
        bindings.packed_weights_sha256,
        bindings.scales_sha256,
        bindings.input_sha256,
        bindings.output_sha256,
    };
    for (values, 0..) |value, index| {
        if (digestIsZero(value))
            return Error.InvalidDispatchEvidence;
        for (values[0..index]) |prior| {
            if (device.digestEqual(value, prior))
                return Error.InvalidDispatchEvidence;
        }
    }
}

pub fn validateMatvecRoleEvidenceV1(
    evidence: MetalMatvecRoleEvidenceV1,
) Error!void {
    try validateMatvecBindingsV1(evidence.bindings);
    const object_roots = [_]Digest{
        evidence.packed_weights_object_sha256,
        evidence.scales_object_sha256,
        evidence.input_object_sha256,
        evidence.output_object_sha256,
    };
    for (object_roots, 0..) |value, index| {
        if (digestIsZero(value))
            return Error.InvalidDispatchEvidence;
        for (object_roots[0..index]) |prior| {
            if (device.digestEqual(value, prior))
                return Error.InvalidDispatchEvidence;
        }
    }
    if (digestIsZero(evidence.roles_sha256) or
        !device.digestEqual(
            evidence.roles_sha256,
            matvecRoleEvidenceRootV1(evidence),
        ))
        return Error.InvalidDispatchEvidence;
}

pub fn matvecRoleEvidenceRootV1(
    evidence: MetalMatvecRoleEvidenceV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_roles_domain);
    hashU64(&hash, dispatch_observation_abi);
    hash.update(&evidence.bindings.packed_weights_sha256);
    hash.update(&evidence.bindings.scales_sha256);
    hash.update(&evidence.bindings.input_sha256);
    hash.update(&evidence.bindings.output_sha256);
    hash.update(&evidence.packed_weights_object_sha256);
    hash.update(&evidence.scales_object_sha256);
    hash.update(&evidence.input_object_sha256);
    hash.update(&evidence.output_object_sha256);
    return finish(&hash);
}

pub fn matvecPackedWeightsInputRootV1(
    packed_weights: []const u8,
) Digest {
    return hashByteSliceV1(
        dispatch_packed_input_domain,
        packed_weights,
    );
}

pub fn matvecScalesInputRootV1(
    scales: []const f32,
) Digest {
    return hashF32SliceV1(
        dispatch_scales_input_domain,
        scales,
    );
}

pub fn matvecVectorInputRootV1(
    input: []const f32,
) Digest {
    return hashF32SliceV1(
        dispatch_vector_input_domain,
        input,
    );
}

pub fn matvecOutputRootV1(
    output: []const f32,
) Digest {
    return hashF32SliceV1(
        dispatch_output_domain,
        output,
    );
}

pub fn validateMetalDispatchTelemetryV1(
    telemetry: metal.MetalDispatchTelemetry,
) Error!void {
    const gpu_start: f64 =
        @bitCast(telemetry.gpu_start_time_bits);
    const gpu_end: f64 =
        @bitCast(telemetry.gpu_end_time_bits);
    if (telemetry.current_allocated_before == 0 or
        telemetry.current_allocated_after == 0 or
        !std.math.isFinite(gpu_start) or
        !std.math.isFinite(gpu_end) or
        gpu_start <= 0 or gpu_end <= gpu_start or
        telemetry.gpu_duration_nanoseconds == 0 or
        telemetry.command_status !=
            completed_command_buffer_status)
        return Error.InvalidDispatchEvidence;
    const duration_nanoseconds =
        (gpu_end - gpu_start) * 1_000_000_000.0;
    if (!std.math.isFinite(duration_nanoseconds) or
        duration_nanoseconds < 1 or
        duration_nanoseconds >=
            @as(f64, @floatFromInt(std.math.maxInt(u64))) or
        telemetry.gpu_duration_nanoseconds !=
            @as(u64, @intFromFloat(duration_nanoseconds)))
        return Error.InvalidDispatchEvidence;
}

pub fn dispatchTelemetryRootV1(
    telemetry: metal.MetalDispatchTelemetry,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_telemetry_domain);
    hashU64(&hash, dispatch_observation_abi);
    hashU64(&hash, telemetry.current_allocated_before);
    hashU64(&hash, telemetry.current_allocated_after);
    hashU64(&hash, telemetry.gpu_start_time_bits);
    hashU64(&hash, telemetry.gpu_end_time_bits);
    hashU64(&hash, telemetry.gpu_duration_nanoseconds);
    hashU64(&hash, telemetry.command_status);
    return finish(&hash);
}

pub fn dispatchSubmissionRootV1(
    observation: MetalLeaseTreeDispatchObservationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_submission_domain);
    hashU64(&hash, observation.abi_version);
    hashU64(&hash, observation.dispatch_generation);
    hashU64(&hash, observation.allocation_count);
    hashU64(&hash, observation.materialized_bytes);
    hash.update(&observation.authority_sha256);
    hash.update(&observation.admission_sha256);
    hash.update(&observation.lease_sha256);
    hash.update(&observation.backend_object_set_sha256);
    hash.update(&observation.pin_sha256);
    hash.update(&observation.dispatch_request_sha256);
    hash.update(&observation.dispatch_authority_sha256);
    hash.update(&observation.queue_authority_sha256);
    hash.update(&observation.geometry.geometry_sha256);
    hash.update(&observation.roles.roles_sha256);
    hash.update(&observation.packed_weights_input_sha256);
    hash.update(&observation.scales_input_sha256);
    hash.update(&observation.vector_input_sha256);
    return finish(&hash);
}

pub fn dispatchBackendCompletionRootV1(
    submission_sha256: Digest,
    telemetry_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_backend_completion_domain);
    hashU64(&hash, dispatch_observation_abi);
    hash.update(&submission_sha256);
    hash.update(&telemetry_sha256);
    return finish(&hash);
}

pub fn metalDispatchObservationRootV1(
    observation: MetalLeaseTreeDispatchObservationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_observation_domain);
    hashU64(&hash, observation.abi_version);
    hashU64(&hash, @intFromEnum(observation.outcome));
    hashU64(&hash, observation.dispatch_generation);
    hashU64(&hash, observation.allocation_count);
    hashU64(&hash, observation.materialized_bytes);
    hash.update(&observation.authority_sha256);
    hash.update(&observation.admission_sha256);
    hash.update(&observation.lease_sha256);
    hash.update(&observation.backend_object_set_sha256);
    hash.update(&observation.pin_sha256);
    hash.update(&observation.dispatch_request_sha256);
    hash.update(&observation.dispatch_authority_sha256);
    hash.update(&observation.queue_authority_sha256);
    hash.update(&observation.geometry.geometry_sha256);
    hash.update(&observation.roles.roles_sha256);
    hash.update(&observation.packed_weights_input_sha256);
    hash.update(&observation.scales_input_sha256);
    hash.update(&observation.vector_input_sha256);
    hash.update(&observation.submission_sha256);
    hash.update(&observation.telemetry_sha256);
    hash.update(&observation.backend_completion_sha256);
    hash.update(&observation.output_sha256);
    hash.update(&observation.terminal_sha256);
    return finish(&hash);
}

pub fn validateMetalLeaseTreeDispatchObservationV1(
    observation: MetalLeaseTreeDispatchObservationV1,
) Error!void {
    try validateMatvecGeometryV1(observation.geometry);
    try validateMatvecRoleEvidenceV1(observation.roles);
    try validateMetalDispatchTelemetryV1(
        observation.telemetry,
    );
    const exact_bytes = std.math.add(
        u64,
        observation.geometry.packed_bytes,
        observation.geometry.scales_bytes,
    ) catch return Error.InvalidDispatchEvidence;
    const exact_with_input = std.math.add(
        u64,
        exact_bytes,
        observation.geometry.input_bytes,
    ) catch return Error.InvalidDispatchEvidence;
    const total_bytes = std.math.add(
        u64,
        exact_with_input,
        observation.geometry.output_bytes,
    ) catch return Error.InvalidDispatchEvidence;
    if (observation.abi_version !=
        dispatch_observation_abi or
        observation.outcome != .succeeded or
        observation.dispatch_generation == 0 or
        observation.allocation_count != 4 or
        observation.materialized_bytes != total_bytes or
        digestIsZero(observation.authority_sha256) or
        digestIsZero(observation.admission_sha256) or
        digestIsZero(observation.lease_sha256) or
        digestIsZero(
            observation.backend_object_set_sha256,
        ) or digestIsZero(observation.pin_sha256) or
        digestIsZero(observation.dispatch_request_sha256) or
        digestIsZero(
            observation.dispatch_authority_sha256,
        ) or digestIsZero(
        observation.queue_authority_sha256,
    ) or device.digestEqual(
        observation.dispatch_authority_sha256,
        observation.queue_authority_sha256,
    ) or digestIsZero(
        observation.packed_weights_input_sha256,
    ) or digestIsZero(
        observation.scales_input_sha256,
    ) or digestIsZero(
        observation.vector_input_sha256,
    ) or digestIsZero(observation.submission_sha256) or
        !device.digestEqual(
            observation.submission_sha256,
            dispatchSubmissionRootV1(observation),
        ) or digestIsZero(observation.telemetry_sha256) or
        !device.digestEqual(
            observation.telemetry_sha256,
            dispatchTelemetryRootV1(observation.telemetry),
        ) or digestIsZero(
        observation.backend_completion_sha256,
    ) or !device.digestEqual(
        observation.backend_completion_sha256,
        dispatchBackendCompletionRootV1(
            observation.submission_sha256,
            observation.telemetry_sha256,
        ),
    ) or digestIsZero(observation.output_sha256) or
        digestIsZero(observation.terminal_sha256) or
        digestIsZero(observation.observation_sha256) or
        !device.digestEqual(
            observation.observation_sha256,
            metalDispatchObservationRootV1(observation),
        ))
        return Error.InvalidDispatchEvidence;
    var terminal: lease_tree.DispatchTerminalEvidenceV1 = .{
        .outcome = observation.outcome,
        .dispatch_generation = observation.dispatch_generation,
        .dispatch_authority_sha256 = observation.dispatch_authority_sha256,
        .queue_authority_sha256 = observation.queue_authority_sha256,
        .pin_sha256 = observation.pin_sha256,
        .dispatch_request_sha256 = observation.dispatch_request_sha256,
        .submission_sha256 = observation.submission_sha256,
        .backend_completion_sha256 = observation.backend_completion_sha256,
        .output_sha256 = observation.output_sha256,
    };
    terminal.terminal_sha256 =
        lease_tree.dispatchTerminalRootV1(terminal);
    lease_tree.validateDispatchTerminalV1(terminal) catch
        return Error.InvalidDispatchEvidence;
    if (!device.digestEqual(
        terminal.terminal_sha256,
        observation.terminal_sha256,
    ))
        return Error.InvalidDispatchEvidence;
}

pub fn validateMetalLeaseTreeDispatchPayloadV1(
    observation: MetalLeaseTreeDispatchObservationV1,
    packed_weights: []const u8,
    scales: []const f32,
    input: []const f32,
    output: []const f32,
) Error!void {
    try validateMetalLeaseTreeDispatchObservationV1(
        observation,
    );
    if (@as(u64, @intCast(packed_weights.len)) !=
        observation.geometry.packed_bytes or
        @as(u64, @intCast(scales.len)) !=
            observation.geometry.scale_count or
        @as(u64, @intCast(input.len)) !=
            observation.geometry.input_count or
        @as(u64, @intCast(output.len)) !=
            observation.geometry.output_count or
        !device.digestEqual(
            observation.packed_weights_input_sha256,
            matvecPackedWeightsInputRootV1(packed_weights),
        ) or !device.digestEqual(
        observation.scales_input_sha256,
        matvecScalesInputRootV1(scales),
    ) or !device.digestEqual(
        observation.vector_input_sha256,
        matvecVectorInputRootV1(input),
    ) or !device.digestEqual(
        observation.output_sha256,
        matvecOutputRootV1(output),
    ))
        return Error.InvalidDispatchEvidence;
}

pub fn validateMetalLeaseTreeDispatchObservationForPinV1(
    observation: MetalLeaseTreeDispatchObservationV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
) Error!void {
    try validateMetalLeaseTreeDispatchObservationV1(
        observation,
    );
    lease_tree.validateDispatchTerminalForPinV1(
        terminal,
        pin,
    ) catch return Error.InvalidDispatchEvidence;
    if (terminal.outcome != observation.outcome or
        terminal.dispatch_generation !=
            observation.dispatch_generation or
        pin.allocation_count != observation.allocation_count or
        pin.pinned_device_bytes !=
            observation.materialized_bytes or
        !device.digestEqual(
            pin.authority_sha256,
            observation.authority_sha256,
        ) or !device.digestEqual(
        pin.admission_sha256,
        observation.admission_sha256,
    ) or !device.digestEqual(
        pin.lease_sha256,
        observation.lease_sha256,
    ) or !device.digestEqual(
        pin.backend_object_set_sha256,
        observation.backend_object_set_sha256,
    ) or !device.digestEqual(
        terminal.pin_sha256,
        observation.pin_sha256,
    ) or !device.digestEqual(
        terminal.dispatch_request_sha256,
        observation.dispatch_request_sha256,
    ) or !device.digestEqual(
        terminal.dispatch_authority_sha256,
        observation.dispatch_authority_sha256,
    ) or !device.digestEqual(
        terminal.queue_authority_sha256,
        observation.queue_authority_sha256,
    ) or !device.digestEqual(
        terminal.submission_sha256,
        observation.submission_sha256,
    ) or !device.digestEqual(
        terminal.backend_completion_sha256,
        observation.backend_completion_sha256,
    ) or !device.digestEqual(
        terminal.output_sha256,
        observation.output_sha256,
    ) or !device.digestEqual(
        terminal.terminal_sha256,
        observation.terminal_sha256,
    ))
        return Error.InvalidDispatchEvidence;
}

pub fn observationRootV1(
    value: MetalAllocationObservationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(observation_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.authority_sha256);
    hash.update(&value.admission_sha256);
    hash.update(&value.allocation_call_sha256);
    hash.update(&value.binding_sha256);
    hash.update(&value.backend_object_sha256);
    hash.update(&value.object_sha256);
    hashU64(&hash, value.adapter_slot_index);
    hashU64(&hash, value.reserved);
    hashU64(&hash, value.backend_object_generation);
    hashU64(&hash, value.ordinal);
    hashU64(&hash, value.device_registry_id);
    hashU64(&hash, value.requested_bytes);
    hashU64(&hash, value.charged_resource_bytes);
    hashU64(&hash, value.buffer_length_bytes);
    hashU64(&hash, value.resource_allocated_size_bytes);
    hashU64(&hash, value.storage_mode);
    hashU64(&hash, value.cpu_cache_mode);
    return finish(&hash);
}

pub fn validateObservationV1(
    value: MetalAllocationObservationV1,
    authority: allocation.AllocationAuthorityV1,
    expected_device_registry_id: u64,
) Error!void {
    allocation.validateAuthorityV1(authority) catch
        return Error.InvalidObservation;
    const reconstructed_object: allocation.BackendObjectV1 = .{
        .allocation_call_sha256 = value.allocation_call_sha256,
        .binding_sha256 = value.binding_sha256,
        .backend_object_sha256 = value.backend_object_sha256,
        .backend_object_generation = value.backend_object_generation,
        .allocated_bytes = value.charged_resource_bytes,
        .object_sha256 = value.object_sha256,
    };
    if (value.abi_version != observation_abi or
        value.reserved != 0 or
        !device.digestEqual(
            value.authority_sha256,
            authority.authority_sha256,
        ) or
        digestIsZero(value.admission_sha256) or
        digestIsZero(value.allocation_call_sha256) or
        digestIsZero(value.binding_sha256) or
        digestIsZero(value.backend_object_sha256) or
        digestIsZero(value.object_sha256) or
        value.adapter_slot_index >=
            authority.maximum_live_objects or
        value.backend_object_generation == 0 or
        value.ordinal >= authority.maximum_live_objects or
        expected_device_registry_id == 0 or
        value.device_registry_id != expected_device_registry_id or
        value.requested_bytes == 0 or
        value.requested_bytes >
            authority.max_single_allocation_bytes or
        value.charged_resource_bytes >
            authority.max_single_allocation_bytes or
        value.charged_resource_bytes >
            authority.max_total_device_bytes or
        value.charged_resource_bytes != value.requested_bytes or
        value.buffer_length_bytes !=
            value.charged_resource_bytes or
        value.resource_allocated_size_bytes <
            value.buffer_length_bytes or
        value.storage_mode != metal.shared_storage_mode or
        value.cpu_cache_mode != metal.default_cpu_cache_mode or
        !device.digestEqual(
            value.backend_object_sha256,
            objectIdentityV1(
                authority,
                expected_device_registry_id,
                value.adapter_slot_index,
                value.backend_object_generation,
                value.allocation_call_sha256,
            ),
        ) or
        !device.digestEqual(
            value.object_sha256,
            allocation.backendObjectRootV1(
                reconstructed_object,
            ),
        ) or
        digestIsZero(value.observation_sha256) or
        !device.digestEqual(
            value.observation_sha256,
            observationRootV1(value),
        ))
        return Error.InvalidObservation;
}

fn makeObservationV1(
    authority: allocation.AllocationAuthorityV1,
    slot_index: u32,
    slot: MetalAllocationSlotV1,
    info: metal.MetalBufferInfo,
) MetalAllocationObservationV1 {
    var result: MetalAllocationObservationV1 = .{
        .authority_sha256 = authority.authority_sha256,
        .admission_sha256 = slot.call.admission_sha256,
        .allocation_call_sha256 = slot.call.call_sha256,
        .binding_sha256 = slot.call.binding_sha256,
        .backend_object_sha256 = slot.object.backend_object_sha256,
        .object_sha256 = slot.object.object_sha256,
        .adapter_slot_index = slot_index,
        .backend_object_generation = slot.generation,
        .ordinal = slot.call.ordinal,
        .device_registry_id = info.device_registry_id,
        .requested_bytes = slot.call.requested_bytes,
        .charged_resource_bytes = slot.call.charged_bytes,
        .buffer_length_bytes = info.resource_length,
        .resource_allocated_size_bytes = info.allocated_size,
        .storage_mode = info.storage_mode,
        .cpu_cache_mode = info.cpu_cache_mode,
    };
    result.observation_sha256 = observationRootV1(result);
    return result;
}

fn backendAuthorityRootV1(
    authority_epoch: u64,
    adapter_nonce: u64,
    adapter_identity: metal.MetalAllocationAdapterIdentity,
    selected: device.DeviceInventoryEntryV1,
    limits: metal.MetalAllocationLimits,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(authority_domain);
    hashU64(&hash, adapter_abi);
    hashU64(&hash, authority_epoch);
    hashU64(&hash, adapter_nonce);
    hashU64(&hash, adapter_identity.abi_version);
    for (adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter_identity.adapter_instance);
    hash.update(&selected.capability.capability_sha256);
    hash.update(&selected.entry_sha256);
    hashU64(&hash, limits.abi_version);
    hashU64(&hash, limits.device_registry_id);
    hashU64(&hash, limits.max_buffer_length);
    hashU64(&hash, limits.resource_granularity);
    hashU64(&hash, limits.storage_mode);
    hashU64(&hash, limits.cpu_cache_mode);
    return finish(&hash);
}

fn dispatchAuthorityRootV1(
    authority: allocation.AllocationAuthorityV1,
    adapter_nonce: u64,
    adapter_identity: metal.MetalAllocationAdapterIdentity,
    limits: metal.MetalAllocationLimits,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_authority_domain);
    hashU64(&hash, adapter_abi);
    hash.update(&authority.authority_sha256);
    hash.update(&authority.backend_authority_sha256);
    hashU64(&hash, adapter_nonce);
    hashU64(&hash, adapter_identity.abi_version);
    for (adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter_identity.adapter_instance);
    hashU64(&hash, limits.abi_version);
    hashU64(&hash, limits.device_registry_id);
    hashU64(&hash, limits.max_buffer_length);
    hashU64(&hash, limits.resource_granularity);
    hashU64(&hash, limits.storage_mode);
    hashU64(&hash, limits.cpu_cache_mode);
    hashU64(&hash, authority.max_queue_slots);
    return finish(&hash);
}

fn queueAuthorityRootV1(
    dispatch_authority_sha256: Digest,
    adapter_identity: metal.MetalAllocationAdapterIdentity,
    limits: metal.MetalAllocationLimits,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(queue_authority_domain);
    hashU64(&hash, adapter_abi);
    hash.update(&dispatch_authority_sha256);
    for (adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter_identity.adapter_instance);
    hashU64(&hash, limits.device_registry_id);
    // V1 owns one synchronous MTLCommandQueue use at a time.
    hashU64(&hash, 1);
    return finish(&hash);
}

fn objectIdentityV1(
    authority: allocation.AllocationAuthorityV1,
    device_registry_id: u64,
    slot_index: u32,
    generation: u64,
    call_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(object_identity_domain);
    hash.update(&authority.authority_sha256);
    hashU64(&hash, device_registry_id);
    hashU64(&hash, slot_index);
    hashU64(&hash, generation);
    hash.update(&call_sha256);
    return finish(&hash);
}

fn digestIsZero(value: Digest) bool {
    return device.digestEqual(value, allocation.zero_digest);
}

fn hashByteSliceV1(
    domain: []const u8,
    values: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hashU64(&hash, dispatch_observation_abi);
    hashU64(&hash, values.len);
    hash.update(values);
    return finish(&hash);
}

fn hashF32SliceV1(
    domain: []const u8,
    values: []const f32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hashU64(&hash, dispatch_observation_abi);
    hashU64(&hash, values.len);
    for (values) |value| hashU32(
        &hash,
        @as(u32, @bitCast(value)),
    );
    return finish(&hash);
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intCast(value), .little);
    hash.update(&bytes);
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

fn testDispatchDigest(label: []const u8) Digest {
    return native.contract.digestV1(label);
}

fn resealTestDispatchObservation(
    observation: *MetalLeaseTreeDispatchObservationV1,
) void {
    observation.geometry.geometry_sha256 =
        matvecGeometryRootV1(observation.geometry);
    observation.roles.roles_sha256 =
        matvecRoleEvidenceRootV1(observation.roles);
    observation.submission_sha256 =
        dispatchSubmissionRootV1(observation.*);
    observation.telemetry_sha256 =
        dispatchTelemetryRootV1(observation.telemetry);
    observation.backend_completion_sha256 =
        dispatchBackendCompletionRootV1(
            observation.submission_sha256,
            observation.telemetry_sha256,
        );
    var terminal: lease_tree.DispatchTerminalEvidenceV1 = .{
        .outcome = observation.outcome,
        .dispatch_generation = observation.dispatch_generation,
        .dispatch_authority_sha256 = observation.dispatch_authority_sha256,
        .queue_authority_sha256 = observation.queue_authority_sha256,
        .pin_sha256 = observation.pin_sha256,
        .dispatch_request_sha256 = observation.dispatch_request_sha256,
        .submission_sha256 = observation.submission_sha256,
        .backend_completion_sha256 = observation.backend_completion_sha256,
        .output_sha256 = observation.output_sha256,
    };
    terminal.terminal_sha256 =
        lease_tree.dispatchTerminalRootV1(terminal);
    observation.terminal_sha256 = terminal.terminal_sha256;
    observation.observation_sha256 =
        metalDispatchObservationRootV1(observation.*);
}

fn makeTestDispatchObservation() !MetalLeaseTreeDispatchObservationV1 {
    const geometry = try makeMatvecGeometryV1(64, 37, 5);
    const gpu_start: f64 = 1.0;
    const gpu_end: f64 = 1.000_001;
    var roles: MetalMatvecRoleEvidenceV1 = .{
        .bindings = .{
            .packed_weights_sha256 = testDispatchDigest("packed binding"),
            .scales_sha256 = testDispatchDigest("scales binding"),
            .input_sha256 = testDispatchDigest("input binding"),
            .output_sha256 = testDispatchDigest("output binding"),
        },
        .packed_weights_object_sha256 = testDispatchDigest("packed object"),
        .scales_object_sha256 = testDispatchDigest("scales object"),
        .input_object_sha256 = testDispatchDigest("input object"),
        .output_object_sha256 = testDispatchDigest("output object"),
    };
    roles.roles_sha256 = matvecRoleEvidenceRootV1(roles);
    var observation: MetalLeaseTreeDispatchObservationV1 = .{
        .dispatch_generation = 7,
        .allocation_count = 4,
        .materialized_bytes = geometry.packed_bytes +
            geometry.scales_bytes +
            geometry.input_bytes +
            geometry.output_bytes,
        .authority_sha256 = testDispatchDigest("allocation authority"),
        .admission_sha256 = testDispatchDigest("allocation admission"),
        .lease_sha256 = testDispatchDigest("allocation lease"),
        .backend_object_set_sha256 = testDispatchDigest("allocation object set"),
        .pin_sha256 = testDispatchDigest("dispatch pin"),
        .dispatch_request_sha256 = testDispatchDigest("dispatch request"),
        .dispatch_authority_sha256 = testDispatchDigest("dispatch authority"),
        .queue_authority_sha256 = testDispatchDigest("queue authority"),
        .geometry = geometry,
        .roles = roles,
        .packed_weights_input_sha256 = testDispatchDigest("packed input"),
        .scales_input_sha256 = testDispatchDigest("scales input"),
        .vector_input_sha256 = testDispatchDigest("vector input"),
        .telemetry = .{
            .current_allocated_before = 4_096,
            .current_allocated_after = 4_096,
            .gpu_start_time_bits = @bitCast(gpu_start),
            .gpu_end_time_bits = @bitCast(gpu_end),
            .gpu_duration_nanoseconds = @intFromFloat(
                (gpu_end - gpu_start) * 1_000_000_000.0,
            ),
            .command_status = completed_command_buffer_status,
        },
        .output_sha256 = testDispatchDigest("dispatch output"),
    };
    resealTestDispatchObservation(&observation);
    return observation;
}

test "Metal dispatch observation seals exact geometry roles telemetry and data" {
    const observation = try makeTestDispatchObservation();
    try validateMetalLeaseTreeDispatchObservationV1(
        observation,
    );
    var packed_weights = [_]u8{0x5a} ** 93;
    var scales = [_]f32{ 0.25, -0.5, 1.0 };
    var input = [_]f32{0.0} ** 37;
    var output = [_]f32{ 1.0, -2.0, 3.0, -4.0, 5.0 };
    packed_weights[17] = 0xa5;
    input[11] = -0.0;
    var payload_observation = observation;
    payload_observation.packed_weights_input_sha256 =
        matvecPackedWeightsInputRootV1(&packed_weights);
    payload_observation.scales_input_sha256 =
        matvecScalesInputRootV1(&scales);
    payload_observation.vector_input_sha256 =
        matvecVectorInputRootV1(&input);
    payload_observation.output_sha256 =
        matvecOutputRootV1(&output);
    resealTestDispatchObservation(&payload_observation);
    try validateMetalLeaseTreeDispatchPayloadV1(
        payload_observation,
        &packed_weights,
        &scales,
        &input,
        &output,
    );
    output[2] = 9.0;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchPayloadV1(
            payload_observation,
            &packed_weights,
            &scales,
            &input,
            &output,
        ),
    );

    var geometry_drift = observation;
    geometry_drift.geometry.input_bytes += 4;
    resealTestDispatchObservation(&geometry_drift);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(
            geometry_drift,
        ),
    );

    var duplicate_role = observation;
    duplicate_role.roles.bindings.output_sha256 =
        duplicate_role.roles.bindings.input_sha256;
    resealTestDispatchObservation(&duplicate_role);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(
            duplicate_role,
        ),
    );

    var byte_total_drift = observation;
    byte_total_drift.materialized_bytes += 1;
    resealTestDispatchObservation(&byte_total_drift);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(
            byte_total_drift,
        ),
    );

    var telemetry_drift = observation;
    telemetry_drift.telemetry.gpu_duration_nanoseconds += 1;
    resealTestDispatchObservation(&telemetry_drift);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(
            telemetry_drift,
        ),
    );

    var input_drift = observation;
    input_drift.vector_input_sha256 =
        testDispatchDigest("different vector input");
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(input_drift),
    );
}

test "disabled Metal adapter rejects every native entry point" {
    if (comptime metal_enabled)
        return error.SkipZigTest;

    const backend: *metal.MetalBackend = @ptrFromInt(0x1000);
    var slots = [_]MetalAllocationSlotV1{.{}};
    var adapter: MetalAllocationAdapterV1 = .{
        .backend = backend,
        .authority = .{},
        .slots = &slots,
        .limits = .{},
        .device_sha256 = allocation.zero_digest,
        .placement_sha256 = allocation.zero_digest,
        .adapter_nonce = 1,
        .adapter_identity = .{},
        .dispatch_authority_sha256 = testDispatchDigest("disabled dispatch authority"),
        .queue_authority_sha256 = testDispatchDigest("disabled queue authority"),
    };

    try std.testing.expectError(
        metal.MetalError.Unavailable,
        makeAllocationInventoryEntryV1(backend, 1, 1, 1),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        MetalAllocationAdapterV1.init(
            backend,
            .{},
            1,
            1,
            &slots,
        ),
    );

    const packed_input = [_]u8{};
    const scales = [_]f32{};
    const input = [_]f32{};
    var output = [_]f32{};
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.dispatchMatvecInt4Observed(
            .{},
            .{},
            .{},
            &packed_input,
            &scales,
            &input,
            &output,
            1,
            1,
            1,
        ),
    );

    var observations = [_]MetalAllocationObservationV1{.{}};
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.copyLiveObservations(&observations),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.validateDispatchSetUnlocked(
            .{},
            .{},
            .{},
            .{},
        ),
    );
}

test "Metal dispatch ownership blocks allocation and free before acknowledge" {
    var slots = [_]MetalAllocationSlotV1{.{}};
    var adapter: MetalAllocationAdapterV1 = .{
        .backend = @ptrFromInt(0x1000),
        .authority = .{},
        .slots = &slots,
        .limits = .{},
        .device_sha256 = allocation.zero_digest,
        .placement_sha256 = allocation.zero_digest,
        .adapter_nonce = 1,
        .adapter_identity = .{},
        .dispatch_authority_sha256 = testDispatchDigest("blocked dispatch authority"),
        .queue_authority_sha256 = testDispatchDigest("blocked queue authority"),
        .dispatch_unresolved = true,
    };
    const interface = adapter.interface();
    try std.testing.expectError(
        allocation.CallbackError.Unavailable,
        interface.allocate_fn(interface.context, .{}),
    );
    try std.testing.expectError(
        allocation.CallbackError.Unavailable,
        interface.free_fn(interface.context, .{}),
    );
    try std.testing.expectEqual(@as(u64, 0), adapter.allocate_calls);
    try std.testing.expectEqual(@as(u64, 0), adapter.free_calls);
}

test "Metal dispatch and queue authorities bind exact adapter identity" {
    const authority: allocation.AllocationAuthorityV1 = .{
        .authority_sha256 = testDispatchDigest("authority identity"),
        .backend_authority_sha256 = testDispatchDigest("backend authority identity"),
        .max_queue_slots = 1,
    };
    const limits: metal.MetalAllocationLimits = .{
        .abi_version = 1,
        .device_registry_id = 77,
        .max_buffer_length = 4_096,
        .resource_granularity = 1,
        .storage_mode = metal.shared_storage_mode,
        .cpu_cache_mode = metal.default_cpu_cache_mode,
    };
    const identity: metal.MetalAllocationAdapterIdentity = .{
        .abi_version = 1,
        .context_nonce = .{ 1, 2, 3, 4 },
        .adapter_instance = 9,
    };
    const first = dispatchAuthorityRootV1(
        authority,
        11,
        identity,
        limits,
    );
    const replay = dispatchAuthorityRootV1(
        authority,
        11,
        identity,
        limits,
    );
    const queue = queueAuthorityRootV1(
        first,
        identity,
        limits,
    );
    var changed_identity = identity;
    changed_identity.adapter_instance += 1;
    const foreign = dispatchAuthorityRootV1(
        authority,
        11,
        changed_identity,
        limits,
    );
    try std.testing.expectEqualSlices(u8, &first, &replay);
    try std.testing.expect(
        !device.digestEqual(first, foreign),
    );
    try std.testing.expect(
        !device.digestEqual(first, queue),
    );
}

test "Metal allocation observation binds logical and occupied byte meanings" {
    const selected = try device.sealInventoryEntryV1(.{
        .discovery_epoch = 1,
        .state = .present,
        .capability = try device.sealCapabilityV1(.{
            .backend_kind = .metal,
            .device_class = .accelerator,
            .operation_profile_bits = device.OperationProfileBitsV1.matvec_int4_f32_bounded,
            .operator_bits = device.OperatorBitsV1.matvec_int4_f32,
            .element_type_bits = device.ElementTypeBitsV1.packed_int4 |
                device.ElementTypeBitsV1.float32,
            .numerical_policy_bits = device.NumericalPolicyBitsV1.bounded_float32,
            .feature_bits = device.FeatureBitsV1.allocation |
                device.FeatureBitsV1.allocated_bytes_observation,
            .max_single_allocation_bytes = 4_096,
            .max_total_device_bytes = 8_192,
            .max_queue_slots = 1,
            .backend_sha256 = native.contract.digestV1("backend"),
            .device_sha256 = native.contract.digestV1("device"),
            .placement_sha256 = native.contract.digestV1("placement"),
        }),
    });
    const authority = try allocation.makeAuthorityV1(
        1,
        1,
        3,
        1,
        selected,
        native.contract.digestV1("authority"),
    );
    var observation: MetalAllocationObservationV1 = .{
        .authority_sha256 = authority.authority_sha256,
        .admission_sha256 = native.contract.digestV1("admission"),
        .allocation_call_sha256 = native.contract.digestV1("call"),
        .binding_sha256 = native.contract.digestV1("binding"),
        .backend_object_sha256 = allocation.zero_digest,
        .object_sha256 = native.contract.digestV1("object"),
        .adapter_slot_index = 2,
        .backend_object_generation = 7,
        .ordinal = 1,
        .device_registry_id = 9,
        .requested_bytes = 1_000,
        .charged_resource_bytes = 1_000,
        .buffer_length_bytes = 1_000,
        .resource_allocated_size_bytes = 1_024,
        .storage_mode = metal.shared_storage_mode,
        .cpu_cache_mode = metal.default_cpu_cache_mode,
    };
    observation.backend_object_sha256 = objectIdentityV1(
        authority,
        observation.device_registry_id,
        observation.adapter_slot_index,
        observation.backend_object_generation,
        observation.allocation_call_sha256,
    );
    observation.object_sha256 =
        allocation.backendObjectRootV1(.{
            .allocation_call_sha256 = observation.allocation_call_sha256,
            .binding_sha256 = observation.binding_sha256,
            .backend_object_sha256 = observation.backend_object_sha256,
            .backend_object_generation = observation.backend_object_generation,
            .allocated_bytes = observation.charged_resource_bytes,
        });
    observation.observation_sha256 =
        observationRootV1(observation);
    try validateObservationV1(observation, authority, 9);
    const expected_observation_sha256 = [_]u8{
        0xd8, 0xa8, 0x31, 0xe4, 0x1a, 0xda, 0x0e, 0xaf,
        0xe2, 0x17, 0x49, 0x38, 0xab, 0xde, 0x80, 0x60,
        0x94, 0xbc, 0xd3, 0x85, 0x24, 0xea, 0x32, 0x9b,
        0xcd, 0xca, 0xcc, 0xbd, 0x55, 0xf1, 0x6b, 0x45,
    };
    try std.testing.expectEqualSlices(
        u8,
        &expected_observation_sha256,
        &observation.observation_sha256,
    );

    var occupied_drift = observation;
    occupied_drift.resource_allocated_size_bytes = 999;
    occupied_drift.observation_sha256 =
        observationRootV1(occupied_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(occupied_drift, authority, 9),
    );

    var logical_drift = observation;
    logical_drift.charged_resource_bytes += 1;
    logical_drift.observation_sha256 =
        observationRootV1(logical_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(logical_drift, authority, 9),
    );

    var root_drift = observation;
    root_drift.device_registry_id += 1;
    root_drift.observation_sha256 =
        observationRootV1(root_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(root_drift, authority, 9),
    );

    var impossible_slot = observation;
    impossible_slot.adapter_slot_index = 3;
    impossible_slot.observation_sha256 =
        observationRootV1(impossible_slot);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(impossible_slot, authority, 9),
    );

    var impossible_ordinal = observation;
    impossible_ordinal.ordinal = 3;
    impossible_ordinal.observation_sha256 =
        observationRootV1(impossible_ordinal);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(impossible_ordinal, authority, 9),
    );

    var impossible_size = observation;
    impossible_size.requested_bytes = 4_097;
    impossible_size.charged_resource_bytes = 4_097;
    impossible_size.buffer_length_bytes = 4_097;
    impossible_size.resource_allocated_size_bytes = 8_192;
    impossible_size.object_sha256 =
        allocation.backendObjectRootV1(.{
            .allocation_call_sha256 = impossible_size.allocation_call_sha256,
            .binding_sha256 = impossible_size.binding_sha256,
            .backend_object_sha256 = impossible_size.backend_object_sha256,
            .backend_object_generation = impossible_size.backend_object_generation,
            .allocated_bytes = impossible_size.charged_resource_bytes,
        });
    impossible_size.observation_sha256 =
        observationRootV1(impossible_size);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(impossible_size, authority, 9),
    );

    var backend_identity_drift = observation;
    backend_identity_drift.backend_object_sha256 =
        native.contract.digestV1("impossible backend identity");
    backend_identity_drift.object_sha256 =
        allocation.backendObjectRootV1(.{
            .allocation_call_sha256 = backend_identity_drift.allocation_call_sha256,
            .binding_sha256 = backend_identity_drift.binding_sha256,
            .backend_object_sha256 = backend_identity_drift.backend_object_sha256,
            .backend_object_generation = backend_identity_drift.backend_object_generation,
            .allocated_bytes = backend_identity_drift.charged_resource_bytes,
        });
    backend_identity_drift.observation_sha256 =
        observationRootV1(backend_identity_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(
            backend_identity_drift,
            authority,
            9,
        ),
    );

    var object_root_drift = observation;
    object_root_drift.object_sha256 =
        native.contract.digestV1("impossible object root");
    object_root_drift.observation_sha256 =
        observationRootV1(object_root_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(object_root_drift, authority, 9),
    );
}
