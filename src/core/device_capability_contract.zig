//! Portable device capability and deterministic selection contract.
//!
//! These pointer-free values answer whether one discovered device can satisfy
//! one already-sealed execution plan. They are decision evidence only: no
//! value in this module grants allocation, queue, dispatch, or publication
//! authority. Native adapters must refresh or validate their discovery view
//! and revalidate the selected capability immediately before acquiring live
//! device resources.

const std = @import("std");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const capability_abi: u64 = 0x4744_4341_0000_0001;
pub const inventory_entry_abi: u64 = 0x4744_4945_0000_0001;
pub const requirement_abi: u64 = 0x4744_5251_0000_0001;
pub const selection_receipt_abi: u64 = 0x4744_5352_0000_0001;
pub const maximum_inventory_entries: usize = 32;

const capability_domain = "glacier-device-capability-v1\x00";
const inventory_entry_domain =
    "glacier-device-inventory-entry-v1\x00";
const inventory_domain = "glacier-device-inventory-v1\x00";
const requirement_domain = "glacier-device-requirement-v1\x00";
const selection_domain = "glacier-device-selection-v1\x00";

pub const BackendKindV1 = enum(u64) {
    cpu = 1,
    metal = 2,
    portable_compute = 3,
    provider = 4,
    _,
};

pub const DeviceClassV1 = enum(u64) {
    cpu = 1,
    accelerator = 2,
    _,
};

pub const InventoryStateV1 = enum(u64) {
    present = 1,
    unavailable = 2,
    lost = 3,
    _,
};

pub const FallbackPolicyV1 = enum(u64) {
    forbidden = 1,
    explicit_cpu = 2,
    _,
};

/// Canonical tested operation/type/numerical tuples. Selection uses these
/// profiles so independent aggregate bit sets can never imply an untested
/// Cartesian-product combination. Existing bits are append-only.
pub const OperationProfileBitsV1 = struct {
    pub const dequantize_int4_f16: u64 = @as(u64, 1) << 0;
    pub const matmul_f16_bounded: u64 = @as(u64, 1) << 1;
    pub const matvec_int4_f32_bounded: u64 = @as(u64, 1) << 2;
    pub const all: u64 =
        dequantize_int4_f16 |
        matmul_f16_bounded |
        matvec_int4_f32_bounded;
};

/// Stable semantic operations. Existing bits must never be reordered or
/// repurposed; later versions append.
pub const OperatorBitsV1 = struct {
    pub const dequantize_int4: u64 = @as(u64, 1) << 0;
    pub const matmul_f16: u64 = @as(u64, 1) << 1;
    pub const matvec_int4_f32: u64 = @as(u64, 1) << 2;
    pub const all: u64 =
        dequantize_int4 | matmul_f16 | matvec_int4_f32;
};

/// Element and storage representations accepted by the declared operations.
pub const ElementTypeBitsV1 = struct {
    pub const packed_int4: u64 = @as(u64, 1) << 0;
    pub const float16: u64 = @as(u64, 1) << 1;
    pub const float32: u64 = @as(u64, 1) << 2;
    pub const all: u64 = packed_int4 | float16 | float32;
};

/// Numerical contracts are compatibility requirements, not quality claims.
pub const NumericalPolicyBitsV1 = struct {
    pub const exact_integer: u64 = @as(u64, 1) << 0;
    pub const bounded_float32: u64 = @as(u64, 1) << 1;
    pub const bounded_float16: u64 = @as(u64, 1) << 2;
    pub const all: u64 =
        exact_integer | bounded_float32 | bounded_float16;
};

/// Device lifecycle and evidence features.
pub const FeatureBitsV1 = struct {
    pub const allocation: u64 = @as(u64, 1) << 0;
    pub const dispatch: u64 = @as(u64, 1) << 1;
    pub const completion_fence: u64 = @as(u64, 1) << 2;
    pub const persistent_weights: u64 = @as(u64, 1) << 3;
    pub const command_buffer_time: u64 = @as(u64, 1) << 4;
    pub const allocated_bytes_observation: u64 = @as(u64, 1) << 5;
    pub const cancellation: u64 = @as(u64, 1) << 6;
    pub const device_loss_signal: u64 = @as(u64, 1) << 7;
    pub const all: u64 =
        allocation |
        dispatch |
        completion_fence |
        persistent_weights |
        command_buffer_time |
        allocated_bytes_observation |
        cancellation |
        device_loss_signal;
};

pub const Error = error{
    AlreadySealed,
    InvalidCapability,
    InvalidInventoryEntry,
    InvalidRequirement,
    InvalidSelectionReceipt,
    TooManyInventoryEntries,
    DuplicateInventoryEntry,
    DuplicateCapability,
    DuplicateDevice,
    NoCompatibleDevice,
};

/// Immutable capability facts. A zero byte ceiling means unknown, never
/// unlimited. `driver_sha256` may be zero only when the adapter explicitly
/// does not retain a driver/runtime identity in this version.
pub const DeviceCapabilityV1 = struct {
    abi_version: u64 = capability_abi,
    backend_kind: BackendKindV1 = .metal,
    device_class: DeviceClassV1 = .accelerator,
    operation_profile_bits: u64 = 0,
    operator_bits: u64 = 0,
    element_type_bits: u64 = 0,
    numerical_policy_bits: u64 = 0,
    feature_bits: u64 = 0,
    max_single_allocation_bytes: u64 = 0,
    max_total_device_bytes: u64 = 0,
    max_queue_slots: u64 = 0,
    backend_sha256: Digest = zero_digest,
    device_sha256: Digest = zero_digest,
    driver_sha256: Digest = zero_digest,
    placement_sha256: Digest = zero_digest,
    capability_sha256: Digest = zero_digest,
};

/// One discovery result. Non-present entries remain in the canonical
/// inventory root but can never win selection.
pub const DeviceInventoryEntryV1 = struct {
    abi_version: u64 = inventory_entry_abi,
    discovery_epoch: u64 = 0,
    policy_rank: u64 = 0,
    state: InventoryStateV1 = .present,
    capability: DeviceCapabilityV1 = .{},
    entry_sha256: Digest = zero_digest,
};

/// Requirements are additive sidecars over an existing execution-plan root.
/// Resource amounts describe compatibility ceilings; `ResourceBank` remains
/// the logical admission authority.
pub const DeviceRequirementV1 = struct {
    abi_version: u64 = requirement_abi,
    plan_sha256: Digest = zero_digest,
    required_device_class: DeviceClassV1 = .accelerator,
    required_operation_profile_bits: u64 = 0,
    required_operator_bits: u64 = 0,
    required_element_type_bits: u64 = 0,
    required_numerical_policy_bits: u64 = 0,
    required_feature_bits: u64 = 0,
    largest_single_allocation_bytes: u64 = 0,
    total_device_bytes: u64 = 0,
    queue_slots: u64 = 0,
    fallback_policy: FallbackPolicyV1 = .forbidden,
    pinned_capability_sha256: Digest = zero_digest,
    requirement_sha256: Digest = zero_digest,
};

/// Portable decision evidence. `selected_index` intentionally lives outside
/// this receipt because discovery order is not canonical.
pub const DeviceSelectionReceiptV1 = struct {
    abi_version: u64 = selection_receipt_abi,
    inventory_count: u64 = 0,
    compatible_count: u64 = 0,
    selected_discovery_epoch: u64 = 0,
    selected_policy_rank: u64 = 0,
    selected_backend_kind: BackendKindV1 = .metal,
    selected_device_class: DeviceClassV1 = .accelerator,
    fallback_used: u64 = 0,
    requirement_sha256: Digest = zero_digest,
    inventory_sha256: Digest = zero_digest,
    selected_capability_sha256: Digest = zero_digest,
    selected_entry_sha256: Digest = zero_digest,
    receipt_sha256: Digest = zero_digest,
};

pub const SelectionV1 = struct {
    selected_index: usize,
    receipt: DeviceSelectionReceiptV1,
};

comptime {
    if (@sizeOf(DeviceCapabilityV1) != 248)
        @compileError("DeviceCapabilityV1 layout changed");
    if (@sizeOf(DeviceInventoryEntryV1) != 312)
        @compileError("DeviceInventoryEntryV1 layout changed");
    if (@sizeOf(DeviceRequirementV1) != 184)
        @compileError("DeviceRequirementV1 layout changed");
    if (@sizeOf(DeviceSelectionReceiptV1) != 224)
        @compileError("DeviceSelectionReceiptV1 layout changed");
}

pub fn sealCapabilityV1(
    unsealed: DeviceCapabilityV1,
) Error!DeviceCapabilityV1 {
    if (!digestIsZero(unsealed.capability_sha256))
        return Error.AlreadySealed;
    var result = unsealed;
    result.abi_version = capability_abi;
    try validateCapabilityShapeV1(result);
    result.capability_sha256 = capabilityRootV1(result);
    try validateCapabilityV1(result);
    return result;
}

pub fn validateCapabilityV1(
    value: DeviceCapabilityV1,
) Error!void {
    try validateCapabilityShapeV1(value);
    if (digestIsZero(value.capability_sha256) or
        !digestEqual(
            value.capability_sha256,
            capabilityRootV1(value),
        ))
        return Error.InvalidCapability;
}

fn validateCapabilityShapeV1(
    value: DeviceCapabilityV1,
) Error!void {
    if (value.abi_version != capability_abi or
        !backendKindValid(value.backend_kind) or
        !deviceClassValid(value.device_class) or
        value.operation_profile_bits == 0 or
        value.operation_profile_bits &
            ~OperationProfileBitsV1.all != 0 or
        value.operator_bits == 0 or
        value.operator_bits & ~OperatorBitsV1.all != 0 or
        value.element_type_bits == 0 or
        value.element_type_bits & ~ElementTypeBitsV1.all != 0 or
        value.numerical_policy_bits == 0 or
        value.numerical_policy_bits &
            ~NumericalPolicyBitsV1.all != 0 or
        value.feature_bits == 0 or
        value.feature_bits & ~FeatureBitsV1.all != 0 or
        digestIsZero(value.backend_sha256) or
        digestIsZero(value.device_sha256) or
        digestIsZero(value.placement_sha256))
        return Error.InvalidCapability;

    if (value.operator_bits != profileOperatorBitsV1(
        value.operation_profile_bits,
    ) or
        value.element_type_bits != profileElementTypeBitsV1(
            value.operation_profile_bits,
        ) or
        value.numerical_policy_bits != profileNumericalPolicyBitsV1(
            value.operation_profile_bits,
        ))
        return Error.InvalidCapability;

    if ((value.backend_kind == .cpu) !=
        (value.device_class == .cpu))
        return Error.InvalidCapability;
    if (value.max_single_allocation_bytes != 0 and
        value.max_total_device_bytes != 0 and
        value.max_single_allocation_bytes >
            value.max_total_device_bytes)
        return Error.InvalidCapability;

    if (hasFeature(value.feature_bits, FeatureBitsV1.dispatch) and
        !hasFeature(value.feature_bits, FeatureBitsV1.allocation))
        return Error.InvalidCapability;
    if (hasFeature(
        value.feature_bits,
        FeatureBitsV1.completion_fence,
    ) and !hasFeature(
        value.feature_bits,
        FeatureBitsV1.dispatch,
    ))
        return Error.InvalidCapability;
    if (hasFeature(
        value.feature_bits,
        FeatureBitsV1.persistent_weights,
    ) and !hasFeature(
        value.feature_bits,
        FeatureBitsV1.allocation,
    ))
        return Error.InvalidCapability;
    if (hasFeature(
        value.feature_bits,
        FeatureBitsV1.command_buffer_time,
    ) and !hasFeature(
        value.feature_bits,
        FeatureBitsV1.completion_fence,
    ))
        return Error.InvalidCapability;
    if (hasFeature(
        value.feature_bits,
        FeatureBitsV1.allocated_bytes_observation,
    ) and !hasFeature(
        value.feature_bits,
        FeatureBitsV1.allocation,
    ))
        return Error.InvalidCapability;
    if ((hasFeature(
        value.feature_bits,
        FeatureBitsV1.cancellation,
    ) or hasFeature(
        value.feature_bits,
        FeatureBitsV1.device_loss_signal,
    )) and !hasFeature(
        value.feature_bits,
        FeatureBitsV1.dispatch,
    ))
        return Error.InvalidCapability;
}

pub fn capabilityRootV1(
    value: DeviceCapabilityV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(capability_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.backend_kind));
    hashU64(&hash, @intFromEnum(value.device_class));
    hashU64(&hash, value.operation_profile_bits);
    hashU64(&hash, value.operator_bits);
    hashU64(&hash, value.element_type_bits);
    hashU64(&hash, value.numerical_policy_bits);
    hashU64(&hash, value.feature_bits);
    hashU64(&hash, value.max_single_allocation_bytes);
    hashU64(&hash, value.max_total_device_bytes);
    hashU64(&hash, value.max_queue_slots);
    hash.update(&value.backend_sha256);
    hash.update(&value.device_sha256);
    hash.update(&value.driver_sha256);
    hash.update(&value.placement_sha256);
    return finish(&hash);
}

pub fn sealInventoryEntryV1(
    unsealed: DeviceInventoryEntryV1,
) Error!DeviceInventoryEntryV1 {
    if (!digestIsZero(unsealed.entry_sha256))
        return Error.AlreadySealed;
    var result = unsealed;
    result.abi_version = inventory_entry_abi;
    try validateInventoryEntryShapeV1(result);
    result.entry_sha256 = inventoryEntryRootV1(result);
    try validateInventoryEntryV1(result);
    return result;
}

pub fn validateInventoryEntryV1(
    value: DeviceInventoryEntryV1,
) Error!void {
    try validateInventoryEntryShapeV1(value);
    if (digestIsZero(value.entry_sha256) or
        !digestEqual(
            value.entry_sha256,
            inventoryEntryRootV1(value),
        ))
        return Error.InvalidInventoryEntry;
}

fn validateInventoryEntryShapeV1(
    value: DeviceInventoryEntryV1,
) Error!void {
    if (value.abi_version != inventory_entry_abi or
        value.discovery_epoch == 0 or
        !inventoryStateValid(value.state))
        return Error.InvalidInventoryEntry;
    validateCapabilityV1(value.capability) catch
        return Error.InvalidInventoryEntry;
}

pub fn inventoryEntryRootV1(
    value: DeviceInventoryEntryV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(inventory_entry_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.discovery_epoch);
    hashU64(&hash, value.policy_rank);
    hashU64(&hash, @intFromEnum(value.state));
    hash.update(&value.capability.capability_sha256);
    return finish(&hash);
}

pub fn sealRequirementV1(
    unsealed: DeviceRequirementV1,
) Error!DeviceRequirementV1 {
    if (!digestIsZero(unsealed.requirement_sha256))
        return Error.AlreadySealed;
    var result = unsealed;
    result.abi_version = requirement_abi;
    try validateRequirementShapeV1(result);
    result.requirement_sha256 = requirementRootV1(result);
    try validateRequirementV1(result);
    return result;
}

pub fn validateRequirementV1(
    value: DeviceRequirementV1,
) Error!void {
    try validateRequirementShapeV1(value);
    if (digestIsZero(value.requirement_sha256) or
        !digestEqual(
            value.requirement_sha256,
            requirementRootV1(value),
        ))
        return Error.InvalidRequirement;
}

fn validateRequirementShapeV1(
    value: DeviceRequirementV1,
) Error!void {
    if (value.abi_version != requirement_abi or
        digestIsZero(value.plan_sha256) or
        !deviceClassValid(value.required_device_class) or
        value.required_operation_profile_bits == 0 or
        value.required_operation_profile_bits &
            ~OperationProfileBitsV1.all != 0 or
        value.required_operator_bits == 0 or
        value.required_operator_bits & ~OperatorBitsV1.all != 0 or
        value.required_element_type_bits == 0 or
        value.required_element_type_bits &
            ~ElementTypeBitsV1.all != 0 or
        value.required_numerical_policy_bits == 0 or
        value.required_numerical_policy_bits &
            ~NumericalPolicyBitsV1.all != 0 or
        value.required_feature_bits & ~FeatureBitsV1.all != 0 or
        value.total_device_bytes == 0 or
        value.largest_single_allocation_bytes >
            value.total_device_bytes or
        value.queue_slots == 0 or
        !fallbackPolicyValid(value.fallback_policy))
        return Error.InvalidRequirement;
    if (value.required_operator_bits != profileOperatorBitsV1(
        value.required_operation_profile_bits,
    ) or
        value.required_element_type_bits != profileElementTypeBitsV1(
            value.required_operation_profile_bits,
        ) or
        value.required_numerical_policy_bits !=
            profileNumericalPolicyBitsV1(
                value.required_operation_profile_bits,
            ))
        return Error.InvalidRequirement;
    if (value.fallback_policy == .explicit_cpu and
        value.required_device_class != .accelerator)
        return Error.InvalidRequirement;
    if (!digestIsZero(value.pinned_capability_sha256) and
        value.fallback_policy != .forbidden)
        return Error.InvalidRequirement;
}

pub fn requirementRootV1(
    value: DeviceRequirementV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(requirement_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.plan_sha256);
    hashU64(
        &hash,
        @intFromEnum(value.required_device_class),
    );
    hashU64(&hash, value.required_operation_profile_bits);
    hashU64(&hash, value.required_operator_bits);
    hashU64(&hash, value.required_element_type_bits);
    hashU64(&hash, value.required_numerical_policy_bits);
    hashU64(&hash, value.required_feature_bits);
    hashU64(&hash, value.largest_single_allocation_bytes);
    hashU64(&hash, value.total_device_bytes);
    hashU64(&hash, value.queue_slots);
    hashU64(&hash, @intFromEnum(value.fallback_policy));
    hash.update(&value.pinned_capability_sha256);
    return finish(&hash);
}

/// Validate and hash a complete inventory independently of discovery order.
/// Invalid or duplicate entries fail the whole inventory rather than being
/// silently ignored.
pub fn inventoryRootV1(
    entries: []const DeviceInventoryEntryV1,
) Error!Digest {
    try validateInventoryV1(entries);
    var roots: [maximum_inventory_entries]Digest =
        [_]Digest{zero_digest} ** maximum_inventory_entries;
    for (entries, 0..) |entry, index| {
        roots[index] = entry.entry_sha256;
    }
    sortDigests(roots[0..entries.len]);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(inventory_domain);
    hashU64(&hash, @intCast(entries.len));
    for (roots[0..entries.len]) |root| hash.update(&root);
    return finish(&hash);
}

fn validateInventoryV1(
    entries: []const DeviceInventoryEntryV1,
) Error!void {
    if (entries.len == 0)
        return Error.NoCompatibleDevice;
    if (entries.len > maximum_inventory_entries)
        return Error.TooManyInventoryEntries;
    for (entries, 0..) |entry, index| {
        try validateInventoryEntryV1(entry);
        for (entries[0..index]) |previous| {
            if (digestEqual(
                entry.entry_sha256,
                previous.entry_sha256,
            ))
                return Error.DuplicateInventoryEntry;
            if (digestEqual(
                entry.capability.capability_sha256,
                previous.capability.capability_sha256,
            ))
                return Error.DuplicateCapability;
            // The same physical device may be exposed by independent
            // backends. It is a duplicate only within one stable backend
            // identity.
            if (digestEqual(
                entry.capability.backend_sha256,
                previous.capability.backend_sha256,
            ) and digestEqual(
                entry.capability.device_sha256,
                previous.capability.device_sha256,
            ))
                return Error.DuplicateDevice;
        }
    }
}

/// Deterministically select one present inventory entry. Exact-class
/// candidates always win. CPU candidates are considered only after the exact
/// accelerator phase is empty and the requirement explicitly allows fallback.
pub fn selectDeviceV1(
    requirement: DeviceRequirementV1,
    entries: []const DeviceInventoryEntryV1,
) Error!SelectionV1 {
    try validateRequirementV1(requirement);
    const inventory_sha256 = try inventoryRootV1(entries);

    if (!digestIsZero(requirement.pinned_capability_sha256)) {
        for (entries, 0..) |entry, index| {
            if (!digestEqual(
                entry.capability.capability_sha256,
                requirement.pinned_capability_sha256,
            ))
                continue;
            if (entry.state != .present or
                entry.capability.device_class !=
                    requirement.required_device_class or
                !capabilitySatisfiesV1(
                    entry.capability,
                    requirement,
                ))
                return Error.NoCompatibleDevice;
            return makeSelectionV1(
                requirement,
                entries,
                inventory_sha256,
                index,
                1,
                false,
            );
        }
        return Error.NoCompatibleDevice;
    }

    const exact = findWinnerV1(
        requirement,
        entries,
        requirement.required_device_class,
    );
    if (exact.index) |index| {
        return makeSelectionV1(
            requirement,
            entries,
            inventory_sha256,
            index,
            exact.compatible_count,
            false,
        );
    }

    if (requirement.fallback_policy != .explicit_cpu or
        requirement.required_device_class != .accelerator)
        return Error.NoCompatibleDevice;
    const fallback = findWinnerV1(
        requirement,
        entries,
        .cpu,
    );
    const fallback_index = fallback.index orelse
        return Error.NoCompatibleDevice;
    return makeSelectionV1(
        requirement,
        entries,
        inventory_sha256,
        fallback_index,
        fallback.compatible_count,
        true,
    );
}

const WinnerV1 = struct {
    index: ?usize = null,
    compatible_count: u64 = 0,
};

fn findWinnerV1(
    requirement: DeviceRequirementV1,
    entries: []const DeviceInventoryEntryV1,
    device_class: DeviceClassV1,
) WinnerV1 {
    var result: WinnerV1 = .{};
    for (entries, 0..) |entry, index| {
        if (entry.state != .present or
            entry.capability.device_class != device_class or
            !capabilitySatisfiesV1(
                entry.capability,
                requirement,
            ))
            continue;
        result.compatible_count += 1;
        if (result.index == null or
            entryPrecedes(entry, entries[result.index.?]))
            result.index = index;
    }
    return result;
}

fn capabilitySatisfiesV1(
    capability: DeviceCapabilityV1,
    requirement: DeviceRequirementV1,
) bool {
    if (requirement.required_operation_profile_bits &
        ~capability.operation_profile_bits != 0 or
        requirement.required_operator_bits &
            ~capability.operator_bits != 0 or
        requirement.required_element_type_bits &
            ~capability.element_type_bits != 0 or
        requirement.required_numerical_policy_bits &
            ~capability.numerical_policy_bits != 0 or
        requirement.required_feature_bits &
            ~capability.feature_bits != 0)
        return false;

    // Zero means the adapter does not claim a physical ceiling.
    if ((requirement.largest_single_allocation_bytes != 0 and
        (capability.max_single_allocation_bytes == 0 or
            capability.max_single_allocation_bytes <
                requirement.largest_single_allocation_bytes)) or
        capability.max_total_device_bytes == 0 or
        capability.max_total_device_bytes <
            requirement.total_device_bytes or
        capability.max_queue_slots == 0 or
        capability.max_queue_slots < requirement.queue_slots)
        return false;
    return true;
}

fn entryPrecedes(
    left: DeviceInventoryEntryV1,
    right: DeviceInventoryEntryV1,
) bool {
    if (left.policy_rank != right.policy_rank)
        return left.policy_rank < right.policy_rank;
    return digestLessThan(
        left.capability.capability_sha256,
        right.capability.capability_sha256,
    );
}

fn makeSelectionV1(
    requirement: DeviceRequirementV1,
    entries: []const DeviceInventoryEntryV1,
    inventory_sha256: Digest,
    selected_index: usize,
    compatible_count: u64,
    fallback_used: bool,
) Error!SelectionV1 {
    const selected = entries[selected_index];
    var receipt: DeviceSelectionReceiptV1 = .{
        .inventory_count = @intCast(entries.len),
        .compatible_count = compatible_count,
        .selected_discovery_epoch = selected.discovery_epoch,
        .selected_policy_rank = selected.policy_rank,
        .selected_backend_kind = selected.capability.backend_kind,
        .selected_device_class = selected.capability.device_class,
        .fallback_used = @intFromBool(fallback_used),
        .requirement_sha256 = requirement.requirement_sha256,
        .inventory_sha256 = inventory_sha256,
        .selected_capability_sha256 = selected.capability.capability_sha256,
        .selected_entry_sha256 = selected.entry_sha256,
    };
    receipt.receipt_sha256 = selectionReceiptRootV1(receipt);
    try validateSelectionReceiptShapeV1(receipt);
    return .{
        .selected_index = selected_index,
        .receipt = receipt,
    };
}

pub fn selectionReceiptRootV1(
    value: DeviceSelectionReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(selection_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.inventory_count);
    hashU64(&hash, value.compatible_count);
    hashU64(&hash, value.selected_discovery_epoch);
    hashU64(&hash, value.selected_policy_rank);
    hashU64(&hash, @intFromEnum(value.selected_backend_kind));
    hashU64(&hash, @intFromEnum(value.selected_device_class));
    hashU64(&hash, value.fallback_used);
    hash.update(&value.requirement_sha256);
    hash.update(&value.inventory_sha256);
    hash.update(&value.selected_capability_sha256);
    hash.update(&value.selected_entry_sha256);
    return finish(&hash);
}

pub fn validateSelectionReceiptV1(
    value: DeviceSelectionReceiptV1,
    requirement: DeviceRequirementV1,
    entries: []const DeviceInventoryEntryV1,
) Error!void {
    try validateSelectionReceiptShapeV1(value);
    const expected = selectDeviceV1(
        requirement,
        entries,
    ) catch return Error.InvalidSelectionReceipt;
    if (!std.meta.eql(value, expected.receipt))
        return Error.InvalidSelectionReceipt;
}

fn validateSelectionReceiptShapeV1(
    value: DeviceSelectionReceiptV1,
) Error!void {
    if (value.abi_version != selection_receipt_abi or
        value.inventory_count == 0 or
        value.inventory_count > maximum_inventory_entries or
        value.compatible_count == 0 or
        value.compatible_count > value.inventory_count or
        value.selected_discovery_epoch == 0 or
        !backendKindValid(value.selected_backend_kind) or
        !deviceClassValid(value.selected_device_class) or
        value.fallback_used > 1 or
        digestIsZero(value.requirement_sha256) or
        digestIsZero(value.inventory_sha256) or
        digestIsZero(value.selected_capability_sha256) or
        digestIsZero(value.selected_entry_sha256) or
        digestIsZero(value.receipt_sha256) or
        !digestEqual(
            value.receipt_sha256,
            selectionReceiptRootV1(value),
        ))
        return Error.InvalidSelectionReceipt;
    if ((value.selected_backend_kind == .cpu) !=
        (value.selected_device_class == .cpu))
        return Error.InvalidSelectionReceipt;
    if (value.fallback_used == 1 and
        value.selected_device_class != .cpu)
        return Error.InvalidSelectionReceipt;
}

fn backendKindValid(value: BackendKindV1) bool {
    return switch (value) {
        .cpu, .metal, .portable_compute, .provider => true,
        _ => false,
    };
}

fn deviceClassValid(value: DeviceClassV1) bool {
    return switch (value) {
        .cpu, .accelerator => true,
        _ => false,
    };
}

fn inventoryStateValid(value: InventoryStateV1) bool {
    return switch (value) {
        .present, .unavailable, .lost => true,
        _ => false,
    };
}

fn fallbackPolicyValid(value: FallbackPolicyV1) bool {
    return switch (value) {
        .forbidden, .explicit_cpu => true,
        _ => false,
    };
}

fn hasFeature(bits: u64, feature: u64) bool {
    return bits & feature != 0;
}

pub fn profileOperatorBitsV1(profiles: u64) u64 {
    var result: u64 = 0;
    if (profiles & OperationProfileBitsV1.dequantize_int4_f16 != 0)
        result |= OperatorBitsV1.dequantize_int4;
    if (profiles & OperationProfileBitsV1.matmul_f16_bounded != 0)
        result |= OperatorBitsV1.matmul_f16;
    if (profiles & OperationProfileBitsV1.matvec_int4_f32_bounded != 0)
        result |= OperatorBitsV1.matvec_int4_f32;
    return result;
}

pub fn profileElementTypeBitsV1(profiles: u64) u64 {
    var result: u64 = 0;
    if (profiles & OperationProfileBitsV1.dequantize_int4_f16 != 0)
        result |= ElementTypeBitsV1.packed_int4 |
            ElementTypeBitsV1.float16;
    if (profiles & OperationProfileBitsV1.matmul_f16_bounded != 0)
        result |= ElementTypeBitsV1.float16;
    if (profiles & OperationProfileBitsV1.matvec_int4_f32_bounded != 0)
        result |= ElementTypeBitsV1.packed_int4 |
            ElementTypeBitsV1.float32;
    return result;
}

pub fn profileNumericalPolicyBitsV1(profiles: u64) u64 {
    var result: u64 = 0;
    if (profiles & OperationProfileBitsV1.dequantize_int4_f16 != 0)
        result |= NumericalPolicyBitsV1.bounded_float16;
    if (profiles & OperationProfileBitsV1.matmul_f16_bounded != 0)
        result |= NumericalPolicyBitsV1.bounded_float16;
    if (profiles & OperationProfileBitsV1.matvec_int4_f32_bounded != 0)
        result |= NumericalPolicyBitsV1.bounded_float32;
    return result;
}

fn sortDigests(values: []Digest) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const candidate = values[index];
        var insertion = index;
        while (insertion > 0 and
            digestLessThan(candidate, values[insertion - 1]))
        {
            values[insertion] = values[insertion - 1];
            insertion -= 1;
        }
        values[insertion] = candidate;
    }
}

fn digestLessThan(left: Digest, right: Digest) bool {
    return std.mem.order(u8, &left, &right) == .lt;
}

pub fn digestV1(bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes);
    return finish(&hash);
}

pub fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

pub fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
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

fn testCapability(
    backend_kind: BackendKindV1,
    device_class: DeviceClassV1,
    name: []const u8,
    operation_profiles: u64,
) !DeviceCapabilityV1 {
    const accelerator_features =
        FeatureBitsV1.allocation |
        FeatureBitsV1.dispatch |
        FeatureBitsV1.completion_fence;
    return sealCapabilityV1(.{
        .backend_kind = backend_kind,
        .device_class = device_class,
        .operation_profile_bits = operation_profiles,
        .operator_bits = profileOperatorBitsV1(operation_profiles),
        .element_type_bits = profileElementTypeBitsV1(
            operation_profiles,
        ),
        .numerical_policy_bits = profileNumericalPolicyBitsV1(
            operation_profiles,
        ),
        .feature_bits = accelerator_features,
        .max_single_allocation_bytes = 1 << 20,
        .max_total_device_bytes = 8 << 20,
        .max_queue_slots = 4,
        .backend_sha256 = digestV1(
            if (backend_kind == .cpu)
                "test cpu backend"
            else
                "test accelerator backend",
        ),
        .device_sha256 = digestV1(name),
        .driver_sha256 = digestV1("test driver"),
        .placement_sha256 = digestV1(
            if (device_class == .cpu)
                "test cpu placement"
            else
                "test accelerator placement",
        ),
    });
}

fn testEntry(
    capability: DeviceCapabilityV1,
    epoch: u64,
    rank: u64,
    state: InventoryStateV1,
) !DeviceInventoryEntryV1 {
    return sealInventoryEntryV1(.{
        .discovery_epoch = epoch,
        .policy_rank = rank,
        .state = state,
        .capability = capability,
    });
}

fn testRequirement(
    fallback: FallbackPolicyV1,
) !DeviceRequirementV1 {
    return sealRequirementV1(.{
        .plan_sha256 = digestV1("test execution plan"),
        .required_device_class = .accelerator,
        .required_operation_profile_bits = OperationProfileBitsV1.matvec_int4_f32_bounded,
        .required_operator_bits = OperatorBitsV1.matvec_int4_f32,
        .required_element_type_bits = ElementTypeBitsV1.packed_int4 |
            ElementTypeBitsV1.float32,
        .required_numerical_policy_bits = NumericalPolicyBitsV1.bounded_float32,
        .required_feature_bits = FeatureBitsV1.allocation |
            FeatureBitsV1.dispatch |
            FeatureBitsV1.completion_fence,
        .largest_single_allocation_bytes = 4096,
        .total_device_bytes = 8192,
        .queue_slots = 1,
        .fallback_policy = fallback,
    });
}

fn expectDigestHex(
    expected: []const u8,
    actual: Digest,
) !void {
    const encoded = std.fmt.bytesToHex(actual, .lower);
    try std.testing.expectEqualStrings(expected, &encoded);
}

test "device capability sealing rejects drift and unknown capability bits" {
    const capability = try testCapability(
        .metal,
        .accelerator,
        "test gpu zero",
        OperationProfileBitsV1.all,
    );
    try validateCapabilityV1(capability);
    try std.testing.expectEqual(
        capability.capability_sha256,
        capabilityRootV1(capability),
    );

    var drifted = capability;
    drifted.max_queue_slots += 1;
    try std.testing.expectError(
        Error.InvalidCapability,
        validateCapabilityV1(drifted),
    );

    var unknown = capability;
    unknown.capability_sha256 = zero_digest;
    unknown.operator_bits |= @as(u64, 1) << 63;
    try std.testing.expectError(
        Error.InvalidCapability,
        sealCapabilityV1(unknown),
    );

    var unknown_profile = capability;
    unknown_profile.capability_sha256 = zero_digest;
    unknown_profile.operation_profile_bits |= @as(u64, 1) << 63;
    try std.testing.expectError(
        Error.InvalidCapability,
        sealCapabilityV1(unknown_profile),
    );

    var cross_product_requirement =
        try testRequirement(.forbidden);
    cross_product_requirement.requirement_sha256 = zero_digest;
    cross_product_requirement.required_operation_profile_bits =
        OperationProfileBitsV1.matmul_f16_bounded;
    cross_product_requirement.required_operator_bits =
        OperatorBitsV1.matmul_f16;
    cross_product_requirement.required_element_type_bits =
        ElementTypeBitsV1.packed_int4;
    cross_product_requirement.required_numerical_policy_bits =
        NumericalPolicyBitsV1.bounded_float16;
    try std.testing.expectError(
        Error.InvalidRequirement,
        sealRequirementV1(cross_product_requirement),
    );

    var invalid_dependency = capability;
    invalid_dependency.capability_sha256 = zero_digest;
    invalid_dependency.feature_bits =
        FeatureBitsV1.command_buffer_time;
    try std.testing.expectError(
        Error.InvalidCapability,
        sealCapabilityV1(invalid_dependency),
    );
}

test "device selection is independent of discovery order" {
    const gpu_a = try testCapability(
        .metal,
        .accelerator,
        "test gpu a",
        OperationProfileBitsV1.all,
    );
    const gpu_b = try testCapability(
        .portable_compute,
        .accelerator,
        "test gpu b",
        OperationProfileBitsV1.all,
    );
    const cpu = try testCapability(
        .cpu,
        .cpu,
        "test cpu",
        OperationProfileBitsV1.all,
    );
    const entry_a = try testEntry(gpu_a, 10, 5, .present);
    const entry_b = try testEntry(gpu_b, 20, 1, .present);
    const entry_cpu = try testEntry(cpu, 30, 0, .present);
    const requirement = try testRequirement(.explicit_cpu);
    try expectDigestHex(
        "e60b628ce213fa5af30dd2b5b3887475" ++
            "88c9edc68c9503490799253461463855",
        gpu_a.capability_sha256,
    );
    try expectDigestHex(
        "3b7285ee03e211332bbba63105633bc2" ++
            "61eaf0295a755afd3b9906487667d255",
        gpu_b.capability_sha256,
    );
    try expectDigestHex(
        "f5566dcde38e7ee8ed44cbdd6c21613b" ++
            "284af5d1c30492d5e5ccd566118f3902",
        cpu.capability_sha256,
    );
    try expectDigestHex(
        "b1ab1dd19213127f5ce9e8ae776c0c1f" ++
            "07a4fec759290ee2f8930eb48668d7f1",
        entry_a.entry_sha256,
    );
    try expectDigestHex(
        "2bf11a9c20bf6e2c90d6b5619512b6ab" ++
            "f152a053f490abf6d32c4e1f5c64409f",
        entry_b.entry_sha256,
    );
    try expectDigestHex(
        "e48176e389602e0cc21fd96f3f3591bd" ++
            "6e24972f2cd859ce1eb4e0c9428cd0ea",
        entry_cpu.entry_sha256,
    );
    try expectDigestHex(
        "16473fa6529e34802c9fe20556588c0e" ++
            "3a69c58a501acf89b09f88d4b31d8488",
        requirement.requirement_sha256,
    );

    const permutations = [_][3]DeviceInventoryEntryV1{
        .{ entry_a, entry_b, entry_cpu },
        .{ entry_a, entry_cpu, entry_b },
        .{ entry_b, entry_a, entry_cpu },
        .{ entry_b, entry_cpu, entry_a },
        .{ entry_cpu, entry_a, entry_b },
        .{ entry_cpu, entry_b, entry_a },
    };
    try expectDigestHex(
        "91964f9334fa667cd45e1da054da2c68" ++
            "4ca083983897e411a0ca17ede11dbbf2",
        try inventoryRootV1(&permutations[0]),
    );
    var expected: ?DeviceSelectionReceiptV1 = null;
    for (permutations) |inventory| {
        const selection = try selectDeviceV1(
            requirement,
            &inventory,
        );
        try std.testing.expectEqual(
            gpu_b.capability_sha256,
            selection.receipt.selected_capability_sha256,
        );
        try std.testing.expectEqual(@as(u64, 0), selection.receipt.fallback_used);
        try std.testing.expectEqual(@as(u64, 2), selection.receipt.compatible_count);
        try expectDigestHex(
            "25a3339e96e33bc7742a0051cafc047f" ++
                "1b96e4205365739a8ba849afaf692813",
            selection.receipt.receipt_sha256,
        );
        try validateSelectionReceiptV1(
            selection.receipt,
            requirement,
            &inventory,
        );
        if (expected) |value| {
            try std.testing.expectEqualDeep(
                value,
                selection.receipt,
            );
        } else {
            expected = selection.receipt;
        }
    }
}

test "CPU fallback is explicit observable and forbidden for a pin" {
    const gpu_without_operation = try testCapability(
        .metal,
        .accelerator,
        "fallback gpu",
        OperationProfileBitsV1.dequantize_int4_f16,
    );
    const cpu = try testCapability(
        .cpu,
        .cpu,
        "fallback cpu",
        OperationProfileBitsV1.all,
    );
    const entries = [_]DeviceInventoryEntryV1{
        try testEntry(gpu_without_operation, 1, 0, .present),
        try testEntry(cpu, 2, 99, .present),
    };

    const forbidden = try testRequirement(.forbidden);
    try std.testing.expectError(
        Error.NoCompatibleDevice,
        selectDeviceV1(forbidden, &entries),
    );

    const allowed = try testRequirement(.explicit_cpu);
    const selection = try selectDeviceV1(allowed, &entries);
    try std.testing.expectEqual(
        DeviceClassV1.cpu,
        selection.receipt.selected_device_class,
    );
    try std.testing.expectEqual(@as(u64, 1), selection.receipt.fallback_used);
    try std.testing.expectEqual(
        cpu.capability_sha256,
        selection.receipt.selected_capability_sha256,
    );
    try expectDigestHex(
        "6dfb63e822d74f15303d1faccf0d926f" ++
            "5432a1d3a006d8cb5de362f0828fa06d",
        selection.receipt.inventory_sha256,
    );
    try expectDigestHex(
        "c16b4b89a5165a36a87ebd75a097ab9" ++
            "d0dbc9b94607016f4d14003b3433a20de",
        selection.receipt.receipt_sha256,
    );

    var pinned_unsealed = forbidden;
    pinned_unsealed.requirement_sha256 = zero_digest;
    pinned_unsealed.pinned_capability_sha256 =
        gpu_without_operation.capability_sha256;
    const pinned = try sealRequirementV1(pinned_unsealed);
    try std.testing.expectError(
        Error.NoCompatibleDevice,
        selectDeviceV1(pinned, &entries),
    );

    var invalid_pin = allowed;
    invalid_pin.requirement_sha256 = zero_digest;
    invalid_pin.pinned_capability_sha256 =
        gpu_without_operation.capability_sha256;
    try std.testing.expectError(
        Error.InvalidRequirement,
        sealRequirementV1(invalid_pin),
    );
}

test "a direct CPU requirement is not mislabeled as fallback" {
    const cpu = try testCapability(
        .cpu,
        .cpu,
        "direct cpu",
        OperationProfileBitsV1.all,
    );
    const entries = [_]DeviceInventoryEntryV1{
        try testEntry(cpu, 7, 0, .present),
    };
    var requirement = try testRequirement(.forbidden);
    requirement.requirement_sha256 = zero_digest;
    requirement.required_device_class = .cpu;
    requirement = try sealRequirementV1(requirement);

    const selection = try selectDeviceV1(requirement, &entries);
    try std.testing.expectEqual(
        DeviceClassV1.cpu,
        selection.receipt.selected_device_class,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        selection.receipt.fallback_used,
    );
    try validateSelectionReceiptV1(
        selection.receipt,
        requirement,
        &entries,
    );
}

test "selection rejects lost unknown ceilings duplicates and receipt substitution" {
    const gpu = try testCapability(
        .metal,
        .accelerator,
        "selection gpu",
        OperationProfileBitsV1.all,
    );
    const lost = [_]DeviceInventoryEntryV1{
        try testEntry(gpu, 1, 0, .lost),
    };
    const requirement = try testRequirement(.forbidden);
    try std.testing.expectError(
        Error.NoCompatibleDevice,
        selectDeviceV1(requirement, &lost),
    );

    var unknown_ceiling = gpu;
    unknown_ceiling.capability_sha256 = zero_digest;
    unknown_ceiling.max_total_device_bytes = 0;
    unknown_ceiling = try sealCapabilityV1(unknown_ceiling);
    const unknown_entries = [_]DeviceInventoryEntryV1{
        try testEntry(unknown_ceiling, 2, 0, .present),
    };
    try std.testing.expectError(
        Error.NoCompatibleDevice,
        selectDeviceV1(requirement, &unknown_entries),
    );

    const duplicate_entries = [_]DeviceInventoryEntryV1{
        try testEntry(gpu, 3, 0, .present),
        try testEntry(gpu, 4, 1, .present),
    };
    try std.testing.expectError(
        Error.DuplicateCapability,
        selectDeviceV1(requirement, &duplicate_entries),
    );

    const duplicate_device = try testCapability(
        .metal,
        .accelerator,
        "selection gpu",
        OperationProfileBitsV1.matvec_int4_f32_bounded,
    );
    const duplicate_device_entries = [_]DeviceInventoryEntryV1{
        try testEntry(gpu, 3, 0, .present),
        try testEntry(duplicate_device, 4, 1, .present),
    };
    try std.testing.expectError(
        Error.DuplicateDevice,
        selectDeviceV1(requirement, &duplicate_device_entries),
    );

    // One physical device may be exposed through independent backends.
    var alternate_backend = try testCapability(
        .portable_compute,
        .accelerator,
        "selection gpu",
        OperationProfileBitsV1.all,
    );
    alternate_backend.capability_sha256 = zero_digest;
    alternate_backend.backend_sha256 = digestV1(
        "independent portable backend",
    );
    alternate_backend = try sealCapabilityV1(alternate_backend);
    const multi_backend_entries = [_]DeviceInventoryEntryV1{
        try testEntry(gpu, 3, 1, .present),
        try testEntry(alternate_backend, 4, 0, .present),
    };
    const multi_backend_selection = try selectDeviceV1(
        requirement,
        &multi_backend_entries,
    );
    try std.testing.expectEqual(
        alternate_backend.capability_sha256,
        multi_backend_selection.receipt.selected_capability_sha256,
    );

    const valid_entries = [_]DeviceInventoryEntryV1{
        try testEntry(gpu, 5, 0, .present),
    };
    const selection = try selectDeviceV1(
        requirement,
        &valid_entries,
    );
    var foreign = selection.receipt;
    foreign.selected_discovery_epoch += 1;
    foreign.receipt_sha256 = selectionReceiptRootV1(foreign);
    try std.testing.expectError(
        Error.InvalidSelectionReceipt,
        validateSelectionReceiptV1(
            foreign,
            requirement,
            &valid_entries,
        ),
    );
}

test "inventory bound and malformed requirements fail before selection" {
    const gpu = try testCapability(
        .metal,
        .accelerator,
        "bounded gpu",
        OperationProfileBitsV1.all,
    );
    const entry = try testEntry(gpu, 1, 0, .present);
    const too_many =
        [_]DeviceInventoryEntryV1{entry} **
        (maximum_inventory_entries + 1);
    const requirement = try testRequirement(.forbidden);
    try std.testing.expectError(
        Error.TooManyInventoryEntries,
        selectDeviceV1(requirement, &too_many),
    );

    var malformed = requirement;
    malformed.requirement_sha256 = zero_digest;
    malformed.total_device_bytes =
        malformed.largest_single_allocation_bytes - 1;
    try std.testing.expectError(
        Error.InvalidRequirement,
        sealRequirementV1(malformed),
    );

    var stale_entry = entry;
    stale_entry.discovery_epoch = 0;
    try std.testing.expectError(
        Error.InvalidInventoryEntry,
        validateInventoryEntryV1(stale_entry),
    );
}
