//! Receipt-bound, backend-neutral device-allocation lifecycle.
//!
//! Selection receipts remain decision evidence only. This module composes one
//! replay-validated selection with a committed ResourceBank parent Receipt,
//! an exact backend-quoted allocation manifest, and a generation-fenced
//! allocator boundary. Device bytes are charged through a ChildLease before
//! the first allocation callback and are returned only after every acquired
//! backend object has been freed.
//!
//! V1 is a synchronous, same-process coordinator. Its fake adapter proves
//! deterministic failure/recovery semantics; a separate Metal adapter binds
//! the same lifecycle to real direct Shared MTLBuffers while charging exact
//! logical resource length. Neither path proves residency, asynchronous
//! cancellation, dispatch ownership, or device-loss recovery.

const std = @import("std");
const device = @import("device_capability_contract.zig");
const resource = @import("resource_bank.zig");

pub const Digest = device.Digest;
pub const zero_digest = device.zero_digest;

pub const manifest_abi: u64 = 0x4744_414d_0000_0001;
pub const request_abi: u64 = 0x4744_4151_0000_0001;
pub const authority_abi: u64 = 0x4744_4141_0000_0001;
pub const quote_abi: u64 = 0x4744_4155_0000_0001;
pub const admission_abi: u64 = 0x4744_4144_0000_0001;
pub const allocation_call_abi: u64 = 0x4744_4143_0000_0001;
pub const backend_object_abi: u64 = 0x4744_414f_0000_0001;
pub const object_set_abi: u64 = 0x4744_4153_0000_0001;
pub const lease_abi: u64 = 0x4744_414c_0000_0001;
pub const recovery_abi: u64 = 0x4744_4152_0000_0001;
pub const terminal_abi: u64 = 0x4744_4154_0000_0001;

pub const maximum_allocations: usize = 64;

const manifest_domain =
    "glacier-device-allocation-manifest-v1\x00";
const request_domain =
    "glacier-device-allocation-request-v1\x00";
const authority_domain =
    "glacier-device-allocation-authority-v1\x00";
const quote_domain =
    "glacier-device-allocation-quote-v1\x00";
const admission_domain =
    "glacier-device-allocation-admission-v1\x00";
const allocation_call_domain =
    "glacier-device-allocation-call-v1\x00";
const backend_object_domain =
    "glacier-device-allocation-object-v1\x00";
const object_set_domain =
    "glacier-device-allocation-object-set-v1\x00";
const lease_domain =
    "glacier-device-allocation-lease-v1\x00";
const recovery_domain =
    "glacier-device-allocation-recovery-v1\x00";
const outstanding_set_domain =
    "glacier-device-allocation-outstanding-v1\x00";
const terminal_domain =
    "glacier-device-allocation-terminal-v1\x00";
const resource_receipt_domain =
    "glacier-resource-receipt-binding-v1\x00";
const resource_child_domain =
    "glacier-resource-child-binding-v1\x00";
const child_key_domain =
    "glacier-device-allocation-child-key-v1\x00";
const fake_object_identity_domain =
    "glacier-device-allocation-fake-object-id-v1\x00";

pub const Error =
    device.Error ||
    resource.Error ||
    error{
        AlreadySealed,
        InvalidManifest,
        InvalidRequest,
        InvalidAuthority,
        InvalidQuote,
        InvalidAdmission,
        InvalidAllocationCall,
        InvalidBackendObject,
        InvalidObjectSet,
        InvalidLease,
        InvalidRecovery,
        InvalidTerminalReceipt,
        InvalidAdapter,
        InvalidBank,
        InvalidConfiguration,
        InvalidTransition,
        StaleHandle,
        CoordinatorSlotsExhausted,
        ObjectSlotsExhausted,
        GenerationExhausted,
        ArithmeticOverflow,
    };

pub const CallbackError = error{
    Unavailable,
    CapacityExceeded,
    InvalidRequest,
    StaleObject,
    InjectedFailure,
};

/// One canonical logical allocation. `charged_bytes` is the exact
/// backend-reported accounting quantity governed by this V1 adapter. It may
/// exceed requested payload bytes, but it is not an OS residency claim.
pub const AllocationEntryV1 = struct {
    binding_sha256: Digest = zero_digest,
    requested_bytes: u64 = 0,
    charged_bytes: u64 = 0,
    quote_sha256: Digest = zero_digest,
};

pub const AllocationManifestV1 = struct {
    abi_version: u64 = manifest_abi,
    allocation_count: u64 = 0,
    largest_requested_bytes: u64 = 0,
    total_requested_bytes: u64 = 0,
    largest_charged_bytes: u64 = 0,
    total_charged_bytes: u64 = 0,
    manifest_sha256: Digest = zero_digest,
};

/// Replayable request composed over an existing selection receipt and a
/// structurally valid committed-parent identity. Bank liveness is checked
/// separately and immediately before the child charge is opened.
pub const AllocationRequestV1 = struct {
    abi_version: u64 = request_abi,
    request_epoch: u64 = 0,
    owner_sha256: Digest = zero_digest,
    authority_sha256: Digest = zero_digest,
    selection_receipt_sha256: Digest = zero_digest,
    requirement_sha256: Digest = zero_digest,
    selected_capability_sha256: Digest = zero_digest,
    selected_entry_sha256: Digest = zero_digest,
    allocation_manifest_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    allocation_count: u64 = 0,
    largest_single_allocation_bytes: u64 = 0,
    total_device_bytes: u64 = 0,
    queue_slots: u64 = 0,
    request_sha256: Digest = zero_digest,
};

/// Immutable identity and hard bounds for one live backend allocator context.
/// V1 requires `maximum_leases == 1`; the adapter context owns global live
/// object enforcement even when several coordinators share it. Mutable usage
/// and generations deliberately stay outside this portable value.
pub const AllocationAuthorityV1 = struct {
    abi_version: u64 = authority_abi,
    authority_epoch: u64 = 0,
    maximum_leases: u64 = 0,
    maximum_live_objects: u64 = 0,
    allocation_granularity_bytes: u64 = 0,
    max_single_allocation_bytes: u64 = 0,
    max_total_device_bytes: u64 = 0,
    max_queue_slots: u64 = 0,
    selected_discovery_epoch: u64 = 0,
    selected_capability_sha256: Digest = zero_digest,
    selected_entry_sha256: Digest = zero_digest,
    backend_authority_sha256: Digest = zero_digest,
    authority_sha256: Digest = zero_digest,
};

/// One immutable backend quote. Its digest is structural composition
/// evidence, not authentication; admission replays the live adapter callback
/// before opening the ResourceBank child.
pub const AllocationQuoteV1 = struct {
    abi_version: u64 = quote_abi,
    authority_sha256: Digest = zero_digest,
    binding_sha256: Digest = zero_digest,
    requested_bytes: u64 = 0,
    charged_bytes: u64 = 0,
    quote_sha256: Digest = zero_digest,
};

/// Admission is returned only after ResourceBank has charged the exact child.
/// It grants synchronous materialization through the bound authority, not
/// dispatch or publication.
pub const AllocationAdmissionV1 = struct {
    abi_version: u64 = admission_abi,
    coordinator_epoch: u64 = 0,
    slot_index: u32 = 0,
    generation: u64 = 0,
    authority_sha256: Digest = zero_digest,
    request_sha256: Digest = zero_digest,
    selection_receipt_sha256: Digest = zero_digest,
    selected_capability_sha256: Digest = zero_digest,
    allocation_manifest_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    child_lease_sha256: Digest = zero_digest,
    allocation_count: u64 = 0,
    total_device_bytes: u64 = 0,
    admission_sha256: Digest = zero_digest,
};

pub const AllocationCallV1 = struct {
    abi_version: u64 = allocation_call_abi,
    authority_sha256: Digest = zero_digest,
    admission_sha256: Digest = zero_digest,
    ordinal: u64 = 0,
    binding_sha256: Digest = zero_digest,
    requested_bytes: u64 = 0,
    charged_bytes: u64 = 0,
    quote_sha256: Digest = zero_digest,
    call_sha256: Digest = zero_digest,
};

/// Pointer-free evidence returned by an adapter. Native handles and addresses
/// remain private to that adapter. Identity plus generation names the object
/// for the matching free callback.
pub const BackendObjectV1 = struct {
    abi_version: u64 = backend_object_abi,
    allocation_call_sha256: Digest = zero_digest,
    binding_sha256: Digest = zero_digest,
    backend_object_sha256: Digest = zero_digest,
    backend_object_generation: u64 = 0,
    allocated_bytes: u64 = 0,
    object_sha256: Digest = zero_digest,
};

pub const BackendObjectSetV1 = struct {
    abi_version: u64 = object_set_abi,
    admission_sha256: Digest = zero_digest,
    allocation_count: u64 = 0,
    total_allocated_bytes: u64 = 0,
    object_set_sha256: Digest = zero_digest,
};

pub const DeviceAllocationLeaseV1 = struct {
    abi_version: u64 = lease_abi,
    coordinator_epoch: u64 = 0,
    slot_index: u32 = 0,
    generation: u64 = 0,
    authority_sha256: Digest = zero_digest,
    request_sha256: Digest = zero_digest,
    admission_sha256: Digest = zero_digest,
    selection_receipt_sha256: Digest = zero_digest,
    selected_capability_sha256: Digest = zero_digest,
    allocation_manifest_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    child_lease_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    allocation_count: u64 = 0,
    materialized_bytes: u64 = 0,
    lease_sha256: Digest = zero_digest,
};

pub const TerminalOutcomeV1 = enum(u64) {
    cancelled = 1,
    allocation_failed = 2,
    released = 3,
    _,
};

pub const TerminalReasonV1 = enum(u64) {
    explicit_cancellation = 1,
    backend_allocation_failure = 2,
    backend_protocol_violation = 3,
    normal_release = 4,
    _,
};

pub const AllocationRecoveryV1 = struct {
    abi_version: u64 = recovery_abi,
    coordinator_epoch: u64 = 0,
    slot_index: u32 = 0,
    generation: u64 = 0,
    recovery_generation: u64 = 0,
    authority_sha256: Digest = zero_digest,
    admission_sha256: Digest = zero_digest,
    lease_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    target_outcome: TerminalOutcomeV1 = .cancelled,
    target_reason: TerminalReasonV1 = .explicit_cancellation,
    outstanding_object_count: u64 = 0,
    outstanding_bytes: u64 = 0,
    outstanding_set_sha256: Digest = zero_digest,
    recovery_sha256: Digest = zero_digest,
};

pub const AllocationTerminalReceiptV1 = struct {
    abi_version: u64 = terminal_abi,
    outcome: TerminalOutcomeV1 = .cancelled,
    reason: TerminalReasonV1 = .explicit_cancellation,
    coordinator_epoch: u64 = 0,
    slot_index: u32 = 0,
    generation: u64 = 0,
    authority_sha256: Digest = zero_digest,
    request_sha256: Digest = zero_digest,
    admission_sha256: Digest = zero_digest,
    lease_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    child_lease_sha256: Digest = zero_digest,
    returned_device_bytes: u64 = 0,
    terminal_sha256: Digest = zero_digest,
};

comptime {
    // These are auto-layout Zig values, not a byte wire codec. Keep the
    // expected 64-bit in-memory footprint stable without rejecting 32-bit
    // source compilation, where pointer alignment legitimately differs.
    if (@sizeOf(usize) == 8 and
        (@sizeOf(AllocationEntryV1) != 80 or
            @sizeOf(AllocationManifestV1) != 80 or
            @sizeOf(AllocationRequestV1) != 336 or
            @sizeOf(AllocationAuthorityV1) != 200 or
            @sizeOf(AllocationQuoteV1) != 120 or
            @sizeOf(AllocationAdmissionV1) != 304 or
            @sizeOf(AllocationCallV1) != 192 or
            @sizeOf(BackendObjectV1) != 152 or
            @sizeOf(BackendObjectSetV1) != 88 or
            @sizeOf(DeviceAllocationLeaseV1) != 368 or
            @sizeOf(AllocationRecoveryV1) != 264 or
            @sizeOf(AllocationTerminalReceiptV1) != 312))
        @compileError(
            "device allocation V1 64-bit in-memory footprint changed",
        );
}

pub const AdapterV1 = struct {
    context: *anyopaque,
    authority: AllocationAuthorityV1,
    /// This callback must be side-effect-free and safe to replay. It may
    /// inspect immutable allocator policy but must not reserve or allocate.
    quote_fn: *const fn (
        context: *anyopaque,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) CallbackError!AllocationQuoteV1,
    /// Success returns a newly owned identity/generation pair that is unique
    /// within this authority epoch and enforces the authority's one-lease and
    /// live-object ceilings across all coordinators sharing `context`.
    /// An error guarantees that no backend object was created.
    allocate_fn: *const fn (
        context: *anyopaque,
        call: AllocationCallV1,
    ) CallbackError!BackendObjectV1,
    /// An error guarantees that the named object remains live and retryable.
    /// Adapters with ambiguous release outcomes require a later ABI with an
    /// explicit inspect/reconcile operation.
    free_fn: *const fn (
        context: *anyopaque,
        object: BackendObjectV1,
    ) CallbackError!void,
};

pub const CancellationProbeV1 = struct {
    context: ?*anyopaque = null,
    cancelled_fn: ?*const fn (
        context: *anyopaque,
        boundary_ordinal: u64,
    ) bool = null,

    pub fn validate(self: CancellationProbeV1) Error!void {
        if ((self.context == null) !=
            (self.cancelled_fn == null))
            return Error.InvalidConfiguration;
    }

    pub fn cancelled(
        self: CancellationProbeV1,
        boundary_ordinal: u64,
    ) bool {
        const callback = self.cancelled_fn orelse return false;
        // A malformed pair is rejected once before materialization. Keep this
        // accessor fail-safe for standalone callers as well.
        const context = self.context orelse return true;
        return callback(context, boundary_ordinal);
    }
};

pub const MaterializeOutcomeV1 = union(enum) {
    active: DeviceAllocationLeaseV1,
    terminal: AllocationTerminalReceiptV1,
    recovery_required: AllocationRecoveryV1,
};

pub const RecoveryOutcomeV1 = union(enum) {
    terminal: AllocationTerminalReceiptV1,
    recovery_required: AllocationRecoveryV1,
};

pub fn sealManifestV1(
    entries: []const AllocationEntryV1,
) Error!AllocationManifestV1 {
    const totals = try manifestTotals(entries);
    var result: AllocationManifestV1 = .{
        .allocation_count = @intCast(entries.len),
        .largest_requested_bytes = totals.largest_requested,
        .total_requested_bytes = totals.total_requested,
        .largest_charged_bytes = totals.largest_charged,
        .total_charged_bytes = totals.total_charged,
    };
    result.manifest_sha256 = manifestRootV1(result, entries);
    try validateManifestV1(result, entries);
    return result;
}

pub fn validateManifestV1(
    manifest: AllocationManifestV1,
    entries: []const AllocationEntryV1,
) Error!void {
    const totals = manifestTotals(entries) catch
        return Error.InvalidManifest;
    if (manifest.abi_version != manifest_abi or
        manifest.allocation_count != entries.len or
        manifest.largest_requested_bytes != totals.largest_requested or
        manifest.total_requested_bytes != totals.total_requested or
        manifest.largest_charged_bytes != totals.largest_charged or
        manifest.total_charged_bytes != totals.total_charged or
        digestIsZero(manifest.manifest_sha256) or
        !digestEqual(
            manifest.manifest_sha256,
            manifestRootV1(manifest, entries),
        ))
        return Error.InvalidManifest;
}

pub fn manifestRootV1(
    manifest: AllocationManifestV1,
    entries: []const AllocationEntryV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(manifest_domain);
    hashU64(&hash, manifest.abi_version);
    hashU64(&hash, manifest.allocation_count);
    hashU64(&hash, manifest.largest_requested_bytes);
    hashU64(&hash, manifest.total_requested_bytes);
    hashU64(&hash, manifest.largest_charged_bytes);
    hashU64(&hash, manifest.total_charged_bytes);
    for (entries) |entry| {
        hash.update(&entry.binding_sha256);
        hashU64(&hash, entry.requested_bytes);
        hashU64(&hash, entry.charged_bytes);
        hash.update(&entry.quote_sha256);
    }
    return finish(&hash);
}

const ManifestTotals = struct {
    largest_requested: u64,
    total_requested: u64,
    largest_charged: u64,
    total_charged: u64,
};

fn manifestTotals(
    entries: []const AllocationEntryV1,
) Error!ManifestTotals {
    if (entries.len == 0 or entries.len > maximum_allocations)
        return Error.InvalidManifest;
    var result: ManifestTotals = .{
        .largest_requested = 0,
        .total_requested = 0,
        .largest_charged = 0,
        .total_charged = 0,
    };
    for (entries, 0..) |entry, index| {
        if (digestIsZero(entry.binding_sha256) or
            entry.requested_bytes == 0 or
            entry.charged_bytes < entry.requested_bytes or
            digestIsZero(entry.quote_sha256))
            return Error.InvalidManifest;
        if (index != 0 and !digestLessThan(
            entries[index - 1].binding_sha256,
            entry.binding_sha256,
        ))
            return Error.InvalidManifest;
        result.total_requested = std.math.add(
            u64,
            result.total_requested,
            entry.requested_bytes,
        ) catch return Error.ArithmeticOverflow;
        result.total_charged = std.math.add(
            u64,
            result.total_charged,
            entry.charged_bytes,
        ) catch return Error.ArithmeticOverflow;
        result.largest_requested = @max(
            result.largest_requested,
            entry.requested_bytes,
        );
        result.largest_charged = @max(
            result.largest_charged,
            entry.charged_bytes,
        );
    }
    return result;
}

pub fn makeRequestV1(
    request_epoch: u64,
    owner_sha256: Digest,
    authority: AllocationAuthorityV1,
    selection_receipt: device.DeviceSelectionReceiptV1,
    requirement: device.DeviceRequirementV1,
    inventory: []const device.DeviceInventoryEntryV1,
    parent: resource.Receipt,
    manifest: AllocationManifestV1,
    entries: []const AllocationEntryV1,
) Error!AllocationRequestV1 {
    var result: AllocationRequestV1 = .{
        .request_epoch = request_epoch,
        .owner_sha256 = owner_sha256,
        .authority_sha256 = authority.authority_sha256,
        .selection_receipt_sha256 = selection_receipt.receipt_sha256,
        .requirement_sha256 = requirement.requirement_sha256,
        .selected_capability_sha256 = selection_receipt.selected_capability_sha256,
        .selected_entry_sha256 = selection_receipt.selected_entry_sha256,
        .allocation_manifest_sha256 = manifest.manifest_sha256,
        .parent_receipt_sha256 = resourceReceiptRootV1(parent),
        .allocation_count = manifest.allocation_count,
        .largest_single_allocation_bytes = manifest.largest_charged_bytes,
        .total_device_bytes = manifest.total_charged_bytes,
        .queue_slots = requirement.queue_slots,
    };
    result.request_sha256 = requestRootV1(result);
    try validateRequestV1(
        result,
        authority,
        selection_receipt,
        requirement,
        inventory,
        parent,
        manifest,
        entries,
    );
    return result;
}

pub fn validateRequestV1(
    request: AllocationRequestV1,
    authority: AllocationAuthorityV1,
    selection_receipt: device.DeviceSelectionReceiptV1,
    requirement: device.DeviceRequirementV1,
    inventory: []const device.DeviceInventoryEntryV1,
    parent: resource.Receipt,
    manifest: AllocationManifestV1,
    entries: []const AllocationEntryV1,
) Error!void {
    if (request.abi_version != request_abi or
        request.request_epoch == 0 or
        digestIsZero(request.owner_sha256) or
        digestIsZero(request.authority_sha256) or
        digestIsZero(request.request_sha256) or
        !digestEqual(request.request_sha256, requestRootV1(request)))
        return Error.InvalidRequest;
    device.validateSelectionReceiptV1(
        selection_receipt,
        requirement,
        inventory,
    ) catch return Error.InvalidRequest;
    validateAuthorityV1(authority) catch
        return Error.InvalidRequest;
    validateManifestV1(manifest, entries) catch
        return Error.InvalidRequest;
    for (entries) |entry| {
        validateQuoteV1(
            quoteFromEntry(authority, entry),
            authority,
        ) catch return Error.InvalidRequest;
    }
    if (!resource.receiptIntegrityValidV1(parent) or
        parent.claim.device_bytes != 0 or
        parent.claim.queue_slots != requirement.queue_slots)
        return Error.InvalidRequest;
    const selected = findSelectedEntry(
        selection_receipt,
        inventory,
    ) orelse return Error.InvalidRequest;
    validateAuthorityForRequest(
        authority,
        request,
        selection_receipt,
    ) catch return Error.InvalidRequest;
    if (selected.state != .present or
        selection_receipt.selected_device_class != .accelerator or
        selection_receipt.fallback_used != 0 or
        requirement.required_feature_bits &
            device.FeatureBitsV1.allocation == 0 or
        requirement.largest_single_allocation_bytes == 0 or
        selected.capability.max_single_allocation_bytes == 0 or
        selected.capability.max_total_device_bytes == 0 or
        authority.max_single_allocation_bytes >
            selected.capability.max_single_allocation_bytes or
        authority.max_total_device_bytes >
            selected.capability.max_total_device_bytes or
        authority.max_queue_slots >
            selected.capability.max_queue_slots or
        !digestEqual(
            request.authority_sha256,
            authority.authority_sha256,
        ) or
        !digestEqual(
            request.selection_receipt_sha256,
            selection_receipt.receipt_sha256,
        ) or
        !digestEqual(
            request.requirement_sha256,
            requirement.requirement_sha256,
        ) or
        !digestEqual(
            request.selected_capability_sha256,
            selection_receipt.selected_capability_sha256,
        ) or
        !digestEqual(
            request.selected_entry_sha256,
            selection_receipt.selected_entry_sha256,
        ) or
        !digestEqual(
            request.allocation_manifest_sha256,
            manifest.manifest_sha256,
        ) or
        !digestEqual(
            request.parent_receipt_sha256,
            resourceReceiptRootV1(parent),
        ) or
        request.allocation_count != manifest.allocation_count or
        request.largest_single_allocation_bytes !=
            manifest.largest_charged_bytes or
        request.total_device_bytes != manifest.total_charged_bytes or
        request.queue_slots != requirement.queue_slots or
        request.largest_single_allocation_bytes !=
            requirement.largest_single_allocation_bytes or
        request.total_device_bytes != requirement.total_device_bytes)
        return Error.InvalidRequest;
}

pub fn requestRootV1(request: AllocationRequestV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(request_domain);
    hashU64(&hash, request.abi_version);
    hashU64(&hash, request.request_epoch);
    hash.update(&request.owner_sha256);
    hash.update(&request.authority_sha256);
    hash.update(&request.selection_receipt_sha256);
    hash.update(&request.requirement_sha256);
    hash.update(&request.selected_capability_sha256);
    hash.update(&request.selected_entry_sha256);
    hash.update(&request.allocation_manifest_sha256);
    hash.update(&request.parent_receipt_sha256);
    hashU64(&hash, request.allocation_count);
    hashU64(&hash, request.largest_single_allocation_bytes);
    hashU64(&hash, request.total_device_bytes);
    hashU64(&hash, request.queue_slots);
    return finish(&hash);
}

pub fn makeAuthorityV1(
    authority_epoch: u64,
    maximum_leases: u64,
    maximum_live_objects: u64,
    allocation_granularity_bytes: u64,
    selected: device.DeviceInventoryEntryV1,
    backend_authority_sha256: Digest,
) Error!AllocationAuthorityV1 {
    device.validateInventoryEntryV1(selected) catch
        return Error.InvalidAuthority;
    if (selected.state != .present or
        selected.capability.device_class != .accelerator)
        return Error.InvalidAuthority;
    var result: AllocationAuthorityV1 = .{
        .authority_epoch = authority_epoch,
        .maximum_leases = maximum_leases,
        .maximum_live_objects = maximum_live_objects,
        .allocation_granularity_bytes = allocation_granularity_bytes,
        .max_single_allocation_bytes = selected.capability.max_single_allocation_bytes,
        .max_total_device_bytes = selected.capability.max_total_device_bytes,
        .max_queue_slots = selected.capability.max_queue_slots,
        .selected_discovery_epoch = selected.discovery_epoch,
        .selected_capability_sha256 = selected.capability.capability_sha256,
        .selected_entry_sha256 = selected.entry_sha256,
        .backend_authority_sha256 = backend_authority_sha256,
    };
    result.authority_sha256 = authorityRootV1(result);
    try validateAuthorityV1(result);
    return result;
}

pub fn validateAuthorityV1(
    authority: AllocationAuthorityV1,
) Error!void {
    if (authority.abi_version != authority_abi or
        authority.authority_epoch == 0 or
        // V1 deliberately serializes materialized leases per adapter context.
        // Multi-lease adapters require authority-wide quarantine and
        // inspect/reconcile semantics for ambiguous object aliases.
        authority.maximum_leases != 1 or
        authority.maximum_live_objects == 0 or
        authority.maximum_live_objects > maximum_allocations or
        authority.allocation_granularity_bytes == 0 or
        !std.math.isPowerOfTwo(
            authority.allocation_granularity_bytes,
        ) or
        authority.allocation_granularity_bytes >
            authority.max_single_allocation_bytes or
        authority.max_single_allocation_bytes == 0 or
        authority.max_total_device_bytes == 0 or
        authority.max_single_allocation_bytes >
            authority.max_total_device_bytes or
        authority.max_queue_slots == 0 or
        authority.selected_discovery_epoch == 0 or
        digestIsZero(authority.selected_capability_sha256) or
        digestIsZero(authority.selected_entry_sha256) or
        digestIsZero(authority.backend_authority_sha256) or
        digestIsZero(authority.authority_sha256) or
        !digestEqual(
            authority.authority_sha256,
            authorityRootV1(authority),
        ))
        return Error.InvalidAuthority;
}

pub fn authorityRootV1(
    authority: AllocationAuthorityV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(authority_domain);
    hashU64(&hash, authority.abi_version);
    hashU64(&hash, authority.authority_epoch);
    hashU64(&hash, authority.maximum_leases);
    hashU64(&hash, authority.maximum_live_objects);
    hashU64(&hash, authority.allocation_granularity_bytes);
    hashU64(&hash, authority.max_single_allocation_bytes);
    hashU64(&hash, authority.max_total_device_bytes);
    hashU64(&hash, authority.max_queue_slots);
    hashU64(&hash, authority.selected_discovery_epoch);
    hash.update(&authority.selected_capability_sha256);
    hash.update(&authority.selected_entry_sha256);
    hash.update(&authority.backend_authority_sha256);
    return finish(&hash);
}

pub fn makeQuoteV1(
    authority: AllocationAuthorityV1,
    binding_sha256: Digest,
    requested_bytes: u64,
    charged_bytes: u64,
) Error!AllocationQuoteV1 {
    var result: AllocationQuoteV1 = .{
        .authority_sha256 = authority.authority_sha256,
        .binding_sha256 = binding_sha256,
        .requested_bytes = requested_bytes,
        .charged_bytes = charged_bytes,
    };
    result.quote_sha256 = quoteRootV1(result);
    try validateQuoteV1(result, authority);
    return result;
}

pub fn validateQuoteV1(
    quote: AllocationQuoteV1,
    authority: AllocationAuthorityV1,
) Error!void {
    try validateAuthorityV1(authority);
    if (quote.abi_version != quote_abi or
        !digestEqual(
            quote.authority_sha256,
            authority.authority_sha256,
        ) or
        digestIsZero(quote.binding_sha256) or
        quote.requested_bytes == 0 or
        quote.charged_bytes < quote.requested_bytes or
        quote.charged_bytes %
            authority.allocation_granularity_bytes != 0 or
        quote.charged_bytes >
            authority.max_single_allocation_bytes or
        digestIsZero(quote.quote_sha256) or
        !digestEqual(quote.quote_sha256, quoteRootV1(quote)))
        return Error.InvalidQuote;
}

pub fn quoteRootV1(quote: AllocationQuoteV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(quote_domain);
    hashU64(&hash, quote.abi_version);
    hash.update(&quote.authority_sha256);
    hash.update(&quote.binding_sha256);
    hashU64(&hash, quote.requested_bytes);
    hashU64(&hash, quote.charged_bytes);
    return finish(&hash);
}

fn quoteFromEntry(
    authority: AllocationAuthorityV1,
    entry: AllocationEntryV1,
) AllocationQuoteV1 {
    return .{
        .authority_sha256 = authority.authority_sha256,
        .binding_sha256 = entry.binding_sha256,
        .requested_bytes = entry.requested_bytes,
        .charged_bytes = entry.charged_bytes,
        .quote_sha256 = entry.quote_sha256,
    };
}

pub fn resourceReceiptRootV1(
    receipt: resource.Receipt,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(resource_receipt_domain);
    hashU64(&hash, receipt.bank_epoch);
    hashU64(&hash, receipt.slot_index);
    hashU64(&hash, receipt.generation);
    hashU64(&hash, receipt.owner_key);
    hashClaim(&hash, receipt.claim);
    hashU64(&hash, receipt.integrity);
    return finish(&hash);
}

pub fn resourceChildRootV1(
    child: resource.ChildLease,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(resource_child_domain);
    hashU64(&hash, child.abi_version);
    hash.update(&resourceReceiptRootV1(child.parent));
    hashU64(&hash, child.child_key);
    hashU64(&hash, child.generation);
    hashClaim(&hash, child.ceiling);
    hashClaim(&hash, child.claim);
    hashU64(&hash, child.integrity);
    return finish(&hash);
}

fn findSelectedEntry(
    selection: device.DeviceSelectionReceiptV1,
    inventory: []const device.DeviceInventoryEntryV1,
) ?device.DeviceInventoryEntryV1 {
    for (inventory) |entry| {
        if (digestEqual(
            entry.entry_sha256,
            selection.selected_entry_sha256,
        ) and digestEqual(
            entry.capability.capability_sha256,
            selection.selected_capability_sha256,
        ))
            return entry;
    }
    return null;
}

fn validateAuthorityForRequest(
    authority: AllocationAuthorityV1,
    request: AllocationRequestV1,
    selection: device.DeviceSelectionReceiptV1,
) Error!void {
    try validateAuthorityV1(authority);
    if (!digestEqual(
        authority.authority_sha256,
        request.authority_sha256,
    ) or !digestEqual(
        authority.selected_capability_sha256,
        request.selected_capability_sha256,
    ) or !digestEqual(
        authority.selected_capability_sha256,
        selection.selected_capability_sha256,
    ) or !digestEqual(
        authority.selected_entry_sha256,
        request.selected_entry_sha256,
    ) or authority.selected_discovery_epoch !=
        selection.selected_discovery_epoch or
        authority.max_single_allocation_bytes <
            request.largest_single_allocation_bytes or
        authority.max_total_device_bytes <
            request.total_device_bytes or
        authority.max_queue_slots < request.queue_slots or
        authority.maximum_live_objects < request.allocation_count)
        return Error.InvalidAuthority;
}

fn makeAdmission(
    coordinator_epoch: u64,
    slot_index: u32,
    generation: u64,
    authority: AllocationAuthorityV1,
    request: AllocationRequestV1,
    child: resource.ChildLease,
) AllocationAdmissionV1 {
    var result: AllocationAdmissionV1 = .{
        .coordinator_epoch = coordinator_epoch,
        .slot_index = slot_index,
        .generation = generation,
        .authority_sha256 = authority.authority_sha256,
        .request_sha256 = request.request_sha256,
        .selection_receipt_sha256 = request.selection_receipt_sha256,
        .selected_capability_sha256 = request.selected_capability_sha256,
        .allocation_manifest_sha256 = request.allocation_manifest_sha256,
        .parent_receipt_sha256 = request.parent_receipt_sha256,
        .child_lease_sha256 = resourceChildRootV1(child),
        .allocation_count = request.allocation_count,
        .total_device_bytes = request.total_device_bytes,
    };
    result.admission_sha256 = admissionRootV1(result);
    return result;
}

pub fn validateAdmissionV1(
    admission: AllocationAdmissionV1,
) Error!void {
    if (admission.abi_version != admission_abi or
        admission.coordinator_epoch == 0 or
        admission.generation == 0 or
        digestIsZero(admission.authority_sha256) or
        digestIsZero(admission.request_sha256) or
        digestIsZero(admission.selection_receipt_sha256) or
        digestIsZero(admission.selected_capability_sha256) or
        digestIsZero(admission.allocation_manifest_sha256) or
        digestIsZero(admission.parent_receipt_sha256) or
        digestIsZero(admission.child_lease_sha256) or
        admission.allocation_count == 0 or
        admission.allocation_count > maximum_allocations or
        admission.total_device_bytes == 0 or
        digestIsZero(admission.admission_sha256) or
        !digestEqual(
            admission.admission_sha256,
            admissionRootV1(admission),
        ))
        return Error.InvalidAdmission;
}

pub fn admissionRootV1(
    admission: AllocationAdmissionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(admission_domain);
    hashU64(&hash, admission.abi_version);
    hashU64(&hash, admission.coordinator_epoch);
    hashU64(&hash, admission.slot_index);
    hashU64(&hash, admission.generation);
    hash.update(&admission.authority_sha256);
    hash.update(&admission.request_sha256);
    hash.update(&admission.selection_receipt_sha256);
    hash.update(&admission.selected_capability_sha256);
    hash.update(&admission.allocation_manifest_sha256);
    hash.update(&admission.parent_receipt_sha256);
    hash.update(&admission.child_lease_sha256);
    hashU64(&hash, admission.allocation_count);
    hashU64(&hash, admission.total_device_bytes);
    return finish(&hash);
}

pub fn makeAllocationCallV1(
    authority: AllocationAuthorityV1,
    admission: AllocationAdmissionV1,
    ordinal: u64,
    entry: AllocationEntryV1,
) Error!AllocationCallV1 {
    var result: AllocationCallV1 = .{
        .authority_sha256 = authority.authority_sha256,
        .admission_sha256 = admission.admission_sha256,
        .ordinal = ordinal,
        .binding_sha256 = entry.binding_sha256,
        .requested_bytes = entry.requested_bytes,
        .charged_bytes = entry.charged_bytes,
        .quote_sha256 = entry.quote_sha256,
    };
    result.call_sha256 = allocationCallRootV1(result);
    try validateAllocationCallV1(result);
    return result;
}

pub fn validateAllocationCallV1(
    call: AllocationCallV1,
) Error!void {
    if (call.abi_version != allocation_call_abi or
        digestIsZero(call.authority_sha256) or
        digestIsZero(call.admission_sha256) or
        call.ordinal >= maximum_allocations or
        digestIsZero(call.binding_sha256) or
        call.requested_bytes == 0 or
        call.charged_bytes < call.requested_bytes or
        digestIsZero(call.quote_sha256) or
        digestIsZero(call.call_sha256) or
        !digestEqual(
            call.call_sha256,
            allocationCallRootV1(call),
        ))
        return Error.InvalidAllocationCall;
}

pub fn allocationCallRootV1(
    call: AllocationCallV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(allocation_call_domain);
    hashU64(&hash, call.abi_version);
    hash.update(&call.authority_sha256);
    hash.update(&call.admission_sha256);
    hashU64(&hash, call.ordinal);
    hash.update(&call.binding_sha256);
    hashU64(&hash, call.requested_bytes);
    hashU64(&hash, call.charged_bytes);
    hash.update(&call.quote_sha256);
    return finish(&hash);
}

pub fn validateBackendObjectV1(
    object: BackendObjectV1,
    call: AllocationCallV1,
) Error!void {
    validateAllocationCallV1(call) catch
        return Error.InvalidBackendObject;
    if (object.abi_version != backend_object_abi or
        !digestEqual(
            object.allocation_call_sha256,
            call.call_sha256,
        ) or !digestEqual(
        object.binding_sha256,
        call.binding_sha256,
    ) or digestIsZero(object.backend_object_sha256) or
        object.backend_object_generation == 0 or
        object.allocated_bytes != call.charged_bytes or
        digestIsZero(object.object_sha256) or
        !digestEqual(
            object.object_sha256,
            backendObjectRootV1(object),
        ))
        return Error.InvalidBackendObject;
}

pub fn backendObjectRootV1(
    object: BackendObjectV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(backend_object_domain);
    hashU64(&hash, object.abi_version);
    hash.update(&object.allocation_call_sha256);
    hash.update(&object.binding_sha256);
    hash.update(&object.backend_object_sha256);
    hashU64(&hash, object.backend_object_generation);
    hashU64(&hash, object.allocated_bytes);
    return finish(&hash);
}

pub fn makeObjectSetV1(
    admission: AllocationAdmissionV1,
    calls: []const AllocationCallV1,
    objects: []const BackendObjectV1,
) Error!BackendObjectSetV1 {
    validateAdmissionV1(admission) catch
        return Error.InvalidObjectSet;
    if (calls.len != objects.len)
        return Error.InvalidObjectSet;
    var total: u64 = 0;
    for (objects, 0..) |object, index| {
        const call = calls[index];
        validateAllocationCallV1(call) catch
            return Error.InvalidObjectSet;
        validateBackendObjectV1(object, call) catch
            return Error.InvalidObjectSet;
        if (call.ordinal != index or
            !digestEqual(
                call.authority_sha256,
                admission.authority_sha256,
            ) or
            !digestEqual(
                call.admission_sha256,
                admission.admission_sha256,
            ))
            return Error.InvalidObjectSet;
        total = std.math.add(
            u64,
            total,
            object.allocated_bytes,
        ) catch return Error.ArithmeticOverflow;
        for (objects[0..index]) |prior| {
            if (digestEqual(
                object.backend_object_sha256,
                prior.backend_object_sha256,
            ) and object.backend_object_generation ==
                prior.backend_object_generation)
                return Error.InvalidObjectSet;
        }
    }
    var result: BackendObjectSetV1 = .{
        .admission_sha256 = admission.admission_sha256,
        .allocation_count = @intCast(objects.len),
        .total_allocated_bytes = total,
    };
    result.object_set_sha256 = objectSetRootV1(result, objects);
    try validateObjectSetV1(result, admission, calls, objects);
    return result;
}

pub fn validateObjectSetV1(
    object_set: BackendObjectSetV1,
    admission: AllocationAdmissionV1,
    calls: []const AllocationCallV1,
    objects: []const BackendObjectV1,
) Error!void {
    validateAdmissionV1(admission) catch
        return Error.InvalidObjectSet;
    if (object_set.abi_version != object_set_abi or
        !digestEqual(
            object_set.admission_sha256,
            admission.admission_sha256,
        ) or calls.len != objects.len or
        object_set.allocation_count != objects.len or
        object_set.allocation_count != admission.allocation_count or
        object_set.total_allocated_bytes !=
            admission.total_device_bytes or
        digestIsZero(object_set.object_set_sha256) or
        !digestEqual(
            object_set.object_set_sha256,
            objectSetRootV1(object_set, objects),
        ))
        return Error.InvalidObjectSet;
    var total: u64 = 0;
    for (objects, 0..) |object, index| {
        const call = calls[index];
        validateAllocationCallV1(call) catch
            return Error.InvalidObjectSet;
        validateBackendObjectV1(object, call) catch
            return Error.InvalidObjectSet;
        if (call.ordinal != index or
            !digestEqual(
                call.authority_sha256,
                admission.authority_sha256,
            ) or
            !digestEqual(
                call.admission_sha256,
                admission.admission_sha256,
            ))
            return Error.InvalidObjectSet;
        total = std.math.add(
            u64,
            total,
            object.allocated_bytes,
        ) catch return Error.InvalidObjectSet;
        for (objects[0..index]) |prior| {
            if (digestEqual(
                object.backend_object_sha256,
                prior.backend_object_sha256,
            ) and object.backend_object_generation ==
                prior.backend_object_generation)
                return Error.InvalidObjectSet;
        }
    }
    if (total != object_set.total_allocated_bytes)
        return Error.InvalidObjectSet;
}

pub fn objectSetRootV1(
    object_set: BackendObjectSetV1,
    objects: []const BackendObjectV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(object_set_domain);
    hashU64(&hash, object_set.abi_version);
    hash.update(&object_set.admission_sha256);
    hashU64(&hash, object_set.allocation_count);
    hashU64(&hash, object_set.total_allocated_bytes);
    for (objects) |object| hash.update(&object.object_sha256);
    return finish(&hash);
}

fn makeLease(
    admission: AllocationAdmissionV1,
    request: AllocationRequestV1,
    object_set: BackendObjectSetV1,
) DeviceAllocationLeaseV1 {
    var result: DeviceAllocationLeaseV1 = .{
        .coordinator_epoch = admission.coordinator_epoch,
        .slot_index = admission.slot_index,
        .generation = admission.generation,
        .authority_sha256 = admission.authority_sha256,
        .request_sha256 = admission.request_sha256,
        .admission_sha256 = admission.admission_sha256,
        .selection_receipt_sha256 = admission.selection_receipt_sha256,
        .selected_capability_sha256 = admission.selected_capability_sha256,
        .allocation_manifest_sha256 = admission.allocation_manifest_sha256,
        .parent_receipt_sha256 = admission.parent_receipt_sha256,
        .child_lease_sha256 = admission.child_lease_sha256,
        .backend_object_set_sha256 = object_set.object_set_sha256,
        .allocation_count = object_set.allocation_count,
        .materialized_bytes = object_set.total_allocated_bytes,
    };
    std.debug.assert(digestEqual(
        result.request_sha256,
        request.request_sha256,
    ));
    result.lease_sha256 = leaseRootV1(result);
    return result;
}

pub fn validateLeaseV1(
    lease: DeviceAllocationLeaseV1,
) Error!void {
    if (lease.abi_version != lease_abi or
        lease.coordinator_epoch == 0 or lease.generation == 0 or
        digestIsZero(lease.authority_sha256) or
        digestIsZero(lease.request_sha256) or
        digestIsZero(lease.admission_sha256) or
        digestIsZero(lease.selection_receipt_sha256) or
        digestIsZero(lease.selected_capability_sha256) or
        digestIsZero(lease.allocation_manifest_sha256) or
        digestIsZero(lease.parent_receipt_sha256) or
        digestIsZero(lease.child_lease_sha256) or
        digestIsZero(lease.backend_object_set_sha256) or
        lease.allocation_count == 0 or
        lease.allocation_count > maximum_allocations or
        lease.materialized_bytes == 0 or
        digestIsZero(lease.lease_sha256) or
        !digestEqual(lease.lease_sha256, leaseRootV1(lease)))
        return Error.InvalidLease;
}

pub fn leaseRootV1(
    lease: DeviceAllocationLeaseV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(lease_domain);
    hashU64(&hash, lease.abi_version);
    hashU64(&hash, lease.coordinator_epoch);
    hashU64(&hash, lease.slot_index);
    hashU64(&hash, lease.generation);
    hash.update(&lease.authority_sha256);
    hash.update(&lease.request_sha256);
    hash.update(&lease.admission_sha256);
    hash.update(&lease.selection_receipt_sha256);
    hash.update(&lease.selected_capability_sha256);
    hash.update(&lease.allocation_manifest_sha256);
    hash.update(&lease.parent_receipt_sha256);
    hash.update(&lease.child_lease_sha256);
    hash.update(&lease.backend_object_set_sha256);
    hashU64(&hash, lease.allocation_count);
    hashU64(&hash, lease.materialized_bytes);
    return finish(&hash);
}

fn terminalOutcomeValid(value: TerminalOutcomeV1) bool {
    return switch (value) {
        .cancelled, .allocation_failed, .released => true,
        _ => false,
    };
}

fn terminalReasonValid(value: TerminalReasonV1) bool {
    return switch (value) {
        .explicit_cancellation,
        .backend_allocation_failure,
        .backend_protocol_violation,
        .normal_release,
        => true,
        _ => false,
    };
}

fn terminalPairValid(
    outcome: TerminalOutcomeV1,
    reason: TerminalReasonV1,
) bool {
    return switch (outcome) {
        .cancelled => reason == .explicit_cancellation,
        .allocation_failed => reason == .backend_allocation_failure or
            reason == .backend_protocol_violation,
        .released => reason == .normal_release,
        _ => false,
    };
}

pub fn validateRecoveryV1(
    recovery: AllocationRecoveryV1,
) Error!void {
    if (recovery.abi_version != recovery_abi or
        recovery.coordinator_epoch == 0 or
        recovery.generation == 0 or
        recovery.recovery_generation == 0 or
        recovery.outstanding_object_count > maximum_allocations or
        digestIsZero(recovery.authority_sha256) or
        digestIsZero(recovery.admission_sha256) or
        !terminalOutcomeValid(recovery.target_outcome) or
        !terminalReasonValid(recovery.target_reason) or
        !terminalPairValid(
            recovery.target_outcome,
            recovery.target_reason,
        ) or
        ((recovery.target_outcome == .released) !=
            !digestIsZero(recovery.lease_sha256)) or
        ((recovery.target_outcome == .released) !=
            !digestIsZero(
                recovery.backend_object_set_sha256,
            )) or
        ((recovery.outstanding_object_count == 0) !=
            digestIsZero(recovery.outstanding_set_sha256)) or
        (recovery.outstanding_object_count == 0 and
            recovery.outstanding_bytes != 0) or
        (recovery.outstanding_object_count != 0 and
            recovery.outstanding_bytes == 0) or
        digestIsZero(recovery.recovery_sha256) or
        !digestEqual(
            recovery.recovery_sha256,
            recoveryRootV1(recovery),
        ))
        return Error.InvalidRecovery;
}

pub fn recoveryRootV1(
    recovery: AllocationRecoveryV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(recovery_domain);
    hashU64(&hash, recovery.abi_version);
    hashU64(&hash, recovery.coordinator_epoch);
    hashU64(&hash, recovery.slot_index);
    hashU64(&hash, recovery.generation);
    hashU64(&hash, recovery.recovery_generation);
    hash.update(&recovery.authority_sha256);
    hash.update(&recovery.admission_sha256);
    hash.update(&recovery.lease_sha256);
    hash.update(&recovery.backend_object_set_sha256);
    hashU64(&hash, @intFromEnum(recovery.target_outcome));
    hashU64(&hash, @intFromEnum(recovery.target_reason));
    hashU64(&hash, recovery.outstanding_object_count);
    hashU64(&hash, recovery.outstanding_bytes);
    hash.update(&recovery.outstanding_set_sha256);
    return finish(&hash);
}

pub fn validateTerminalReceiptV1(
    terminal: AllocationTerminalReceiptV1,
) Error!void {
    if (terminal.abi_version != terminal_abi or
        !terminalOutcomeValid(terminal.outcome) or
        !terminalReasonValid(terminal.reason) or
        !terminalPairValid(terminal.outcome, terminal.reason) or
        terminal.coordinator_epoch == 0 or
        terminal.generation == 0 or
        digestIsZero(terminal.authority_sha256) or
        digestIsZero(terminal.request_sha256) or
        digestIsZero(terminal.admission_sha256) or
        digestIsZero(terminal.parent_receipt_sha256) or
        digestIsZero(terminal.child_lease_sha256) or
        terminal.returned_device_bytes == 0 or
        ((terminal.outcome == .released) !=
            !digestIsZero(terminal.lease_sha256)) or
        ((terminal.outcome == .released) !=
            !digestIsZero(
                terminal.backend_object_set_sha256,
            )) or
        digestIsZero(terminal.terminal_sha256) or
        !digestEqual(
            terminal.terminal_sha256,
            terminalRootV1(terminal),
        ))
        return Error.InvalidTerminalReceipt;
}

pub fn terminalRootV1(
    terminal: AllocationTerminalReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(terminal_domain);
    hashU64(&hash, terminal.abi_version);
    hashU64(&hash, @intFromEnum(terminal.outcome));
    hashU64(&hash, @intFromEnum(terminal.reason));
    hashU64(&hash, terminal.coordinator_epoch);
    hashU64(&hash, terminal.slot_index);
    hashU64(&hash, terminal.generation);
    hash.update(&terminal.authority_sha256);
    hash.update(&terminal.request_sha256);
    hash.update(&terminal.admission_sha256);
    hash.update(&terminal.lease_sha256);
    hash.update(&terminal.backend_object_set_sha256);
    hash.update(&terminal.parent_receipt_sha256);
    hash.update(&terminal.child_lease_sha256);
    hashU64(&hash, terminal.returned_device_bytes);
    return finish(&hash);
}

const CoordinatorSlotStateV1 = enum(u8) {
    free,
    admitted,
    live,
    recovery_required,
};

/// Caller-owned fixed storage. Treat fields as coordinator-private after init.
pub const CoordinatorSlotV1 = struct {
    state: CoordinatorSlotStateV1 = .free,
    generation: u64 = 0,
    authority: AllocationAuthorityV1 = .{},
    request: AllocationRequestV1 = .{},
    admission: AllocationAdmissionV1 = .{},
    parent: resource.Receipt = undefined,
    child: resource.ChildLease = undefined,
    object_set: BackendObjectSetV1 = .{},
    lease: DeviceAllocationLeaseV1 = .{},
    target_outcome: TerminalOutcomeV1 = .cancelled,
    target_reason: TerminalReasonV1 = .explicit_cancellation,
    recovery_generation: u64 = 0,
    bank_context: ?*resource.Bank = null,
    adapter_context: ?*anyopaque = null,
    adapter_quote_fn: ?@TypeOf(@as(AdapterV1, undefined).quote_fn) = null,
    adapter_allocate_fn: ?@TypeOf(@as(AdapterV1, undefined).allocate_fn) = null,
    adapter_free_fn: ?@TypeOf(@as(AdapterV1, undefined).free_fn) = null,
};

const CoordinatorObjectStateV1 = enum(u8) {
    free,
    reserved,
    live,
};

/// Shared caller-owned object storage. Raw backend handles never enter it.
pub const CoordinatorObjectSlotV1 = struct {
    state: CoordinatorObjectStateV1 = .free,
    coordinator_slot_index: u32 = 0,
    coordinator_generation: u64 = 0,
    ordinal: u64 = 0,
    entry: AllocationEntryV1 = .{},
    call: AllocationCallV1 = .{},
    object: BackendObjectV1 = .{},
};

pub const CoordinatorSnapshotV1 = struct {
    coordinator_epoch: u64,
    next_generation: u64,
    admitted_leases: usize,
    live_leases: usize,
    recovery_required_leases: usize,
    reserved_objects: usize,
    live_objects: usize,
};

/// Fixed-storage synchronous coordinator.
///
/// Once used through pointer-taking methods, do not copy or move this value.
/// Adapter and cancellation callbacks run under the mutex and must not re-enter
/// this coordinator.
pub const CoordinatorV1 = struct {
    epoch: u64,
    slots: []CoordinatorSlotV1,
    objects: []CoordinatorObjectSlotV1,
    next_generation: u64 = 1,
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        epoch: u64,
        slots: []CoordinatorSlotV1,
        objects: []CoordinatorObjectSlotV1,
    ) Error!CoordinatorV1 {
        if (epoch == 0 or slots.len == 0 or
            slots.len > std.math.maxInt(u32) or
            objects.len == 0 or objects.len > maximum_allocations)
            return Error.InvalidConfiguration;
        for (slots) |*slot| slot.* = .{};
        for (objects) |*object| object.* = .{};
        return .{
            .epoch = epoch,
            .slots = slots,
            .objects = objects,
        };
    }

    pub fn snapshot(self: *CoordinatorV1) CoordinatorSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var result: CoordinatorSnapshotV1 = .{
            .coordinator_epoch = self.epoch,
            .next_generation = self.next_generation,
            .admitted_leases = 0,
            .live_leases = 0,
            .recovery_required_leases = 0,
            .reserved_objects = 0,
            .live_objects = 0,
        };
        for (self.slots) |slot| switch (slot.state) {
            .free => {},
            .admitted => result.admitted_leases += 1,
            .live => result.live_leases += 1,
            .recovery_required => result.recovery_required_leases += 1,
        };
        for (self.objects) |object| switch (object.state) {
            .free => {},
            .reserved => result.reserved_objects += 1,
            .live => result.live_objects += 1,
        };
        return result;
    }

    /// Validate every portable composition and live parent fence before
    /// charging the exact child. Only the side-effect-free quote callback runs
    /// before Bank mutation; no allocation or free callback runs here.
    pub fn admit(
        self: *CoordinatorV1,
        bank: *resource.Bank,
        adapter: AdapterV1,
        request: AllocationRequestV1,
        selection_receipt: device.DeviceSelectionReceiptV1,
        requirement: device.DeviceRequirementV1,
        inventory: []const device.DeviceInventoryEntryV1,
        parent: resource.Receipt,
        manifest: AllocationManifestV1,
        entries: []const AllocationEntryV1,
    ) Error!AllocationAdmissionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const authority = adapter.authority;
        try validateRequestV1(
            request,
            authority,
            selection_receipt,
            requirement,
            inventory,
            parent,
            manifest,
            entries,
        );
        if (self.activeAuthorityLeases(authority.authority_sha256) >=
            authority.maximum_leases)
            return Error.CoordinatorSlotsExhausted;
        const active_authority_objects =
            self.activeAuthorityObjects(authority.authority_sha256);
        const next_authority_objects = std.math.add(
            u64,
            active_authority_objects,
            request.allocation_count,
        ) catch return Error.ArithmeticOverflow;
        if (next_authority_objects > authority.maximum_live_objects)
            return Error.ObjectSlotsExhausted;
        // Quote replay is read-only and happens before ResourceBank mutation.
        // It prevents a caller-authored charged-byte field from becoming
        // allocator accounting merely because its structural hash is valid.
        for (entries) |entry| {
            const replayed = adapter.quote_fn(
                adapter.context,
                entry.binding_sha256,
                entry.requested_bytes,
            ) catch return Error.InvalidQuote;
            try validateQuoteV1(replayed, authority);
            if (!std.meta.eql(
                replayed,
                quoteFromEntry(authority, entry),
            ))
                return Error.InvalidQuote;
        }
        try bank.validateCommitted(parent);

        const slot_index = self.findFreeCoordinatorSlot() orelse
            return Error.CoordinatorSlotsExhausted;
        var free_object_indices: [maximum_allocations]usize = undefined;
        if (!self.findFreeObjectSlots(
            entries.len,
            &free_object_indices,
        ))
            return Error.ObjectSlotsExhausted;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return Error.GenerationExhausted;
        const generation = self.next_generation;
        const child_key = allocationChildKeyV1(
            self.epoch,
            @intCast(slot_index),
            generation,
            request.request_sha256,
        );
        const claim: resource.Claim = .{
            .device_bytes = request.total_device_bytes,
        };
        const child = try bank.openChild(
            parent,
            child_key,
            claim,
            claim,
        );
        self.next_generation += 1;
        const admission = makeAdmission(
            self.epoch,
            @intCast(slot_index),
            generation,
            authority,
            request,
            child,
        );
        self.slots[slot_index] = .{
            .state = .admitted,
            .generation = generation,
            .authority = authority,
            .request = request,
            .admission = admission,
            .parent = parent,
            .child = child,
            .bank_context = bank,
            .adapter_context = adapter.context,
            .adapter_quote_fn = adapter.quote_fn,
            .adapter_allocate_fn = adapter.allocate_fn,
            .adapter_free_fn = adapter.free_fn,
        };
        for (entries, 0..) |entry, ordinal| {
            self.objects[free_object_indices[ordinal]] = .{
                .state = .reserved,
                .coordinator_slot_index = @intCast(slot_index),
                .coordinator_generation = generation,
                .ordinal = @intCast(ordinal),
                .entry = entry,
            };
        }
        return admission;
    }

    pub fn cancelAdmission(
        self: *CoordinatorV1,
        bank: *resource.Bank,
        admission: AllocationAdmissionV1,
    ) Error!AllocationTerminalReceiptV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = try self.validateAdmissionLive(
            admission,
            .admitted,
        );
        try validateBankForSlot(bank, slot.*);
        try bank.validateChild(slot.child);
        try bank.closeChild(slot.child);
        const terminal = makeTerminal(
            slot.*,
            .cancelled,
            .explicit_cancellation,
        );
        self.clearCoordinatorSlot(admission.slot_index, admission.generation);
        return terminal;
    }

    pub fn materialize(
        self: *CoordinatorV1,
        bank: *resource.Bank,
        admission: AllocationAdmissionV1,
        adapter: AdapterV1,
        cancellation: CancellationProbeV1,
    ) Error!MaterializeOutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateAdmissionLive(
            admission,
            .admitted,
        );
        try validateBankForSlot(bank, slot.*);
        try validateAdapterForSlot(adapter, slot.*);
        try bank.validateChild(slot.child);
        try cancellation.validate();
        const allocation_count: usize = std.math.cast(
            usize,
            admission.allocation_count,
        ) orelse return Error.InvalidAdmission;

        var ordinal: u64 = 0;
        while (ordinal < admission.allocation_count) : (ordinal += 1) {
            if (cancellation.cancelled(ordinal)) {
                return self.abortOrRecover(
                    bank,
                    adapter,
                    admission.slot_index,
                    admission.generation,
                    .cancelled,
                    .explicit_cancellation,
                );
            }
            const object_slot = self.findObjectSlot(
                admission.slot_index,
                admission.generation,
                ordinal,
            ) orelse return Error.StaleHandle;
            if (object_slot.state != .reserved)
                return Error.InvalidTransition;
            const call = try makeAllocationCallV1(
                slot.authority,
                admission,
                ordinal,
                object_slot.entry,
            );
            object_slot.call = call;
            const object = adapter.allocate_fn(
                adapter.context,
                call,
            ) catch {
                return self.abortOrRecover(
                    bank,
                    adapter,
                    admission.slot_index,
                    admission.generation,
                    .allocation_failed,
                    .backend_allocation_failure,
                );
            };
            // Retain the returned identity before validating its evidence so a
            // protocol-drift response still receives a cleanup attempt.
            object_slot.object = object;
            object_slot.state = .live;
            validateBackendObjectV1(object, call) catch {
                return self.abortOrRecover(
                    bank,
                    adapter,
                    admission.slot_index,
                    admission.generation,
                    .allocation_failed,
                    .backend_protocol_violation,
                );
            };
            if (self.hasDuplicateObject(
                admission.slot_index,
                admission.generation,
                ordinal,
                object,
            )) {
                return self.abortOrRecover(
                    bank,
                    adapter,
                    admission.slot_index,
                    admission.generation,
                    .allocation_failed,
                    .backend_protocol_violation,
                );
            }
        }
        if (cancellation.cancelled(admission.allocation_count)) {
            return self.abortOrRecover(
                bank,
                adapter,
                admission.slot_index,
                admission.generation,
                .cancelled,
                .explicit_cancellation,
            );
        }

        var calls: [maximum_allocations]AllocationCallV1 =
            [_]AllocationCallV1{.{}} ** maximum_allocations;
        var objects: [maximum_allocations]BackendObjectV1 =
            [_]BackendObjectV1{.{}} ** maximum_allocations;
        self.copyMaterializationInOrder(
            admission.slot_index,
            admission.generation,
            calls[0..allocation_count],
            objects[0..allocation_count],
        ) catch return self.abortOrRecover(
            bank,
            adapter,
            admission.slot_index,
            admission.generation,
            .allocation_failed,
            .backend_protocol_violation,
        );
        const object_set = makeObjectSetV1(
            admission,
            calls[0..allocation_count],
            objects[0..allocation_count],
        ) catch return self.abortOrRecover(
            bank,
            adapter,
            admission.slot_index,
            admission.generation,
            .allocation_failed,
            .backend_protocol_violation,
        );
        const lease = makeLease(
            admission,
            slot.request,
            object_set,
        );
        slot.object_set = object_set;
        slot.lease = lease;
        slot.state = .live;
        return .{ .active = lease };
    }

    pub fn release(
        self: *CoordinatorV1,
        bank: *resource.Bank,
        lease: DeviceAllocationLeaseV1,
        adapter: AdapterV1,
    ) Error!RecoveryOutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = try self.validateLeaseLive(lease);
        try validateBankForSlot(bank, slot.*);
        try validateAdapterForSlot(adapter, slot.*);
        try bank.validateChild(slot.child);
        const outcome = self.cleanupForTerminal(
            bank,
            adapter,
            lease.slot_index,
            lease.generation,
            .released,
            .normal_release,
        );
        return switch (outcome) {
            .terminal => |terminal| .{ .terminal = terminal },
            .recovery_required => |recovery| .{ .recovery_required = recovery },
            .active => unreachable,
        };
    }

    pub fn retryRecovery(
        self: *CoordinatorV1,
        bank: *resource.Bank,
        recovery: AllocationRecoveryV1,
        adapter: AdapterV1,
    ) Error!RecoveryOutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = try self.validateRecoveryLive(recovery);
        try validateBankForSlot(bank, slot.*);
        try validateAdapterForSlot(adapter, slot.*);
        try bank.validateChild(slot.child);
        const outcome = self.cleanupForTerminal(
            bank,
            adapter,
            recovery.slot_index,
            recovery.generation,
            slot.target_outcome,
            slot.target_reason,
        );
        return switch (outcome) {
            .terminal => |terminal| .{ .terminal = terminal },
            .recovery_required => |next| .{ .recovery_required = next },
            .active => unreachable,
        };
    }

    fn abortOrRecover(
        self: *CoordinatorV1,
        bank: *resource.Bank,
        adapter: AdapterV1,
        slot_index: u32,
        generation: u64,
        outcome: TerminalOutcomeV1,
        reason: TerminalReasonV1,
    ) MaterializeOutcomeV1 {
        return self.cleanupForTerminal(
            bank,
            adapter,
            slot_index,
            generation,
            outcome,
            reason,
        );
    }

    fn cleanupForTerminal(
        self: *CoordinatorV1,
        bank: *resource.Bank,
        adapter: AdapterV1,
        slot_index: u32,
        generation: u64,
        outcome: TerminalOutcomeV1,
        reason: TerminalReasonV1,
    ) MaterializeOutcomeV1 {
        const index: usize = slot_index;
        var slot = &self.slots[index];
        slot.target_outcome = outcome;
        slot.target_reason = reason;
        var free_failed = false;
        var ordinal = slot.admission.allocation_count;
        while (ordinal != 0) {
            ordinal -= 1;
            const object_slot = self.findObjectSlot(
                slot_index,
                generation,
                ordinal,
            ) orelse {
                free_failed = true;
                continue;
            };
            if (object_slot.state != .live) continue;
            adapter.free_fn(
                adapter.context,
                object_slot.object,
            ) catch {
                free_failed = true;
                continue;
            };
            object_slot.state = .reserved;
            object_slot.object = .{};
        }
        if (free_failed) {
            slot.state = .recovery_required;
            slot.recovery_generation =
                nextRecoveryGeneration(slot.recovery_generation);
            return .{
                .recovery_required = self.makeRecovery(slot_index, generation),
            };
        }
        bank.closeChild(slot.child) catch {
            slot.state = .recovery_required;
            slot.recovery_generation =
                nextRecoveryGeneration(slot.recovery_generation);
            return .{
                .recovery_required = self.makeRecovery(slot_index, generation),
            };
        };
        const terminal = makeTerminal(slot.*, outcome, reason);
        self.clearCoordinatorSlot(slot_index, generation);
        return .{ .terminal = terminal };
    }

    fn makeRecovery(
        self: *CoordinatorV1,
        slot_index: u32,
        generation: u64,
    ) AllocationRecoveryV1 {
        const slot = self.slots[slot_index];
        var outstanding_count: u64 = 0;
        var outstanding_bytes: u64 = 0;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(outstanding_set_domain);
        hashU64(&hash, self.epoch);
        hashU64(&hash, slot_index);
        hashU64(&hash, generation);
        const allocation_count = std.math.cast(
            usize,
            slot.admission.allocation_count,
        ) orelse maximum_allocations;
        for (0..allocation_count) |ordinal| {
            const object_slot = self.findObjectSlot(
                slot_index,
                generation,
                ordinal,
            ) orelse continue;
            if (object_slot.state != .live) continue;
            outstanding_count += 1;
            // The adapter response may be malformed. Recovery accounting is
            // therefore composed from the sealed call, never from the
            // unvalidated object-reported byte field.
            outstanding_bytes +|= object_slot.call.charged_bytes;
            hashU64(&hash, ordinal);
            hash.update(&object_slot.object.object_sha256);
        }
        const outstanding_root =
            if (outstanding_count == 0) zero_digest else finish(&hash);
        var result: AllocationRecoveryV1 = .{
            .coordinator_epoch = self.epoch,
            .slot_index = slot_index,
            .generation = generation,
            .recovery_generation = slot.recovery_generation,
            .authority_sha256 = slot.authority.authority_sha256,
            .admission_sha256 = slot.admission.admission_sha256,
            .lease_sha256 = slot.lease.lease_sha256,
            .backend_object_set_sha256 = slot.object_set.object_set_sha256,
            .target_outcome = slot.target_outcome,
            .target_reason = slot.target_reason,
            .outstanding_object_count = outstanding_count,
            .outstanding_bytes = outstanding_bytes,
            .outstanding_set_sha256 = outstanding_root,
        };
        result.recovery_sha256 = recoveryRootV1(result);
        return result;
    }

    fn validateAdmissionLive(
        self: *CoordinatorV1,
        admission: AllocationAdmissionV1,
        required_state: CoordinatorSlotStateV1,
    ) Error!*CoordinatorSlotV1 {
        validateAdmissionV1(admission) catch
            return Error.StaleHandle;
        if (admission.coordinator_epoch != self.epoch or
            admission.slot_index >= self.slots.len)
            return Error.StaleHandle;
        const slot = &self.slots[admission.slot_index];
        if (slot.state != required_state or
            slot.generation != admission.generation or
            !std.meta.eql(slot.admission, admission))
            return Error.StaleHandle;
        return slot;
    }

    fn validateLeaseLive(
        self: *CoordinatorV1,
        lease: DeviceAllocationLeaseV1,
    ) Error!*CoordinatorSlotV1 {
        validateLeaseV1(lease) catch return Error.StaleHandle;
        if (lease.coordinator_epoch != self.epoch or
            lease.slot_index >= self.slots.len)
            return Error.StaleHandle;
        const slot = &self.slots[lease.slot_index];
        if (slot.state != .live or
            slot.generation != lease.generation or
            !std.meta.eql(slot.lease, lease))
            return Error.StaleHandle;
        return slot;
    }

    fn validateRecoveryLive(
        self: *CoordinatorV1,
        recovery: AllocationRecoveryV1,
    ) Error!*CoordinatorSlotV1 {
        validateRecoveryV1(recovery) catch return Error.StaleHandle;
        if (recovery.coordinator_epoch != self.epoch or
            recovery.slot_index >= self.slots.len)
            return Error.StaleHandle;
        const slot = &self.slots[recovery.slot_index];
        if (slot.state != .recovery_required or
            slot.generation != recovery.generation or
            slot.recovery_generation != recovery.recovery_generation or
            !std.meta.eql(
                self.makeRecovery(
                    recovery.slot_index,
                    recovery.generation,
                ),
                recovery,
            ))
            return Error.StaleHandle;
        return slot;
    }

    fn findFreeCoordinatorSlot(
        self: *CoordinatorV1,
    ) ?usize {
        for (self.slots, 0..) |slot, index| {
            if (slot.state == .free) return index;
        }
        return null;
    }

    fn activeAuthorityLeases(
        self: *CoordinatorV1,
        authority_sha256: Digest,
    ) u64 {
        var result: u64 = 0;
        for (self.slots) |slot| {
            if (slot.state != .free and digestEqual(
                slot.authority.authority_sha256,
                authority_sha256,
            ))
                result += 1;
        }
        return result;
    }

    fn activeAuthorityObjects(
        self: *CoordinatorV1,
        authority_sha256: Digest,
    ) u64 {
        var result: u64 = 0;
        for (self.objects) |object| {
            if (object.state == .free) continue;
            const parent_index: usize =
                object.coordinator_slot_index;
            if (parent_index >= self.slots.len) continue;
            const slot = self.slots[parent_index];
            if (slot.state != .free and
                slot.generation ==
                    object.coordinator_generation and
                digestEqual(
                    slot.authority.authority_sha256,
                    authority_sha256,
                ))
                result += 1;
        }
        return result;
    }

    fn findFreeObjectSlots(
        self: *CoordinatorV1,
        count: usize,
        indices: *[maximum_allocations]usize,
    ) bool {
        var found: usize = 0;
        for (self.objects, 0..) |object, index| {
            if (object.state != .free) continue;
            indices[found] = index;
            found += 1;
            if (found == count) return true;
        }
        return false;
    }

    fn findObjectSlot(
        self: *CoordinatorV1,
        coordinator_slot_index: u32,
        generation: u64,
        ordinal: u64,
    ) ?*CoordinatorObjectSlotV1 {
        for (self.objects) |*object| {
            if (object.state != .free and
                object.coordinator_slot_index ==
                    coordinator_slot_index and
                object.coordinator_generation == generation and
                object.ordinal == ordinal)
                return object;
        }
        return null;
    }

    fn hasDuplicateObject(
        self: *CoordinatorV1,
        slot_index: u32,
        generation: u64,
        current_ordinal: u64,
        object: BackendObjectV1,
    ) bool {
        for (self.objects) |candidate| {
            if (candidate.state != .live or
                candidate.coordinator_slot_index != slot_index or
                candidate.coordinator_generation != generation or
                candidate.ordinal == current_ordinal)
                continue;
            if (digestEqual(
                candidate.object.backend_object_sha256,
                object.backend_object_sha256,
            ) and candidate.object.backend_object_generation ==
                object.backend_object_generation)
                return true;
        }
        return false;
    }

    fn copyMaterializationInOrder(
        self: *CoordinatorV1,
        slot_index: u32,
        generation: u64,
        out_calls: []AllocationCallV1,
        out_objects: []BackendObjectV1,
    ) Error!void {
        if (out_calls.len != out_objects.len)
            return Error.InvalidConfiguration;
        for (out_objects, 0..) |*target, ordinal| {
            const object = self.findObjectSlot(
                slot_index,
                generation,
                ordinal,
            ) orelse return Error.StaleHandle;
            if (object.state != .live)
                return Error.InvalidTransition;
            out_calls[ordinal] = object.call;
            target.* = object.object;
        }
    }

    fn clearCoordinatorSlot(
        self: *CoordinatorV1,
        slot_index: u32,
        generation: u64,
    ) void {
        for (self.objects) |*object| {
            if (object.state != .free and
                object.coordinator_slot_index == slot_index and
                object.coordinator_generation == generation)
                object.* = .{};
        }
        self.slots[slot_index] = .{};
    }
};

fn validateAdapterForSlot(
    adapter: AdapterV1,
    slot: CoordinatorSlotV1,
) Error!void {
    try validateAuthorityV1(adapter.authority);
    const context = slot.adapter_context orelse
        return Error.InvalidAdapter;
    const quote_fn = slot.adapter_quote_fn orelse
        return Error.InvalidAdapter;
    const allocate_fn = slot.adapter_allocate_fn orelse
        return Error.InvalidAdapter;
    const free_fn = slot.adapter_free_fn orelse
        return Error.InvalidAdapter;
    if (!std.meta.eql(adapter.authority, slot.authority) or
        adapter.context != context or
        @intFromPtr(adapter.quote_fn) != @intFromPtr(quote_fn) or
        @intFromPtr(adapter.allocate_fn) != @intFromPtr(allocate_fn) or
        @intFromPtr(adapter.free_fn) != @intFromPtr(free_fn))
        return Error.InvalidAdapter;
}

fn validateBankForSlot(
    bank: *resource.Bank,
    slot: CoordinatorSlotV1,
) Error!void {
    const admitted_bank = slot.bank_context orelse
        return Error.InvalidBank;
    if (bank != admitted_bank)
        return Error.InvalidBank;
}

fn makeTerminal(
    slot: CoordinatorSlotV1,
    outcome: TerminalOutcomeV1,
    reason: TerminalReasonV1,
) AllocationTerminalReceiptV1 {
    var result: AllocationTerminalReceiptV1 = .{
        .outcome = outcome,
        .reason = reason,
        .coordinator_epoch = slot.admission.coordinator_epoch,
        .slot_index = slot.admission.slot_index,
        .generation = slot.admission.generation,
        .authority_sha256 = slot.authority.authority_sha256,
        .request_sha256 = slot.request.request_sha256,
        .admission_sha256 = slot.admission.admission_sha256,
        .lease_sha256 = if (outcome == .released)
            slot.lease.lease_sha256
        else
            zero_digest,
        .backend_object_set_sha256 = if (outcome == .released)
            slot.object_set.object_set_sha256
        else
            zero_digest,
        .parent_receipt_sha256 = slot.admission.parent_receipt_sha256,
        .child_lease_sha256 = slot.admission.child_lease_sha256,
        .returned_device_bytes = slot.request.total_device_bytes,
    };
    result.terminal_sha256 = terminalRootV1(result);
    return result;
}

fn nextRecoveryGeneration(current: u64) u64 {
    // At exhaustion retain the same retry authority rather than wrapping or
    // dropping a conservative charge. If any object state changed, the
    // outstanding-set root still fences the copied prior ticket.
    return if (current == std.math.maxInt(u64))
        current
    else
        current + 1;
}

fn allocationChildKeyV1(
    coordinator_epoch: u64,
    slot_index: u32,
    generation: u64,
    request_sha256: Digest,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(child_key_domain);
    hashU64(&hash, coordinator_epoch);
    hashU64(&hash, slot_index);
    hashU64(&hash, generation);
    hash.update(&request_sha256);
    const key_digest = finish(&hash);
    const value = std.mem.readInt(u64, key_digest[0..8], .little);
    return if (value == 0) 1 else value;
}

/// Deterministic fake backend object registry.
pub const FakeObjectSlotV1 = struct {
    live: bool = false,
    generation: u64 = 0,
    call: AllocationCallV1 = .{},
    object: BackendObjectV1 = .{},
    actual_charged_bytes: u64 = 0,
};

pub const FakeSnapshotV1 = struct {
    authority_epoch: u64,
    used_bytes: u64,
    live_objects: usize,
    materialized_leases: usize,
    allocate_calls: u64,
    free_calls: u64,
    injected_allocate_failures: u64,
    injected_free_failures: u64,
};

/// Same-process fake allocator. Once `adapter()` exposes its address, do not
/// copy or move this value.
pub const FakeBackendV1 = struct {
    authority: AllocationAuthorityV1,
    objects: []FakeObjectSlotV1,
    next_generation: u64 = 1,
    used_bytes: u64 = 0,
    active_admission_sha256: Digest = zero_digest,
    allocate_calls: u64 = 0,
    free_calls: u64 = 0,
    injected_allocate_failures: u64 = 0,
    injected_free_failures: u64 = 0,
    fail_allocate_ordinal: ?u64 = null,
    fail_free_binding_sha256: ?Digest = null,
    report_byte_delta: i64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        authority: AllocationAuthorityV1,
        objects: []FakeObjectSlotV1,
    ) Error!FakeBackendV1 {
        try validateAuthorityV1(authority);
        if (objects.len == 0 or
            objects.len != authority.maximum_live_objects or
            objects.len > maximum_allocations)
            return Error.InvalidConfiguration;
        for (objects) |*object| object.* = .{};
        return .{
            .authority = authority,
            .objects = objects,
        };
    }

    pub fn adapter(self: *FakeBackendV1) AdapterV1 {
        return .{
            .context = self,
            .authority = self.authority,
            .quote_fn = quoteCallback,
            .allocate_fn = allocateCallback,
            .free_fn = freeCallback,
        };
    }

    pub fn failNextAllocationAtOrdinal(
        self: *FakeBackendV1,
        ordinal: ?u64,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fail_allocate_ordinal = ordinal;
    }

    pub fn failNextFreeForBinding(
        self: *FakeBackendV1,
        binding_sha256: ?Digest,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fail_free_binding_sha256 = binding_sha256;
    }

    pub fn driftNextReportedBytes(
        self: *FakeBackendV1,
        delta: i64,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.report_byte_delta = delta;
    }

    pub fn snapshot(self: *FakeBackendV1) FakeSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var live: usize = 0;
        for (self.objects) |object| {
            if (object.live) live += 1;
        }
        return .{
            .authority_epoch = self.authority.authority_epoch,
            .used_bytes = self.used_bytes,
            .live_objects = live,
            .materialized_leases = @intFromBool(!digestIsZero(
                self.active_admission_sha256,
            )),
            .allocate_calls = self.allocate_calls,
            .free_calls = self.free_calls,
            .injected_allocate_failures = self.injected_allocate_failures,
            .injected_free_failures = self.injected_free_failures,
        };
    }

    fn quoteCallback(
        context: *anyopaque,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) CallbackError!AllocationQuoteV1 {
        const self: *FakeBackendV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (digestIsZero(binding_sha256) or requested_bytes == 0)
            return CallbackError.InvalidRequest;
        const charged_bytes = alignForward(
            requested_bytes,
            self.authority.allocation_granularity_bytes,
        ) catch return CallbackError.CapacityExceeded;
        if (charged_bytes >
            self.authority.max_single_allocation_bytes)
            return CallbackError.CapacityExceeded;
        return makeQuoteV1(
            self.authority,
            binding_sha256,
            requested_bytes,
            charged_bytes,
        ) catch return CallbackError.InvalidRequest;
    }

    fn allocateCallback(
        context: *anyopaque,
        call: AllocationCallV1,
    ) CallbackError!BackendObjectV1 {
        const self: *FakeBackendV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        validateAllocationCallV1(call) catch
            return CallbackError.InvalidRequest;
        if (!digestEqual(
            call.authority_sha256,
            self.authority.authority_sha256,
        ) or call.charged_bytes >
            self.authority.max_single_allocation_bytes)
            return CallbackError.InvalidRequest;
        const quote = quoteCallbackUnlocked(
            self.authority,
            call.binding_sha256,
            call.requested_bytes,
        ) catch return CallbackError.InvalidRequest;
        if (call.charged_bytes != quote.charged_bytes or
            !digestEqual(call.quote_sha256, quote.quote_sha256))
            return CallbackError.InvalidRequest;
        if (!digestIsZero(self.active_admission_sha256) and
            !digestEqual(
                self.active_admission_sha256,
                call.admission_sha256,
            ))
            return CallbackError.CapacityExceeded;
        for (self.objects) |object| {
            if (object.live and
                digestEqual(
                    object.call.admission_sha256,
                    call.admission_sha256,
                ) and object.call.ordinal == call.ordinal)
                return CallbackError.StaleObject;
        }
        self.allocate_calls +|= 1;
        if (self.fail_allocate_ordinal) |ordinal| {
            if (ordinal == call.ordinal) {
                self.fail_allocate_ordinal = null;
                self.injected_allocate_failures +|= 1;
                return CallbackError.InjectedFailure;
            }
        }
        const next_used = std.math.add(
            u64,
            self.used_bytes,
            call.charged_bytes,
        ) catch return CallbackError.CapacityExceeded;
        if (next_used > self.authority.max_total_device_bytes)
            return CallbackError.CapacityExceeded;
        var slot_index: ?usize = null;
        for (self.objects, 0..) |object, index| {
            if (!object.live) {
                slot_index = index;
                break;
            }
        }
        const index = slot_index orelse
            return CallbackError.CapacityExceeded;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return CallbackError.Unavailable;
        const generation = self.next_generation;
        self.next_generation += 1;
        const identity = fakeObjectIdentityV1(
            self.authority,
            @intCast(index),
            generation,
            call.call_sha256,
        );
        var reported = call.charged_bytes;
        if (self.report_byte_delta != 0) {
            const delta = self.report_byte_delta;
            self.report_byte_delta = 0;
            if (delta > 0) {
                reported = std.math.add(
                    u64,
                    reported,
                    @intCast(delta),
                ) catch return CallbackError.CapacityExceeded;
            } else {
                // Avoid negating minInt(i64), whose magnitude still fits u64.
                const magnitude: u64 =
                    @as(u64, @intCast(-(delta + 1))) + 1;
                reported = if (magnitude >= reported)
                    0
                else
                    reported - magnitude;
            }
        }
        var object: BackendObjectV1 = .{
            .allocation_call_sha256 = call.call_sha256,
            .binding_sha256 = call.binding_sha256,
            .backend_object_sha256 = identity,
            .backend_object_generation = generation,
            .allocated_bytes = reported,
        };
        object.object_sha256 = backendObjectRootV1(object);
        self.objects[index] = .{
            .live = true,
            .generation = generation,
            .call = call,
            .object = object,
            .actual_charged_bytes = call.charged_bytes,
        };
        self.used_bytes = next_used;
        self.active_admission_sha256 = call.admission_sha256;
        return object;
    }

    fn freeCallback(
        context: *anyopaque,
        object: BackendObjectV1,
    ) CallbackError!void {
        const self: *FakeBackendV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.free_calls +|= 1;
        var found: ?usize = null;
        for (self.objects, 0..) |candidate, index| {
            if (candidate.live and
                candidate.generation ==
                    object.backend_object_generation and
                digestEqual(
                    candidate.object.backend_object_sha256,
                    object.backend_object_sha256,
                ) and digestEqual(
                candidate.call.call_sha256,
                object.allocation_call_sha256,
            )) {
                found = index;
                break;
            }
        }
        const index = found orelse return CallbackError.StaleObject;
        const slot = &self.objects[index];
        if (self.fail_free_binding_sha256) |binding| {
            if (digestEqual(binding, slot.call.binding_sha256)) {
                self.fail_free_binding_sha256 = null;
                self.injected_free_failures +|= 1;
                return CallbackError.InjectedFailure;
            }
        }
        self.used_bytes = std.math.sub(
            u64,
            self.used_bytes,
            slot.actual_charged_bytes,
        ) catch return CallbackError.InvalidRequest;
        slot.* = .{};
        var any_live = false;
        for (self.objects) |candidate| {
            if (candidate.live) {
                any_live = true;
                break;
            }
        }
        if (!any_live)
            self.active_admission_sha256 = zero_digest;
    }
};

fn fakeObjectIdentityV1(
    authority: AllocationAuthorityV1,
    slot_index: u32,
    generation: u64,
    call_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(fake_object_identity_domain);
    hash.update(&authority.authority_sha256);
    hashU64(&hash, slot_index);
    hashU64(&hash, generation);
    hash.update(&call_sha256);
    return finish(&hash);
}

pub fn makeFakeQuoteV1(
    authority: AllocationAuthorityV1,
    binding_sha256: Digest,
    requested_bytes: u64,
) Error!AllocationQuoteV1 {
    try validateAuthorityV1(authority);
    if (digestIsZero(binding_sha256) or requested_bytes == 0)
        return Error.InvalidQuote;
    const charged_bytes = try alignForward(
        requested_bytes,
        authority.allocation_granularity_bytes,
    );
    return makeQuoteV1(
        authority,
        binding_sha256,
        requested_bytes,
        charged_bytes,
    );
}

fn quoteCallbackUnlocked(
    authority: AllocationAuthorityV1,
    binding_sha256: Digest,
    requested_bytes: u64,
) CallbackError!AllocationQuoteV1 {
    return makeFakeQuoteV1(
        authority,
        binding_sha256,
        requested_bytes,
    ) catch |err| return switch (err) {
        Error.ArithmeticOverflow => CallbackError.CapacityExceeded,
        else => CallbackError.InvalidRequest,
    };
}

fn alignForward(value: u64, alignment: u64) Error!u64 {
    if (value == 0 or alignment == 0 or
        !std.math.isPowerOfTwo(alignment))
        return Error.InvalidConfiguration;
    const mask = alignment - 1;
    const with_mask = std.math.add(
        u64,
        value,
        mask,
    ) catch return Error.ArithmeticOverflow;
    return with_mask & ~mask;
}

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource.Claim,
) void {
    inline for (std.meta.fields(resource.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn finish(
    hash: *std.crypto.hash.sha2.Sha256,
) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn digestIsZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &zero_digest);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn digestLessThan(left: Digest, right: Digest) bool {
    return std.mem.order(u8, &left, &right) == .lt;
}

fn digest(value: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &result, .{});
    return result;
}

const TestFixture = struct {
    entries: [3]device.DeviceInventoryEntryV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    allocation_entries: [3]AllocationEntryV1,
    manifest: AllocationManifestV1,
    authority: AllocationAuthorityV1,
};

fn testCapability(
    backend: device.BackendKindV1,
    class: device.DeviceClassV1,
    label: []const u8,
) !device.DeviceCapabilityV1 {
    const profiles =
        device.OperationProfileBitsV1.dequantize_int4_f16 |
        device.OperationProfileBitsV1.matmul_f16_bounded |
        device.OperationProfileBitsV1.matvec_int4_f32_bounded;
    return device.sealCapabilityV1(.{
        .backend_kind = backend,
        .device_class = class,
        .operation_profile_bits = profiles,
        .operator_bits = device.profileOperatorBitsV1(profiles),
        .element_type_bits = device.profileElementTypeBitsV1(profiles),
        .numerical_policy_bits = device.profileNumericalPolicyBitsV1(profiles),
        .feature_bits = device.FeatureBitsV1.allocation |
            device.FeatureBitsV1.dispatch |
            device.FeatureBitsV1.completion_fence,
        .max_single_allocation_bytes = 4_096,
        .max_total_device_bytes = 8_192,
        .max_queue_slots = 1,
        .backend_sha256 = digest("test allocation backend"),
        .device_sha256 = digest(label),
        .driver_sha256 = digest("test allocation driver"),
        .placement_sha256 = digest("test allocation placement"),
    });
}

fn testEntry(
    capability: device.DeviceCapabilityV1,
    epoch: u64,
    rank: u64,
) !device.DeviceInventoryEntryV1 {
    return device.sealInventoryEntryV1(.{
        .discovery_epoch = epoch,
        .policy_rank = rank,
        .capability = capability,
    });
}

fn testFixture() !TestFixture {
    const gpu_a = try testCapability(.metal, .accelerator, "lease gpu a");
    const gpu_b = try testCapability(
        .portable_compute,
        .accelerator,
        "lease gpu b",
    );
    const cpu = try testCapability(.cpu, .cpu, "lease cpu");
    const inventory = [3]device.DeviceInventoryEntryV1{
        try testEntry(gpu_a, 10, 5),
        try testEntry(gpu_b, 20, 1),
        try testEntry(cpu, 30, 0),
    };
    const profiles =
        device.OperationProfileBitsV1.dequantize_int4_f16 |
        device.OperationProfileBitsV1.matmul_f16_bounded |
        device.OperationProfileBitsV1.matvec_int4_f32_bounded;
    const requirement = try device.sealRequirementV1(.{
        .plan_sha256 = digest("device allocation execution plan"),
        .required_device_class = .accelerator,
        .required_operation_profile_bits = profiles,
        .required_operator_bits = device.profileOperatorBitsV1(profiles),
        .required_element_type_bits = device.profileElementTypeBitsV1(profiles),
        .required_numerical_policy_bits = device.profileNumericalPolicyBitsV1(profiles),
        .required_feature_bits = device.FeatureBitsV1.allocation,
        .largest_single_allocation_bytes = 4_096,
        .total_device_bytes = 8_192,
        .queue_slots = 1,
        .fallback_policy = .explicit_cpu,
    });
    const selection = try device.selectDeviceV1(
        requirement,
        &inventory,
    );
    const authority = try makeAuthorityV1(
        77,
        1,
        3,
        1_024,
        inventory[selection.selected_index],
        digest("fake allocation authority"),
    );
    var allocation_entries = [3]AllocationEntryV1{
        .{
            .binding_sha256 = digest("activation allocation"),
            .requested_bytes = 1_000,
        },
        .{
            .binding_sha256 = digest("kv allocation"),
            .requested_bytes = 3_000,
        },
        .{
            .binding_sha256 = digest("weight allocation"),
            .requested_bytes = 4_000,
        },
    };
    for (&allocation_entries) |*entry| {
        const quote = try makeFakeQuoteV1(
            authority,
            entry.binding_sha256,
            entry.requested_bytes,
        );
        entry.charged_bytes = quote.charged_bytes;
        entry.quote_sha256 = quote.quote_sha256;
    }
    std.mem.sort(
        AllocationEntryV1,
        &allocation_entries,
        {},
        struct {
            fn lessThan(
                _: void,
                left: AllocationEntryV1,
                right: AllocationEntryV1,
            ) bool {
                return digestLessThan(
                    left.binding_sha256,
                    right.binding_sha256,
                );
            }
        }.lessThan,
    );
    const manifest = try sealManifestV1(&allocation_entries);
    return .{
        .entries = inventory,
        .requirement = requirement,
        .selection = selection.receipt,
        .allocation_entries = allocation_entries,
        .manifest = manifest,
        .authority = authority,
    };
}

const TestRuntime = struct {
    bank_slots: [1]resource.Slot = .{.{}},
    child_slots: [1]resource.ChildSlot = .{.{}},
    bank: resource.Bank = undefined,
    parent: resource.Receipt = undefined,
    coordinator_slots: [1]CoordinatorSlotV1 = .{.{}},
    coordinator_objects: [3]CoordinatorObjectSlotV1 =
        [_]CoordinatorObjectSlotV1{.{}} ** 3,
    coordinator: CoordinatorV1 = undefined,
    fake_objects: [3]FakeObjectSlotV1 =
        [_]FakeObjectSlotV1{.{}} ** 3,
    fake: FakeBackendV1 = undefined,

    fn init(
        self: *TestRuntime,
        fixture: TestFixture,
    ) !void {
        self.bank = try resource.Bank.initWithChildSlots(
            &self.bank_slots,
            &self.child_slots,
            .{
                .host_bytes = 1_024,
                .capsule_bytes = 1_024,
                .device_bytes = 8_192,
                .queue_slots = 1,
            },
            41,
        );
        self.parent = try self.bank.commit(
            try self.bank.reserve(9001, .{
                .capsule_bytes = 64,
                .queue_slots = 1,
            }),
        );
        self.coordinator = try CoordinatorV1.init(
            51,
            &self.coordinator_slots,
            &self.coordinator_objects,
        );
        self.fake = try FakeBackendV1.init(
            fixture.authority,
            &self.fake_objects,
        );
    }

    fn makeRequest(
        self: *TestRuntime,
        fixture: TestFixture,
    ) !AllocationRequestV1 {
        return makeRequestV1(
            61,
            digest("allocation request owner"),
            fixture.authority,
            fixture.selection,
            fixture.requirement,
            &fixture.entries,
            self.parent,
            fixture.manifest,
            &fixture.allocation_entries,
        );
    }

    fn admit(
        self: *TestRuntime,
        fixture: TestFixture,
        allocation_request: AllocationRequestV1,
    ) !AllocationAdmissionV1 {
        return self.coordinator.admit(
            &self.bank,
            self.fake.adapter(),
            allocation_request,
            fixture.selection,
            fixture.requirement,
            &fixture.entries,
            self.parent,
            fixture.manifest,
            &fixture.allocation_entries,
        );
    }
};

test "receipt-bound fake allocation cancel then materialize and release" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    const request = try runtime.makeRequest(fixture);

    const first = try runtime.admit(fixture, request);
    try std.testing.expectEqual(@as(u64, 8_192), (try runtime.bank.snapshot()).used.device_bytes);
    try std.testing.expectError(
        resource.Error.InvalidTransition,
        runtime.bank.release(runtime.parent),
    );
    const cancelled = try runtime.coordinator.cancelAdmission(
        &runtime.bank,
        first,
    );
    try std.testing.expectEqual(
        TerminalOutcomeV1.cancelled,
        cancelled.outcome,
    );
    try std.testing.expectEqual(@as(u64, 0), (try runtime.bank.snapshot()).used.device_bytes);

    const second = try runtime.admit(fixture, request);
    try std.testing.expect(second.generation > first.generation);
    const materialized = try runtime.coordinator.materialize(
        &runtime.bank,
        second,
        runtime.fake.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 8_192), runtime.fake.snapshot().used_bytes);
    const released = try runtime.coordinator.release(
        &runtime.bank,
        lease,
        runtime.fake.adapter(),
    );
    const terminal = switch (released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        TerminalOutcomeV1.released,
        terminal.outcome,
    );
    try std.testing.expectEqual(@as(u64, 0), runtime.fake.snapshot().used_bytes);
    try std.testing.expectEqual(@as(u64, 0), (try runtime.bank.snapshot()).used.device_bytes);
    const snapshot = runtime.coordinator.snapshot();
    try std.testing.expectEqual(@as(usize, 0), snapshot.live_leases);
    try std.testing.expectEqual(@as(usize, 0), snapshot.live_objects);
    try std.testing.expectError(
        Error.StaleHandle,
        runtime.coordinator.release(
            &runtime.bank,
            lease,
            runtime.fake.adapter(),
        ),
    );
    try runtime.bank.release(runtime.parent);
    try std.testing.expect((try runtime.bank.snapshot()).used.isZero());
}

test "allocation failure and cancellation at every boundary leak nothing" {
    const fixture = try testFixture();
    for (0..fixture.allocation_entries.len) |fail_ordinal| {
        var runtime: TestRuntime = .{};
        try runtime.init(fixture);
        const admission = try runtime.admit(
            fixture,
            try runtime.makeRequest(fixture),
        );
        runtime.fake.failNextAllocationAtOrdinal(fail_ordinal);
        const outcome = try runtime.coordinator.materialize(
            &runtime.bank,
            admission,
            runtime.fake.adapter(),
            .{},
        );
        const terminal = switch (outcome) {
            .terminal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(
            TerminalOutcomeV1.allocation_failed,
            terminal.outcome,
        );
        try std.testing.expectEqual(@as(u64, 0), runtime.fake.snapshot().used_bytes);
        try std.testing.expectEqual(@as(u64, 0), (try runtime.bank.snapshot()).used.device_bytes);
        try runtime.bank.release(runtime.parent);
    }

    for (0..fixture.allocation_entries.len + 1) |boundary| {
        var runtime: TestRuntime = .{};
        try runtime.init(fixture);
        const admission = try runtime.admit(
            fixture,
            try runtime.makeRequest(fixture),
        );
        var probe = CancelAtBoundary{ .target = boundary };
        const outcome = try runtime.coordinator.materialize(
            &runtime.bank,
            admission,
            runtime.fake.adapter(),
            probe.probe(),
        );
        const terminal = switch (outcome) {
            .terminal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(
            TerminalOutcomeV1.cancelled,
            terminal.outcome,
        );
        try std.testing.expectEqual(@as(u64, 0), runtime.fake.snapshot().used_bytes);
        try std.testing.expectEqual(@as(u64, 0), (try runtime.bank.snapshot()).used.device_bytes);
        try runtime.bank.release(runtime.parent);
    }
}

const CancelAtBoundary = struct {
    target: u64,

    fn probe(self: *CancelAtBoundary) CancellationProbeV1 {
        return .{
            .context = self,
            .cancelled_fn = check,
        };
    }

    fn check(context: *anyopaque, boundary: u64) bool {
        const self: *CancelAtBoundary =
            @ptrCast(@alignCast(context));
        return self.target == boundary;
    }
};

const MalformedObjectAdapter = struct {
    inner: AdapterV1,
    malformed_ordinal: u64,
    reported_bytes: u64,
    fail_matching_free_once: bool = true,

    fn adapter(self: *MalformedObjectAdapter) AdapterV1 {
        return .{
            .context = self,
            .authority = self.inner.authority,
            .quote_fn = quote,
            .allocate_fn = allocate,
            .free_fn = free,
        };
    }

    fn quote(
        context: *anyopaque,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) CallbackError!AllocationQuoteV1 {
        const self: *MalformedObjectAdapter =
            @ptrCast(@alignCast(context));
        return self.inner.quote_fn(
            self.inner.context,
            binding_sha256,
            requested_bytes,
        );
    }

    fn allocate(
        context: *anyopaque,
        call: AllocationCallV1,
    ) CallbackError!BackendObjectV1 {
        const self: *MalformedObjectAdapter =
            @ptrCast(@alignCast(context));
        var object = try self.inner.allocate_fn(
            self.inner.context,
            call,
        );
        if (call.ordinal == self.malformed_ordinal) {
            object.allocated_bytes = self.reported_bytes;
            object.object_sha256 = backendObjectRootV1(object);
        }
        return object;
    }

    fn free(
        context: *anyopaque,
        object: BackendObjectV1,
    ) CallbackError!void {
        const self: *MalformedObjectAdapter =
            @ptrCast(@alignCast(context));
        if (self.fail_matching_free_once and
            object.allocated_bytes == self.reported_bytes)
        {
            self.fail_matching_free_once = false;
            return CallbackError.InjectedFailure;
        }
        return self.inner.free_fn(self.inner.context, object);
    }
};

test "failed free retains charge and recovery generation fences retry" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    const admission = try runtime.admit(
        fixture,
        try runtime.makeRequest(fixture),
    );
    const materialized = try runtime.coordinator.materialize(
        &runtime.bank,
        admission,
        runtime.fake.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    runtime.fake.failNextFreeForBinding(
        fixture.allocation_entries[1].binding_sha256,
    );
    const release = try runtime.coordinator.release(
        &runtime.bank,
        lease,
        runtime.fake.adapter(),
    );
    const recovery = switch (release) {
        .recovery_required => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var oversized_recovery = recovery;
    oversized_recovery.outstanding_object_count =
        maximum_allocations + 1;
    oversized_recovery.recovery_sha256 =
        recoveryRootV1(oversized_recovery);
    try std.testing.expectError(
        Error.InvalidRecovery,
        validateRecoveryV1(oversized_recovery),
    );
    try std.testing.expectEqual(@as(u64, 8_192), (try runtime.bank.snapshot()).used.device_bytes);
    try std.testing.expect(recovery.outstanding_object_count > 0);
    try std.testing.expectError(
        Error.StaleHandle,
        runtime.coordinator.release(
            &runtime.bank,
            lease,
            runtime.fake.adapter(),
        ),
    );
    const retried = try runtime.coordinator.retryRecovery(
        &runtime.bank,
        recovery,
        runtime.fake.adapter(),
    );
    const terminal = switch (retried) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        TerminalOutcomeV1.released,
        terminal.outcome,
    );
    try std.testing.expectEqual(@as(u64, 0), runtime.fake.snapshot().used_bytes);
    try std.testing.expectEqual(@as(u64, 0), (try runtime.bank.snapshot()).used.device_bytes);
    try std.testing.expectError(
        Error.StaleHandle,
        runtime.coordinator.retryRecovery(
            &runtime.bank,
            recovery,
            runtime.fake.adapter(),
        ),
    );
    try runtime.bank.release(runtime.parent);
}

test "quoted versus allocated byte drift rolls back conservatively" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    const admission = try runtime.admit(
        fixture,
        try runtime.makeRequest(fixture),
    );
    runtime.fake.driftNextReportedBytes(1);
    const outcome = try runtime.coordinator.materialize(
        &runtime.bank,
        admission,
        runtime.fake.adapter(),
        .{},
    );
    const terminal = switch (outcome) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        TerminalReasonV1.backend_protocol_violation,
        terminal.reason,
    );
    try std.testing.expectEqual(@as(u64, 0), runtime.fake.snapshot().used_bytes);
    try std.testing.expectEqual(@as(u64, 0), (try runtime.bank.snapshot()).used.device_bytes);
    try runtime.bank.release(runtime.parent);
}

test "malformed object evidence with failed cleanup uses trusted recovery bytes" {
    const fixture = try testFixture();
    const malformed_values = [_]u64{
        0,
        std.math.maxInt(u64),
    };
    for (malformed_values) |reported_bytes| {
        var runtime: TestRuntime = .{};
        try runtime.init(fixture);
        var malformed: MalformedObjectAdapter = .{
            .inner = runtime.fake.adapter(),
            .malformed_ordinal = 1,
            .reported_bytes = reported_bytes,
        };
        const request = try runtime.makeRequest(fixture);
        const admission = try runtime.coordinator.admit(
            &runtime.bank,
            malformed.adapter(),
            request,
            fixture.selection,
            fixture.requirement,
            &fixture.entries,
            runtime.parent,
            fixture.manifest,
            &fixture.allocation_entries,
        );
        const outcome = try runtime.coordinator.materialize(
            &runtime.bank,
            admission,
            malformed.adapter(),
            .{},
        );
        const recovery = switch (outcome) {
            .recovery_required => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(
            @as(u64, 1),
            recovery.outstanding_object_count,
        );
        try std.testing.expectEqual(
            fixture.allocation_entries[1].charged_bytes,
            recovery.outstanding_bytes,
        );
        try std.testing.expectEqual(
            @as(u64, 8_192),
            (try runtime.bank.snapshot()).used.device_bytes,
        );
        const retried = try runtime.coordinator.retryRecovery(
            &runtime.bank,
            recovery,
            malformed.adapter(),
        );
        const terminal = switch (retried) {
            .terminal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(
            TerminalReasonV1.backend_protocol_violation,
            terminal.reason,
        );
        try std.testing.expectEqual(
            @as(u64, 0),
            runtime.fake.snapshot().used_bytes,
        );
        try runtime.bank.release(runtime.parent);
    }
}

test "malformed cancellation probe fails before allocation and remains cancellable" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    const admission = try runtime.admit(
        fixture,
        try runtime.makeRequest(fixture),
    );
    const malformed: CancellationProbeV1 = .{
        .cancelled_fn = CancelAtBoundary.check,
    };
    try std.testing.expectError(
        Error.InvalidConfiguration,
        runtime.coordinator.materialize(
            &runtime.bank,
            admission,
            runtime.fake.adapter(),
            malformed,
        ),
    );
    const coordinator_snapshot = runtime.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 1),
        coordinator_snapshot.admitted_leases,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        coordinator_snapshot.live_objects,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        runtime.fake.snapshot().allocate_calls,
    );
    _ = try runtime.coordinator.cancelAdmission(
        &runtime.bank,
        admission,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        (try runtime.bank.snapshot()).used.device_bytes,
    );
    try runtime.bank.release(runtime.parent);
}

test "materialize and release require the exact admitted adapter instance" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    const admission = try runtime.admit(
        fixture,
        try runtime.makeRequest(fixture),
    );
    var foreign_slots =
        [_]FakeObjectSlotV1{.{}} ** 3;
    var foreign = try FakeBackendV1.init(
        fixture.authority,
        &foreign_slots,
    );
    try std.testing.expectError(
        Error.InvalidAdapter,
        runtime.coordinator.materialize(
            &runtime.bank,
            admission,
            foreign.adapter(),
            .{},
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        foreign.snapshot().allocate_calls,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        runtime.fake.snapshot().allocate_calls,
    );
    _ = try runtime.coordinator.cancelAdmission(
        &runtime.bank,
        admission,
    );
    try runtime.bank.release(runtime.parent);
}

test "terminal transitions require the exact admitted ResourceBank instance" {
    const fixture = try testFixture();
    var original: TestRuntime = .{};
    var mirror: TestRuntime = .{};
    try original.init(fixture);
    try mirror.init(fixture);
    const original_admission = try original.admit(
        fixture,
        try original.makeRequest(fixture),
    );
    const mirror_admission = try mirror.admit(
        fixture,
        try mirror.makeRequest(fixture),
    );
    try std.testing.expectEqualDeep(
        original_admission,
        mirror_admission,
    );
    const original_before = try original.bank.snapshotV2();
    const mirror_before = try mirror.bank.snapshotV2();
    try std.testing.expectError(
        Error.InvalidBank,
        original.coordinator.cancelAdmission(
            &mirror.bank,
            original_admission,
        ),
    );
    try std.testing.expectEqualDeep(
        original_before,
        try original.bank.snapshotV2(),
    );
    try std.testing.expectEqualDeep(
        mirror_before,
        try mirror.bank.snapshotV2(),
    );
    _ = try original.coordinator.cancelAdmission(
        &original.bank,
        original_admission,
    );
    _ = try mirror.coordinator.cancelAdmission(
        &mirror.bank,
        mirror_admission,
    );
    try original.bank.release(original.parent);
    try mirror.bank.release(mirror.parent);
}

test "shared fake authority enforces one materialized lease across coordinators" {
    const fixture = try testFixture();
    var first_runtime: TestRuntime = .{};
    var second_runtime: TestRuntime = .{};
    try first_runtime.init(fixture);
    try second_runtime.init(fixture);
    const shared_adapter = first_runtime.fake.adapter();
    const first_admission = try first_runtime.admit(
        fixture,
        try first_runtime.makeRequest(fixture),
    );
    const second_request = try second_runtime.makeRequest(fixture);
    const second_admission = try second_runtime.coordinator.admit(
        &second_runtime.bank,
        shared_adapter,
        second_request,
        fixture.selection,
        fixture.requirement,
        &fixture.entries,
        second_runtime.parent,
        fixture.manifest,
        &fixture.allocation_entries,
    );
    const first_outcome =
        try first_runtime.coordinator.materialize(
            &first_runtime.bank,
            first_admission,
            shared_adapter,
            .{},
        );
    const first_lease = switch (first_outcome) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        @as(usize, 1),
        first_runtime.fake.snapshot().materialized_leases,
    );
    const second_outcome =
        try second_runtime.coordinator.materialize(
            &second_runtime.bank,
            second_admission,
            shared_adapter,
            .{},
        );
    const second_terminal = switch (second_outcome) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        TerminalOutcomeV1.allocation_failed,
        second_terminal.outcome,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        (try second_runtime.bank.snapshot()).used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        first_runtime.fake.snapshot().live_objects,
    );
    const released = try first_runtime.coordinator.release(
        &first_runtime.bank,
        first_lease,
        shared_adapter,
    );
    switch (released) {
        .terminal => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        first_runtime.fake.snapshot().materialized_leases,
    );
    try first_runtime.bank.release(first_runtime.parent);
    try second_runtime.bank.release(second_runtime.parent);
}

test "live quote replay rejects self-consistent caller quote drift before charge" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    var forged_entries = fixture.allocation_entries;
    for (&forged_entries) |*entry| {
        if (entry.requested_bytes == 1_000) {
            entry.requested_bytes = 1_500;
            entry.charged_bytes = 3_072;
        } else if (entry.requested_bytes == 3_000) {
            entry.requested_bytes = 500;
            entry.charged_bytes = 1_024;
        }
        const forged_quote = try makeQuoteV1(
            fixture.authority,
            entry.binding_sha256,
            entry.requested_bytes,
            entry.charged_bytes,
        );
        entry.quote_sha256 = forged_quote.quote_sha256;
    }
    const forged_manifest = try sealManifestV1(&forged_entries);
    const forged_request = try makeRequestV1(
        61,
        digest("allocation request owner"),
        fixture.authority,
        fixture.selection,
        fixture.requirement,
        &fixture.entries,
        runtime.parent,
        forged_manifest,
        &forged_entries,
    );
    const bank_before = try runtime.bank.snapshotV2();
    const coordinator_before = runtime.coordinator.snapshot();
    const backend_before = runtime.fake.snapshot();
    try std.testing.expectError(
        Error.InvalidQuote,
        runtime.coordinator.admit(
            &runtime.bank,
            runtime.fake.adapter(),
            forged_request,
            fixture.selection,
            fixture.requirement,
            &fixture.entries,
            runtime.parent,
            forged_manifest,
            &forged_entries,
        ),
    );
    try std.testing.expectEqualDeep(
        bank_before,
        try runtime.bank.snapshotV2(),
    );
    try std.testing.expectEqualDeep(
        coordinator_before,
        runtime.coordinator.snapshot(),
    );
    try std.testing.expectEqualDeep(
        backend_before,
        runtime.fake.snapshot(),
    );
    try runtime.bank.release(runtime.parent);
}

test "partial allocation cleanup failure retains charge until recovery" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    const admission = try runtime.admit(
        fixture,
        try runtime.makeRequest(fixture),
    );
    runtime.fake.failNextAllocationAtOrdinal(2);
    runtime.fake.failNextFreeForBinding(
        fixture.allocation_entries[1].binding_sha256,
    );
    const materialized = try runtime.coordinator.materialize(
        &runtime.bank,
        admission,
        runtime.fake.adapter(),
        .{},
    );
    const recovery = switch (materialized) {
        .recovery_required => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        TerminalOutcomeV1.allocation_failed,
        recovery.target_outcome,
    );
    try std.testing.expectEqual(@as(u64, 8_192), (try runtime.bank.snapshot()).used.device_bytes);
    try std.testing.expectEqual(@as(usize, 1), runtime.fake.snapshot().live_objects);
    const retried = try runtime.coordinator.retryRecovery(
        &runtime.bank,
        recovery,
        runtime.fake.adapter(),
    );
    const terminal = switch (retried) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        TerminalOutcomeV1.allocation_failed,
        terminal.outcome,
    );
    try std.testing.expectEqual(@as(u64, 0), runtime.fake.snapshot().used_bytes);
    try std.testing.expectEqual(@as(u64, 0), (try runtime.bank.snapshot()).used.device_bytes);
    try runtime.bank.release(runtime.parent);
}

test "foreign authority and stale copied admissions fail before mutation" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    const request = try runtime.makeRequest(fixture);
    var foreign = fixture.authority;
    foreign.backend_authority_sha256 = digest("foreign allocator");
    foreign.authority_sha256 = authorityRootV1(foreign);
    var foreign_adapter = runtime.fake.adapter();
    foreign_adapter.authority = foreign;
    const before = try runtime.bank.snapshotV2();
    try std.testing.expectError(
        Error.InvalidRequest,
        runtime.coordinator.admit(
            &runtime.bank,
            foreign_adapter,
            request,
            fixture.selection,
            fixture.requirement,
            &fixture.entries,
            runtime.parent,
            fixture.manifest,
            &fixture.allocation_entries,
        ),
    );
    try std.testing.expectEqualDeep(before, try runtime.bank.snapshotV2());

    const admission = try runtime.admit(fixture, request);
    _ = try runtime.coordinator.cancelAdmission(
        &runtime.bank,
        admission,
    );
    try std.testing.expectError(
        Error.StaleHandle,
        runtime.coordinator.cancelAdmission(
            &runtime.bank,
            admission,
        ),
    );
    try runtime.bank.release(runtime.parent);
}

test "authority composition and quote granularity fail before admission" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);

    var multi_lease = fixture.authority;
    multi_lease.maximum_leases = 2;
    multi_lease.authority_sha256 =
        authorityRootV1(multi_lease);
    try std.testing.expectError(
        Error.InvalidAuthority,
        validateAuthorityV1(multi_lease),
    );

    var misaligned_quote = fixture.allocation_entries[0];
    misaligned_quote.charged_bytes += 1;
    const quote_value: AllocationQuoteV1 = .{
        .authority_sha256 = fixture.authority.authority_sha256,
        .binding_sha256 = misaligned_quote.binding_sha256,
        .requested_bytes = misaligned_quote.requested_bytes,
        .charged_bytes = misaligned_quote.charged_bytes,
    };
    var sealed_misaligned = quote_value;
    sealed_misaligned.quote_sha256 =
        quoteRootV1(sealed_misaligned);
    try std.testing.expectError(
        Error.InvalidQuote,
        validateQuoteV1(
            sealed_misaligned,
            fixture.authority,
        ),
    );

    var stale_authority = fixture.authority;
    stale_authority.selected_discovery_epoch += 1;
    stale_authority.authority_sha256 =
        authorityRootV1(stale_authority);
    var stale_entries = fixture.allocation_entries;
    for (&stale_entries) |*entry| {
        const quote = try makeFakeQuoteV1(
            stale_authority,
            entry.binding_sha256,
            entry.requested_bytes,
        );
        entry.charged_bytes = quote.charged_bytes;
        entry.quote_sha256 = quote.quote_sha256;
    }
    const stale_manifest = try sealManifestV1(
        &stale_entries,
    );
    try std.testing.expectError(
        Error.InvalidRequest,
        makeRequestV1(
            61,
            digest("allocation request owner"),
            stale_authority,
            fixture.selection,
            fixture.requirement,
            &fixture.entries,
            runtime.parent,
            stale_manifest,
            &stale_entries,
        ),
    );
    try runtime.bank.release(runtime.parent);
}

test "public object validators replay nested call and admission evidence" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    const admission = try runtime.admit(
        fixture,
        try runtime.makeRequest(fixture),
    );
    const materialized = try runtime.coordinator.materialize(
        &runtime.bank,
        admission,
        runtime.fake.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var calls: [3]AllocationCallV1 = undefined;
    var objects: [3]BackendObjectV1 = undefined;
    try runtime.coordinator.copyMaterializationInOrder(
        admission.slot_index,
        admission.generation,
        &calls,
        &objects,
    );
    var malformed_call = calls[0];
    malformed_call.ordinal = maximum_allocations;
    try std.testing.expectError(
        Error.InvalidBackendObject,
        validateBackendObjectV1(
            objects[0],
            malformed_call,
        ),
    );
    var malformed_admission = admission;
    malformed_admission.generation = 0;
    try std.testing.expectError(
        Error.InvalidObjectSet,
        validateObjectSetV1(
            runtime.coordinator.slots[
                admission.slot_index
            ].object_set,
            malformed_admission,
            &calls,
            &objects,
        ),
    );
    const released = try runtime.coordinator.release(
        &runtime.bank,
        lease,
        runtime.fake.adapter(),
    );
    switch (released) {
        .terminal => {},
        else => return error.TestUnexpectedResult,
    }
    try runtime.bank.release(runtime.parent);
}

test "allocation lifecycle literal golden roots stay stable" {
    const fixture = try testFixture();
    var runtime: TestRuntime = .{};
    try runtime.init(fixture);
    const request = try runtime.makeRequest(fixture);
    const first = try runtime.admit(fixture, request);
    const cancelled = try runtime.coordinator.cancelAdmission(
        &runtime.bank,
        first,
    );
    const second = try runtime.admit(fixture, request);
    const materialized = try runtime.coordinator.materialize(
        &runtime.bank,
        second,
        runtime.fake.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    runtime.fake.failNextFreeForBinding(
        fixture.allocation_entries[1].binding_sha256,
    );
    const released = try runtime.coordinator.release(
        &runtime.bank,
        lease,
        runtime.fake.adapter(),
    );
    const recovery = switch (released) {
        .recovery_required => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const retried = try runtime.coordinator.retryRecovery(
        &runtime.bank,
        recovery,
        runtime.fake.adapter(),
    );
    const terminal = switch (retried) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualDeep(
        try goldenDigest("9cb59d992fd5e0ada234f70f8113c1978ca576988144a62c1ccf554c1622820c"),
        fixture.authority.authority_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("3a9de9c57e4ad39c820e439965322bc8f0110d978bcb01c9e4fc1c1509215d8e"),
        fixture.manifest.manifest_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("ade7fd932b2d2a3f827b0d3368735f38f65c207dcce035d637669a4a3d72f229"),
        request.request_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("9b1cc692024666a2235634bf5360e72e5c00d47703f36c284602369311dbfea9"),
        first.admission_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("9cf1c97a579d687846d48f63207b71b31ecd020d8f43e2d81d518adea9d7e912"),
        cancelled.terminal_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("4e15ba09b470c1fefdf68d32544fc56c00c771a7a40c9dfb095f97d7aa659199"),
        second.admission_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("29b38cab3cc7d7aa06959ce3e9f19612742bf22d3d292b22527b220f8d6b40b6"),
        lease.backend_object_set_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("e42a511222aa3f91b853a810b5c5f21bb49ca8d3dcb0bf7a1a42792b1fd2c6b6"),
        lease.lease_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("c7ba3cd55db25c4066520d1f99536f4c39bbc8e4d5e04308e495e2899d289601"),
        recovery.outstanding_set_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("eb4ded83c6ab2327f083c54bbb07943374ffe245e4c77ccf88233b6b527c5bdb"),
        recovery.recovery_sha256,
    );
    try std.testing.expectEqualDeep(
        try goldenDigest("fa5fb28efc490c4be5f2060e58e21b6b77f0b574c33e6016ee046b48e19199d0"),
        terminal.terminal_sha256,
    );
    const quote_goldens = [_][]const u8{
        "f2b861b318c11f007fe94b8796a13eb94bb49c001f670dfdf0c6eae14b45324f",
        "9c4f99ce7d60ef3d53b40f30c8abca0791e2fc4a0be2f2053bdc67825372704f",
        "30855f74cd6211672a90394e1080ae6657c7019df4248aa873c5a9139ea82aae",
    };
    for (fixture.allocation_entries, quote_goldens) |entry, expected| {
        try std.testing.expectEqualDeep(
            try goldenDigest(expected),
            entry.quote_sha256,
        );
    }
    try runtime.bank.release(runtime.parent);
}

fn goldenDigest(encoded: []const u8) !Digest {
    var result: Digest = undefined;
    _ = try std.fmt.hexToBytes(&result, encoded);
    return result;
}
