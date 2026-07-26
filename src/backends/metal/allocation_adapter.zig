//! Native Metal adapter for the portable device-allocation lease.
//!
//! The portable V1 charge is the exact logical `MTLBuffer.length` returned by
//! a direct Shared resource. `MTLResource.allocatedSize` is retained as a
//! separate per-object native observation because Metal exposes it only after
//! creation. Neither value is relabelled as residency, and device-wide
//! `currentAllocatedSize` is never used to infer object ownership.

const std = @import("std");
const core = @import("core");
const metal = @import("backend.zig");
const native = @import("native_observer.zig");

pub const allocation = core.device_allocation_lease;
pub const device = core.device_capability_contract;
pub const Digest = allocation.Digest;

pub const adapter_abi: u64 = 0x474d_4141_0000_0001;
pub const observation_abi: u64 = 0x474d_414f_0000_0001;

const authority_domain =
    "glacier-metal-allocation-authority-v1\x00";
const object_identity_domain =
    "glacier-metal-allocation-object-identity-v1\x00";
const observation_domain =
    "glacier-metal-allocation-observation-v1\x00";
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
    device.Error ||
    metal.MetalError ||
    error{
        InvalidConfiguration,
        InvalidDevice,
        InvalidObservation,
        StaleObject,
        BufferTooSmall,
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
    next_generation: u64 = 1,
    used_resource_bytes: u64 = 0,
    observed_allocated_size_bytes: u64 = 0,
    active_admission_sha256: Digest = allocation.zero_digest,
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
        return .{
            .backend = backend,
            .authority = authority,
            .slots = slots,
            .limits = limits,
            .device_sha256 = expected_device,
            .placement_sha256 = expected_placement,
            .adapter_nonce = adapter_nonce,
            .adapter_identity = adapter_identity,
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

    pub fn validateEmpty(
        self: *MetalAllocationAdapterV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.used_resource_bytes != 0 or
            self.observed_allocated_size_bytes != 0 or
            !digestIsZero(self.active_admission_sha256))
            return Error.InvalidConfiguration;
        for (self.slots) |slot| if (slot.live or
            !slot.native_token.isZero())
            return Error.InvalidConfiguration;
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
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();

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
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
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
