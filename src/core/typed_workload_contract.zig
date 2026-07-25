//! Portable, bounded typed-workload plan contract.
//!
//! W4a describes what an open-loop workload is allowed to request. It does
//! not execute models, call adapters, publish results, access an OS service,
//! or define result/evidence records. Those layers bind this plan through its
//! semantic root and remain separately versioned.

const std = @import("std");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const plan_abi: u64 = 0x4757_5457_5000_0001;
pub const profile_abi: u64 = 0x4757_5457_4600_0001;
pub const item_abi: u64 = 0x4757_5457_4900_0001;
pub const support_record_abi: u64 = 0x4757_5457_5300_0001;

pub const plan_magic = [8]u8{ 'G', 'W', 'T', 'W', 'P', '1', 0, 0 };
pub const plan_header_bytes: usize = 384;
pub const profile_record_bytes: usize = 368;
pub const item_record_bytes: usize = 280;
pub const plan_footer_bytes: usize = 32;
pub const allowed_flags: u64 = 0;

pub const maximum_profiles: usize = 16;
pub const maximum_items: usize = 16;
pub const maximum_driver_steps: u64 = 512;
pub const maximum_service_quanta: u64 = 256;
pub const absent: u64 = std.math.maxInt(u64);

pub const maximum_plan_bytes: usize =
    plan_header_bytes +
    maximum_profiles * profile_record_bytes +
    maximum_items * item_record_bytes +
    plan_footer_bytes;

const support_record_domain =
    "glacier-typed-workload-support-record-v1\x00";
const profile_domain = "glacier-typed-workload-profile-v1\x00";
const item_domain = "glacier-typed-workload-item-v1\x00";
const profile_section_domain =
    "glacier-typed-workload-profile-section-v1\x00";
const item_section_domain =
    "glacier-typed-workload-item-section-v1\x00";
const plan_domain = "glacier-typed-workload-plan-v1\x00";
const plan_wire_domain = "glacier-typed-workload-plan-wire-v1\x00";

pub const Error = error{
    AliasedBuffer,
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidEvidence,
    InvalidPlan,
    ItemLimitExceeded,
    ProfileLimitExceeded,
};

pub const LifecycleV1 = enum(u64) {
    stateless = 1,
    stateful = 2,
};

pub const ExecutionUnitV1 = enum(u64) {
    operation = 1,
    token = 2,
    frame = 3,
    sample = 4,
    diffusion_step = 5,
    provider_call = 6,
    tool_call = 7,
};

pub const CancellationBoundaryV1 = enum(u64) {
    before_start = 1,
    between_units = 2,
    cooperative = 3,
    terminal_only = 4,
};

pub const PublicationPolicyV1 = enum(u64) {
    final_only = 1,
    incremental = 2,
    transactional = 3,
};

pub const CorrectnessGateV1 = enum(u64) {
    exact = 1,
    bounded_numeric = 2,
    structural = 3,
    external_verifier = 4,
};

pub const TerminalActionV1 = enum(u64) {
    none = 0,
    cancel = 1,
    timeout = 2,
};

pub const ProfileV1 = struct {
    index: u64,
    family: model.ModelFamilyIdV1,
    operation: model.OperationIdV1,
    input_kind: model.InputKindV1,
    output_kind: model.OutputKindV1,
    numerical_policy: model.NumericalPolicyV1,
    adapter_abi: u64,
    lifecycle: LifecycleV1,
    execution_unit: ExecutionUnitV1,
    cancellation_boundary: CancellationBoundaryV1,
    publication_policy: PublicationPolicyV1,
    correctness_gate: CorrectnessGateV1,
    claim: resource_bank.Claim,
    support_sha256: Digest,
    artifact_sha256: Digest,
    execution_plan_sha256: Digest,
    adapter_implementation_sha256: Digest,
    correctness_sha256: Digest,
    profile_sha256: Digest,
};

pub const ItemV1 = struct {
    ordinal: u64,
    profile_index: u64,
    profile_sha256: Digest,
    arrival_step: u64,
    weight: u16,
    work_quanta: u64,
    deadline_tick: u64 = 0,
    terminal_action_step: u64 = absent,
    terminal_action: TerminalActionV1 = .none,
    fairness_member: bool = true,
    tenant_key: u64,
    request_key: u64,
    request_generation: u64,
    resource_owner_key: u64,
    claim: resource_bank.Claim,
    input_binding_sha256: Digest,
    item_sha256: Digest,
};

pub const PlanV1 = struct {
    seed: u64,
    capacity: u32,
    max_driver_steps: u64,
    max_service_quanta: u64,
    fairness_start_tick: u64,
    fairness_end_tick: u64,
    bank_epoch: u64,
    scheduler_epoch: u64,
    max_weight: u16,
    max_projection_quanta: u64,
    max_projection_operations: u64,
    limits: resource_bank.Limits,
    challenge: Digest,
    profiles: []const ProfileV1,
    items: []const ItemV1,
};

/// Canonical support binding for concrete profiles. Native struct bytes are
/// deliberately never hashed because enum/layout padding is not an ABI.
pub fn supportRecordSha256V1(record: model.SupportRecordV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(support_record_domain);
    hashU64(&hash, support_record_abi);
    hashU64(&hash, @intFromEnum(record.family));
    hashU64(&hash, @intFromEnum(record.operation));
    hashU64(&hash, @intFromEnum(record.input_kind));
    hashU64(&hash, @intFromEnum(record.output_kind));
    hashU64(&hash, @intFromEnum(record.numerical_policy));
    hashU64(&hash, record.max_batch_items);
    hashU64(&hash, record.max_input_features);
    hashU64(&hash, record.max_output_dimensions);
    hashU64(&hash, record.allowed_capabilities);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn profileSha256V1(profile: ProfileV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(profile_domain);
    hashU64(&hash, profile_abi);
    hashU64(&hash, profile.index);
    hashU64(&hash, @intFromEnum(profile.family));
    hashU64(&hash, @intFromEnum(profile.operation));
    hashU64(&hash, @intFromEnum(profile.input_kind));
    hashU64(&hash, @intFromEnum(profile.output_kind));
    hashU64(&hash, @intFromEnum(profile.numerical_policy));
    hashU64(&hash, profile.adapter_abi);
    hashU64(&hash, @intFromEnum(profile.lifecycle));
    hashU64(&hash, @intFromEnum(profile.execution_unit));
    hashU64(&hash, @intFromEnum(profile.cancellation_boundary));
    hashU64(&hash, @intFromEnum(profile.publication_policy));
    hashU64(&hash, @intFromEnum(profile.correctness_gate));
    hashClaim(&hash, profile.claim);
    hash.update(&profile.support_sha256);
    hash.update(&profile.artifact_sha256);
    hash.update(&profile.execution_plan_sha256);
    hash.update(&profile.adapter_implementation_sha256);
    hash.update(&profile.correctness_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn itemSha256V1(item: ItemV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(item_domain);
    hashU64(&hash, item_abi);
    hashU64(&hash, item.ordinal);
    hashU64(&hash, item.profile_index);
    hash.update(&item.profile_sha256);
    hashU64(&hash, item.arrival_step);
    hashU64(&hash, item.weight);
    hashU64(&hash, item.work_quanta);
    hashU64(&hash, item.deadline_tick);
    hashU64(&hash, item.terminal_action_step);
    hashU64(&hash, @intFromEnum(item.terminal_action));
    hashU64(&hash, @intFromBool(item.fairness_member));
    hashU64(&hash, item.tenant_key);
    hashU64(&hash, item.request_key);
    hashU64(&hash, item.request_generation);
    hashU64(&hash, item.resource_owner_key);
    hashClaim(&hash, item.claim);
    hash.update(&item.input_binding_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn profileSectionSha256V1(profiles: []const ProfileV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(profile_section_domain);
    hashU64(&hash, profiles.len);
    for (profiles) |profile| hash.update(&profile.profile_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn itemSectionSha256V1(items: []const ItemV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(item_section_domain);
    hashU64(&hash, items.len);
    for (items) |item| hash.update(&item.item_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn planSha256V1(plan: PlanV1) Digest {
    const profile_root = profileSectionSha256V1(plan.profiles);
    const item_root = itemSectionSha256V1(plan.items);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, plan_abi);
    hashU64(&hash, plan.seed);
    hashU64(&hash, plan.capacity);
    hashU64(&hash, plan.max_driver_steps);
    hashU64(&hash, plan.max_service_quanta);
    hashU64(&hash, plan.fairness_start_tick);
    hashU64(&hash, plan.fairness_end_tick);
    hashU64(&hash, plan.bank_epoch);
    hashU64(&hash, plan.scheduler_epoch);
    hashU64(&hash, plan.max_weight);
    hashU64(&hash, plan.max_projection_quanta);
    hashU64(&hash, plan.max_projection_operations);
    hashLimits(&hash, plan.limits);
    hash.update(&plan.challenge);
    hashU64(&hash, plan.profiles.len);
    hash.update(&profile_root);
    hashU64(&hash, plan.items.len);
    hash.update(&item_root);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn validatePlanV1(plan: PlanV1) Error!void {
    if (plan.seed == 0 or
        plan.capacity == 0 or
        plan.capacity > maximum_items or
        plan.capacity > plan.items.len or
        plan.max_driver_steps == 0 or
        plan.max_driver_steps > maximum_driver_steps or
        plan.max_service_quanta == 0 or
        plan.max_service_quanta > maximum_service_quanta or
        plan.fairness_end_tick <= plan.fairness_start_tick or
        plan.fairness_end_tick > plan.max_service_quanta or
        plan.bank_epoch == 0 or
        plan.scheduler_epoch == 0 or
        plan.max_weight == 0 or
        plan.max_projection_quanta == 0 or
        plan.max_projection_operations == 0 or
        plan.profiles.len == 0 or
        plan.profiles.len > maximum_profiles or
        plan.items.len < 2 or
        plan.items.len > maximum_items or
        plan.profiles.len > plan.items.len or
        digestIsZero(plan.challenge) or
        plan.limits.queue_slots < plan.capacity)
        return Error.InvalidPlan;

    var referenced_profiles = [_]bool{false} ** maximum_profiles;
    for (plan.profiles, 0..) |profile, index| {
        if (profile.index != index or
            !validEnum(model.ModelFamilyIdV1, profile.family) or
            !validEnum(model.OperationIdV1, profile.operation) or
            !validEnum(model.InputKindV1, profile.input_kind) or
            !validEnum(model.OutputKindV1, profile.output_kind) or
            !validEnum(model.NumericalPolicyV1, profile.numerical_policy) or
            profile.adapter_abi == 0 or
            !validEnum(LifecycleV1, profile.lifecycle) or
            !validEnum(ExecutionUnitV1, profile.execution_unit) or
            !validEnum(
                CancellationBoundaryV1,
                profile.cancellation_boundary,
            ) or
            !validEnum(PublicationPolicyV1, profile.publication_policy) or
            !validEnum(CorrectnessGateV1, profile.correctness_gate) or
            profile.claim.isZero() or
            profile.claim.queue_slots != 1 or
            digestIsZero(profile.support_sha256) or
            digestIsZero(profile.artifact_sha256) or
            digestIsZero(profile.execution_plan_sha256) or
            digestIsZero(profile.adapter_implementation_sha256) or
            digestIsZero(profile.correctness_sha256) or
            digestIsZero(profile.profile_sha256))
            return Error.InvalidPlan;
        _ = profile.claim.hostBytes() catch
            return Error.ArithmeticOverflow;
        if (!std.mem.eql(
            u8,
            &profile.profile_sha256,
            &profileSha256V1(profile),
        )) return Error.InvalidPlan;
        for (plan.profiles[0..index]) |prior| {
            if (prior.index == profile.index or
                std.mem.eql(
                    u8,
                    &prior.profile_sha256,
                    &profile.profile_sha256,
                ))
                return Error.InvalidPlan;
        }
    }

    var total_work: u64 = 0;
    var fairness_members: usize = 0;
    var previous_arrival: u64 = 0;
    for (plan.items, 0..) |item, index| {
        if (item.ordinal != index or
            item.profile_index >= plan.profiles.len or
            item.arrival_step >= plan.max_driver_steps or
            (index != 0 and item.arrival_step < previous_arrival) or
            item.weight == 0 or
            item.weight > plan.max_weight or
            item.work_quanta == 0 or
            item.deadline_tick > plan.max_projection_quanta or
            (item.deadline_tick != 0 and
                item.deadline_tick <= item.arrival_step) or
            !validEnum(TerminalActionV1, item.terminal_action) or
            ((item.terminal_action == .none) !=
                (item.terminal_action_step == absent)) or
            (item.terminal_action != .none and
                (item.terminal_action_step < item.arrival_step or
                    item.terminal_action_step >= plan.max_driver_steps)) or
            item.tenant_key == 0 or
            item.request_key == 0 or
            item.request_generation == 0 or
            item.resource_owner_key == 0 or
            item.claim.isZero() or
            item.claim.queue_slots != 1 or
            digestIsZero(item.input_binding_sha256) or
            digestIsZero(item.item_sha256))
            return Error.InvalidPlan;

        const profile_index = std.math.cast(
            usize,
            item.profile_index,
        ) orelse return Error.InvalidPlan;
        const profile = plan.profiles[profile_index];
        if (profile.index != item.profile_index or
            !std.mem.eql(
                u8,
                &profile.profile_sha256,
                &item.profile_sha256,
            ) or
            !std.meta.eql(profile.claim, item.claim) or
            !std.mem.eql(
                u8,
                &item.item_sha256,
                &itemSha256V1(item),
            ))
            return Error.InvalidPlan;
        referenced_profiles[profile_index] = true;
        previous_arrival = item.arrival_step;
        total_work = std.math.add(
            u64,
            total_work,
            item.work_quanta,
        ) catch return Error.ArithmeticOverflow;
        if (item.fairness_member) fairness_members += 1;
        for (plan.items[0..index]) |prior| {
            if (prior.tenant_key == item.tenant_key or
                prior.request_key == item.request_key or
                prior.resource_owner_key == item.resource_owner_key)
                return Error.InvalidPlan;
        }
    }
    if (total_work > plan.max_service_quanta or fairness_members < 2)
        return Error.InvalidPlan;
    for (referenced_profiles[0..plan.profiles.len]) |referenced| {
        if (!referenced) return Error.InvalidPlan;
    }
}

pub fn requiredPlanBytesV1(
    profile_count: usize,
    item_count: usize,
) Error!usize {
    if (profile_count == 0 or profile_count > maximum_profiles)
        return Error.ProfileLimitExceeded;
    if (item_count == 0 or item_count > maximum_items)
        return Error.ItemLimitExceeded;
    const profile_bytes = std.math.mul(
        usize,
        profile_count,
        profile_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    const item_bytes = std.math.mul(
        usize,
        item_count,
        item_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    var total = std.math.add(
        usize,
        plan_header_bytes,
        profile_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = std.math.add(usize, total, item_bytes) catch
        return Error.ArithmeticOverflow;
    return std.math.add(usize, total, plan_footer_bytes) catch
        return Error.ArithmeticOverflow;
}

pub fn encodePlanV1(
    plan: PlanV1,
    destination: []u8,
) Error![]const u8 {
    try validatePlanV1(plan);
    const needed = try requiredPlanBytesV1(
        plan.profiles.len,
        plan.items.len,
    );
    if (destination.len < needed) return Error.BufferTooSmall;
    const output = destination[0..needed];
    if (slicesOverlap(
        std.mem.sliceAsBytes(plan.profiles),
        output,
    ) or slicesOverlap(
        std.mem.sliceAsBytes(plan.items),
        output,
    )) return Error.AliasedBuffer;

    @memset(output, 0);
    @memcpy(output[0..8], &plan_magic);
    writeU64(output, 8, plan_abi);
    writeU64(output, 16, needed);
    writeU64(output, 24, plan_header_bytes);
    writeU64(output, 32, profile_record_bytes);
    writeU64(output, 40, item_record_bytes);
    writeU64(output, 48, plan_footer_bytes);
    writeU64(output, 56, allowed_flags);
    writeU64(output, 64, plan.profiles.len);
    writeU64(output, 72, plan.items.len);
    writeU64(output, 80, plan.seed);
    writeU64(output, 88, plan.capacity);
    writeU64(output, 96, plan.max_driver_steps);
    writeU64(output, 104, plan.max_service_quanta);
    writeU64(output, 112, plan.fairness_start_tick);
    writeU64(output, 120, plan.fairness_end_tick);
    writeU64(output, 128, plan.bank_epoch);
    writeU64(output, 136, plan.scheduler_epoch);
    writeU64(output, 144, plan.max_weight);
    writeU64(output, 152, plan.max_projection_quanta);
    writeU64(output, 160, plan.max_projection_operations);
    writeLimits(output, 168, plan.limits);
    @memcpy(output[256..288], &plan.challenge);
    const profile_section_root = profileSectionSha256V1(plan.profiles);
    const item_section_root = itemSectionSha256V1(plan.items);
    const plan_root = planSha256V1(plan);
    @memcpy(output[288..320], &profile_section_root);
    @memcpy(output[320..352], &item_section_root);
    @memcpy(output[352..384], &plan_root);

    var offset: usize = plan_header_bytes;
    for (plan.profiles) |profile| {
        writeProfileRecordV1(
            output[offset..][0..profile_record_bytes],
            profile,
        );
        offset += profile_record_bytes;
    }
    for (plan.items) |item| {
        writeItemRecordV1(
            output[offset..][0..item_record_bytes],
            item,
        );
        offset += item_record_bytes;
    }
    const footer = wireSha256(output[0..offset]);
    @memcpy(output[offset .. offset + plan_footer_bytes], &footer);
    return output;
}

pub fn decodePlanV1(
    encoded: []const u8,
    profile_storage: []ProfileV1,
    item_storage: []ItemV1,
) Error!PlanV1 {
    if (encoded.len < plan_header_bytes + plan_footer_bytes or
        !std.mem.eql(u8, encoded[0..8], &plan_magic) or
        readU64(encoded, 8) != plan_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 24) != plan_header_bytes or
        readU64(encoded, 32) != profile_record_bytes or
        readU64(encoded, 40) != item_record_bytes or
        readU64(encoded, 48) != plan_footer_bytes or
        readU64(encoded, 56) != allowed_flags)
        return Error.InvalidEvidence;
    const profile_count = std.math.cast(
        usize,
        readU64(encoded, 64),
    ) orelse return Error.InvalidEvidence;
    const item_count = std.math.cast(
        usize,
        readU64(encoded, 72),
    ) orelse return Error.InvalidEvidence;
    const expected = requiredPlanBytesV1(
        profile_count,
        item_count,
    ) catch return Error.InvalidEvidence;
    if (encoded.len != expected) return Error.InvalidEvidence;
    if (profile_storage.len < profile_count or
        item_storage.len < item_count)
        return Error.BufferTooSmall;
    const target_profiles = profile_storage[0..profile_count];
    const target_items = item_storage[0..item_count];
    if (slicesOverlap(
        encoded,
        std.mem.sliceAsBytes(target_profiles),
    ) or slicesOverlap(
        encoded,
        std.mem.sliceAsBytes(target_items),
    ) or slicesOverlap(
        std.mem.sliceAsBytes(target_profiles),
        std.mem.sliceAsBytes(target_items),
    )) return Error.AliasedBuffer;

    var retained_footer: Digest = undefined;
    @memcpy(&retained_footer, encoded[encoded.len - plan_footer_bytes ..]);
    const expected_footer = wireSha256(
        encoded[0 .. encoded.len - plan_footer_bytes],
    );
    if (!std.mem.eql(u8, &retained_footer, &expected_footer))
        return Error.InvalidEvidence;

    var temporary_profiles: [maximum_profiles]ProfileV1 = undefined;
    var temporary_items: [maximum_items]ItemV1 = undefined;
    var offset: usize = plan_header_bytes;
    for (0..profile_count) |index| {
        temporary_profiles[index] = decodeProfileRecordV1(
            encoded[offset..][0..profile_record_bytes],
        ) catch return Error.InvalidEvidence;
        offset += profile_record_bytes;
    }
    for (0..item_count) |index| {
        temporary_items[index] = decodeItemRecordV1(
            encoded[offset..][0..item_record_bytes],
        ) catch return Error.InvalidEvidence;
        offset += item_record_bytes;
    }

    const capacity = std.math.cast(
        u32,
        readU64(encoded, 88),
    ) orelse return Error.InvalidEvidence;
    const max_weight = std.math.cast(
        u16,
        readU64(encoded, 144),
    ) orelse return Error.InvalidEvidence;
    var challenge: Digest = undefined;
    var retained_profile_root: Digest = undefined;
    var retained_item_root: Digest = undefined;
    var retained_plan_root: Digest = undefined;
    @memcpy(&challenge, encoded[256..288]);
    @memcpy(&retained_profile_root, encoded[288..320]);
    @memcpy(&retained_item_root, encoded[320..352]);
    @memcpy(&retained_plan_root, encoded[352..384]);
    const temporary_plan: PlanV1 = .{
        .seed = readU64(encoded, 80),
        .capacity = capacity,
        .max_driver_steps = readU64(encoded, 96),
        .max_service_quanta = readU64(encoded, 104),
        .fairness_start_tick = readU64(encoded, 112),
        .fairness_end_tick = readU64(encoded, 120),
        .bank_epoch = readU64(encoded, 128),
        .scheduler_epoch = readU64(encoded, 136),
        .max_weight = max_weight,
        .max_projection_quanta = readU64(encoded, 152),
        .max_projection_operations = readU64(encoded, 160),
        .limits = readLimits(encoded, 168),
        .challenge = challenge,
        .profiles = temporary_profiles[0..profile_count],
        .items = temporary_items[0..item_count],
    };
    validatePlanV1(temporary_plan) catch return Error.InvalidEvidence;
    if (!std.mem.eql(
        u8,
        &retained_profile_root,
        &profileSectionSha256V1(temporary_plan.profiles),
    ) or !std.mem.eql(
        u8,
        &retained_item_root,
        &itemSectionSha256V1(temporary_plan.items),
    ) or !std.mem.eql(
        u8,
        &retained_plan_root,
        &planSha256V1(temporary_plan),
    )) return Error.InvalidEvidence;

    @memcpy(target_profiles, temporary_profiles[0..profile_count]);
    @memcpy(target_items, temporary_items[0..item_count]);
    return .{
        .seed = temporary_plan.seed,
        .capacity = temporary_plan.capacity,
        .max_driver_steps = temporary_plan.max_driver_steps,
        .max_service_quanta = temporary_plan.max_service_quanta,
        .fairness_start_tick = temporary_plan.fairness_start_tick,
        .fairness_end_tick = temporary_plan.fairness_end_tick,
        .bank_epoch = temporary_plan.bank_epoch,
        .scheduler_epoch = temporary_plan.scheduler_epoch,
        .max_weight = temporary_plan.max_weight,
        .max_projection_quanta = temporary_plan.max_projection_quanta,
        .max_projection_operations = temporary_plan.max_projection_operations,
        .limits = temporary_plan.limits,
        .challenge = temporary_plan.challenge,
        .profiles = target_profiles,
        .items = target_items,
    };
}

fn writeProfileRecordV1(output: []u8, profile: ProfileV1) void {
    @memset(output, 0);
    writeU64(output, 0, profile.index);
    writeU64(output, 8, @intFromEnum(profile.family));
    writeU64(output, 16, @intFromEnum(profile.operation));
    writeU64(output, 24, @intFromEnum(profile.input_kind));
    writeU64(output, 32, @intFromEnum(profile.output_kind));
    writeU64(output, 40, @intFromEnum(profile.numerical_policy));
    writeU64(output, 48, profile.adapter_abi);
    writeU64(output, 56, @intFromEnum(profile.lifecycle));
    writeU64(output, 64, @intFromEnum(profile.execution_unit));
    writeU64(output, 72, @intFromEnum(profile.cancellation_boundary));
    writeU64(output, 80, @intFromEnum(profile.publication_policy));
    writeU64(output, 88, @intFromEnum(profile.correctness_gate));
    writeClaim(output, 96, profile.claim);
    @memcpy(output[176..208], &profile.support_sha256);
    @memcpy(output[208..240], &profile.artifact_sha256);
    @memcpy(output[240..272], &profile.execution_plan_sha256);
    @memcpy(
        output[272..304],
        &profile.adapter_implementation_sha256,
    );
    @memcpy(output[304..336], &profile.correctness_sha256);
    @memcpy(output[336..368], &profile.profile_sha256);
}

fn decodeProfileRecordV1(input: []const u8) Error!ProfileV1 {
    var support_sha256: Digest = undefined;
    var artifact_sha256: Digest = undefined;
    var execution_plan_sha256: Digest = undefined;
    var adapter_implementation_sha256: Digest = undefined;
    var correctness_sha256: Digest = undefined;
    var profile_sha256: Digest = undefined;
    @memcpy(&support_sha256, input[176..208]);
    @memcpy(&artifact_sha256, input[208..240]);
    @memcpy(&execution_plan_sha256, input[240..272]);
    @memcpy(&adapter_implementation_sha256, input[272..304]);
    @memcpy(&correctness_sha256, input[304..336]);
    @memcpy(&profile_sha256, input[336..368]);
    return .{
        .index = readU64(input, 0),
        .family = try readEnum(model.ModelFamilyIdV1, input, 8),
        .operation = try readEnum(model.OperationIdV1, input, 16),
        .input_kind = try readEnum(model.InputKindV1, input, 24),
        .output_kind = try readEnum(model.OutputKindV1, input, 32),
        .numerical_policy = try readEnum(
            model.NumericalPolicyV1,
            input,
            40,
        ),
        .adapter_abi = readU64(input, 48),
        .lifecycle = try readEnum(LifecycleV1, input, 56),
        .execution_unit = try readEnum(ExecutionUnitV1, input, 64),
        .cancellation_boundary = try readEnum(
            CancellationBoundaryV1,
            input,
            72,
        ),
        .publication_policy = try readEnum(
            PublicationPolicyV1,
            input,
            80,
        ),
        .correctness_gate = try readEnum(
            CorrectnessGateV1,
            input,
            88,
        ),
        .claim = readClaim(input, 96),
        .support_sha256 = support_sha256,
        .artifact_sha256 = artifact_sha256,
        .execution_plan_sha256 = execution_plan_sha256,
        .adapter_implementation_sha256 = adapter_implementation_sha256,
        .correctness_sha256 = correctness_sha256,
        .profile_sha256 = profile_sha256,
    };
}

fn writeItemRecordV1(output: []u8, item: ItemV1) void {
    @memset(output, 0);
    writeU64(output, 0, item.ordinal);
    writeU64(output, 8, item.profile_index);
    @memcpy(output[16..48], &item.profile_sha256);
    writeU64(output, 48, item.arrival_step);
    writeU64(output, 56, item.weight);
    writeU64(output, 64, item.work_quanta);
    writeU64(output, 72, item.deadline_tick);
    writeU64(output, 80, item.terminal_action_step);
    writeU64(output, 88, @intFromEnum(item.terminal_action));
    writeU64(output, 96, @intFromBool(item.fairness_member));
    writeU64(output, 104, item.tenant_key);
    writeU64(output, 112, item.request_key);
    writeU64(output, 120, item.request_generation);
    writeU64(output, 128, item.resource_owner_key);
    writeClaim(output, 136, item.claim);
    @memcpy(output[216..248], &item.input_binding_sha256);
    @memcpy(output[248..280], &item.item_sha256);
}

fn decodeItemRecordV1(input: []const u8) Error!ItemV1 {
    const weight = std.math.cast(
        u16,
        readU64(input, 56),
    ) orelse return Error.InvalidEvidence;
    const fairness = switch (readU64(input, 96)) {
        0 => false,
        1 => true,
        else => return Error.InvalidEvidence,
    };
    var profile_sha256: Digest = undefined;
    var input_binding_sha256: Digest = undefined;
    var item_sha256: Digest = undefined;
    @memcpy(&profile_sha256, input[16..48]);
    @memcpy(&input_binding_sha256, input[216..248]);
    @memcpy(&item_sha256, input[248..280]);
    return .{
        .ordinal = readU64(input, 0),
        .profile_index = readU64(input, 8),
        .profile_sha256 = profile_sha256,
        .arrival_step = readU64(input, 48),
        .weight = weight,
        .work_quanta = readU64(input, 64),
        .deadline_tick = readU64(input, 72),
        .terminal_action_step = readU64(input, 80),
        .terminal_action = try readEnum(
            TerminalActionV1,
            input,
            88,
        ),
        .fairness_member = fairness,
        .tenant_key = readU64(input, 104),
        .request_key = readU64(input, 112),
        .request_generation = readU64(input, 120),
        .resource_owner_key = readU64(input, 128),
        .claim = readClaim(input, 136),
        .input_binding_sha256 = input_binding_sha256,
        .item_sha256 = item_sha256,
    };
}

fn writeClaim(
    output: []u8,
    offset: usize,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim), 0..) |field, index|
        writeU64(output, offset + index * 8, @field(claim, field.name));
}

fn readClaim(input: []const u8, offset: usize) resource_bank.Claim {
    var claim: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim), 0..) |field, index|
        @field(claim, field.name) = readU64(input, offset + index * 8);
    return claim;
}

fn writeLimits(
    output: []u8,
    offset: usize,
    limits: resource_bank.Limits,
) void {
    inline for (std.meta.fields(resource_bank.Limits), 0..) |field, index|
        writeU64(output, offset + index * 8, @field(limits, field.name));
}

fn readLimits(
    input: []const u8,
    offset: usize,
) resource_bank.Limits {
    var limits: resource_bank.Limits = .{};
    inline for (std.meta.fields(resource_bank.Limits), 0..) |field, index|
        @field(limits, field.name) =
            readU64(input, offset + index * 8);
    return limits;
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(
        u64,
        output[offset..][0..8],
        @intCast(value),
        .little,
    );
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset..][0..8], .little);
}

fn readEnum(
    comptime Enum: type,
    input: []const u8,
    offset: usize,
) Error!Enum {
    return std.meta.intToEnum(Enum, readU64(input, offset)) catch
        return Error.InvalidEvidence;
}

fn validEnum(comptime Enum: type, value: Enum) bool {
    _ = std.meta.intToEnum(
        Enum,
        @intFromEnum(value),
    ) catch return false;
    return true;
}

fn hashClaim(hash: anytype, claim: resource_bank.Claim) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn hashLimits(hash: anytype, limits: resource_bank.Limits) void {
    inline for (std.meta.fields(resource_bank.Limits)) |field|
        hashU64(hash, @field(limits, field.name));
}

fn hashU64(hash: anytype, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

fn wireSha256(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_wire_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn digestIsZero(digest: Digest) bool {
    return std.mem.eql(u8, &digest, &zero_digest);
}

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(
        usize,
        left_start,
        left.len,
    ) catch return true;
    const right_end = std.math.add(
        usize,
        right_start,
        right.len,
    ) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn digestFill(value: u8) Digest {
    return [_]u8{value} ** 32;
}

fn digestFromHex(hex: *const [64]u8) !Digest {
    var digest: Digest = undefined;
    _ = try std.fmt.hexToBytes(&digest, hex);
    return digest;
}

fn fixtureSupportV1(index: usize) model.SupportRecordV1 {
    return switch (index) {
        0 => .{
            .family = .autoregressive,
            .operation = .decode_next,
            .input_kind = .token_ids,
            .output_kind = .token_scores,
            .numerical_policy = .strict_float32,
            .max_batch_items = 4,
            .max_input_features = 4096,
            .max_output_dimensions = 32000,
            .allowed_capabilities = 0x11,
        },
        else => .{
            .family = .stateless_encoder,
            .operation = .encode,
            .input_kind = .dense_tensor,
            .output_kind = .embedding_i32,
            .numerical_policy = .exact_integer,
            .max_batch_items = 8,
            .max_input_features = 1024,
            .max_output_dimensions = 768,
            .allowed_capabilities = 0x22,
        },
    };
}

fn fixtureProfileV1(index: usize) ProfileV1 {
    const support = fixtureSupportV1(index);
    var profile: ProfileV1 = .{
        .index = index,
        .family = support.family,
        .operation = support.operation,
        .input_kind = support.input_kind,
        .output_kind = support.output_kind,
        .numerical_policy = support.numerical_policy,
        .adapter_abi = 0x4757_4144_0000_0001 + index,
        .lifecycle = if (index == 0) .stateful else .stateless,
        .execution_unit = if (index == 0) .token else .operation,
        .cancellation_boundary = if (index == 0)
            .between_units
        else
            .before_start,
        .publication_policy = if (index == 0)
            .incremental
        else
            .final_only,
        .correctness_gate = if (index == 0)
            .bounded_numeric
        else
            .exact,
        .claim = if (index == 0) .{
            .capsule_bytes = 64,
            .kv_bytes = 512,
            .logits_bytes = 128,
            .device_bytes = 1024,
            .io_bytes = 32,
            .queue_slots = 1,
        } else .{
            .capsule_bytes = 48,
            .activation_bytes = 256,
            .partial_bytes = 64,
            .device_bytes = 512,
            .io_bytes = 16,
            .queue_slots = 1,
        },
        .support_sha256 = supportRecordSha256V1(support),
        .artifact_sha256 = digestFill(@intCast(0x20 + index)),
        .execution_plan_sha256 = digestFill(@intCast(0x30 + index)),
        .adapter_implementation_sha256 = digestFill(@intCast(0x40 + index)),
        .correctness_sha256 = digestFill(@intCast(0x50 + index)),
        .profile_sha256 = zero_digest,
    };
    profile.profile_sha256 = profileSha256V1(profile);
    return profile;
}

fn fixtureItemV1(
    ordinal: usize,
    profile: ProfileV1,
    arrival_step: u64,
    action_step: u64,
    action: TerminalActionV1,
) ItemV1 {
    const identity: u64 = @intCast(ordinal + 1);
    var item: ItemV1 = .{
        .ordinal = ordinal,
        .profile_index = profile.index,
        .profile_sha256 = profile.profile_sha256,
        .arrival_step = arrival_step,
        .weight = if (profile.index == 0) 2 else 1,
        .work_quanta = 3 + identity,
        .deadline_tick = 32,
        .terminal_action_step = action_step,
        .terminal_action = action,
        .fairness_member = ordinal < 2,
        .tenant_key = 0x1000 + identity,
        .request_key = 0x2000 + identity,
        .request_generation = 1,
        .resource_owner_key = 0x3000 + identity,
        .claim = profile.claim,
        .input_binding_sha256 = digestFill(@intCast(0x60 + ordinal)),
        .item_sha256 = zero_digest,
    };
    item.item_sha256 = itemSha256V1(item);
    return item;
}

fn fixtureProfilesV1() [2]ProfileV1 {
    return .{
        fixtureProfileV1(0),
        fixtureProfileV1(1),
    };
}

fn fixtureItemsV1(profiles: *const [2]ProfileV1) [4]ItemV1 {
    return .{
        fixtureItemV1(0, profiles[0], 0, absent, .none),
        fixtureItemV1(1, profiles[1], 0, absent, .none),
        fixtureItemV1(2, profiles[0], 2, 7, .cancel),
        fixtureItemV1(3, profiles[1], 3, 9, .timeout),
    };
}

fn fixturePlanV1(
    profiles: []const ProfileV1,
    items: []const ItemV1,
) PlanV1 {
    return .{
        .seed = 0x4757_5457_2026_0001,
        .capacity = 4,
        .max_driver_steps = 64,
        .max_service_quanta = 64,
        .fairness_start_tick = 0,
        .fairness_end_tick = 8,
        .bank_epoch = 0x4757_424b_0000_0001,
        .scheduler_epoch = 0x4757_5343_0000_0001,
        .max_weight = 4,
        .max_projection_quanta = 256,
        .max_projection_operations = 4096,
        .limits = .{
            .host_bytes = 8192,
            .capsule_bytes = 1024,
            .kv_bytes = 4096,
            .activation_bytes = 4096,
            .partial_bytes = 1024,
            .logits_bytes = 1024,
            .output_journal_bytes = 1024,
            .staging_bytes = 1024,
            .device_bytes = 8192,
            .io_bytes = 1024,
            .queue_slots = 4,
        },
        .challenge = digestFill(0x71),
        .profiles = profiles,
        .items = items,
    };
}

fn expectPlanEqual(expected: PlanV1, actual: PlanV1) !void {
    try std.testing.expectEqual(expected.seed, actual.seed);
    try std.testing.expectEqual(expected.capacity, actual.capacity);
    try std.testing.expectEqual(
        expected.max_driver_steps,
        actual.max_driver_steps,
    );
    try std.testing.expectEqual(
        expected.max_service_quanta,
        actual.max_service_quanta,
    );
    try std.testing.expectEqual(
        expected.fairness_start_tick,
        actual.fairness_start_tick,
    );
    try std.testing.expectEqual(
        expected.fairness_end_tick,
        actual.fairness_end_tick,
    );
    try std.testing.expectEqual(expected.bank_epoch, actual.bank_epoch);
    try std.testing.expectEqual(
        expected.scheduler_epoch,
        actual.scheduler_epoch,
    );
    try std.testing.expectEqual(expected.max_weight, actual.max_weight);
    try std.testing.expectEqual(
        expected.max_projection_quanta,
        actual.max_projection_quanta,
    );
    try std.testing.expectEqual(
        expected.max_projection_operations,
        actual.max_projection_operations,
    );
    try std.testing.expectEqualDeep(expected.limits, actual.limits);
    try std.testing.expectEqualSlices(
        u8,
        &expected.challenge,
        &actual.challenge,
    );
    try std.testing.expectEqualDeep(expected.profiles, actual.profiles);
    try std.testing.expectEqualDeep(expected.items, actual.items);
}

fn expectDecodeRejectedWithoutMutation(
    encoded: []const u8,
    expected_error: Error,
) !void {
    const profile_sentinel = fixtureProfileV1(0);
    const item_sentinel = fixtureItemV1(
        0,
        profile_sentinel,
        0,
        absent,
        .none,
    );
    var profiles = [_]ProfileV1{profile_sentinel} ** maximum_profiles;
    var items = [_]ItemV1{item_sentinel} ** maximum_items;
    const before_profiles = profiles;
    const before_items = items;
    try std.testing.expectError(
        expected_error,
        decodePlanV1(encoded, &profiles, &items),
    );
    try std.testing.expectEqualDeep(before_profiles, profiles);
    try std.testing.expectEqualDeep(before_items, items);
}

fn resealWireForTest(
    encoded: []u8,
    plan: PlanV1,
) void {
    const profile_root = profileSectionSha256V1(plan.profiles);
    const item_root = itemSectionSha256V1(plan.items);
    const plan_root = planSha256V1(plan);
    @memcpy(encoded[288..320], &profile_root);
    @memcpy(encoded[320..352], &item_root);
    @memcpy(encoded[352..384], &plan_root);
    var offset: usize = plan_header_bytes;
    for (plan.profiles) |profile| {
        writeProfileRecordV1(
            encoded[offset..][0..profile_record_bytes],
            profile,
        );
        offset += profile_record_bytes;
    }
    for (plan.items) |item| {
        writeItemRecordV1(
            encoded[offset..][0..item_record_bytes],
            item,
        );
        offset += item_record_bytes;
    }
    const footer = wireSha256(encoded[0..offset]);
    @memcpy(encoded[offset .. offset + plan_footer_bytes], &footer);
}

test "W4a canonical plan round trips without native layout" {
    var profiles = fixtureProfilesV1();
    var items = fixtureItemsV1(&profiles);
    const plan = fixturePlanV1(&profiles, &items);
    try validatePlanV1(plan);
    try std.testing.expectEqual(
        @as(usize, 2272),
        try requiredPlanBytesV1(profiles.len, items.len),
    );
    try std.testing.expectEqual(
        @as(usize, 10784),
        maximum_plan_bytes,
    );

    var encoded_storage: [maximum_plan_bytes]u8 = undefined;
    const encoded = try encodePlanV1(plan, &encoded_storage);
    var fixture_wire_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        encoded,
        &fixture_wire_sha256,
        .{},
    );
    const expected_wire_sha256 = try digestFromHex(
        "d8f11aff66f65bd423b00564bb67710a3ab8ce5ac79456d6b2b112cd86b148a7",
    );
    const expected_plan_sha256 = try digestFromHex(
        "5f2ecceeac1949f91b12ae5670b3cb3ee691a7afc9bf99f86bf829f8c5182fcb",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_wire_sha256,
        &fixture_wire_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_plan_sha256,
        &planSha256V1(plan),
    );
    try std.testing.expectEqual(@as(usize, 2272), encoded.len);
    try std.testing.expectEqualSlices(u8, &plan_magic, encoded[0..8]);
    try std.testing.expectEqual(plan_abi, readU64(encoded, 8));
    try std.testing.expectEqual(
        @as(u64, plan_header_bytes),
        readU64(encoded, 24),
    );
    try std.testing.expectEqual(
        @as(u64, profile_record_bytes),
        readU64(encoded, 32),
    );
    try std.testing.expectEqual(
        @as(u64, item_record_bytes),
        readU64(encoded, 40),
    );
    try std.testing.expectEqual(
        @as(u64, profiles.len),
        readU64(encoded, 64),
    );
    try std.testing.expectEqual(
        @as(u64, items.len),
        readU64(encoded, 72),
    );

    var decoded_profiles: [maximum_profiles]ProfileV1 = undefined;
    var decoded_items: [maximum_items]ItemV1 = undefined;
    const decoded = try decodePlanV1(
        encoded,
        &decoded_profiles,
        &decoded_items,
    );
    try expectPlanEqual(plan, decoded);
    try std.testing.expectEqualSlices(
        u8,
        &planSha256V1(plan),
        &planSha256V1(decoded),
    );

    var second_storage: [maximum_plan_bytes]u8 = undefined;
    const second = try encodePlanV1(decoded, &second_storage);
    try std.testing.expectEqualSlices(u8, encoded, second);
}

test "W4a support record hash binds every canonical field and profile root" {
    const baseline = fixtureSupportV1(0);
    const root = supportRecordSha256V1(baseline);
    var changed = baseline;

    inline for (std.meta.fields(model.SupportRecordV1)) |field| {
        changed = baseline;
        const Field = field.type;
        if (@typeInfo(Field) == .@"enum") {
            const value = @intFromEnum(@field(changed, field.name));
            const replacement: u64 = if (value == 1) 2 else 1;
            @field(changed, field.name) = std.meta.intToEnum(
                Field,
                replacement,
            ) catch unreachable;
        } else {
            @field(changed, field.name) +%= 1;
        }
        try std.testing.expect(!std.mem.eql(
            u8,
            &root,
            &supportRecordSha256V1(changed),
        ));
    }

    var profile = fixtureProfileV1(0);
    const original_profile_root = profile.profile_sha256;
    changed = baseline;
    changed.max_batch_items += 1;
    profile.support_sha256 = supportRecordSha256V1(changed);
    profile.profile_sha256 = profileSha256V1(profile);
    try std.testing.expect(!std.mem.eql(
        u8,
        &original_profile_root,
        &profile.profile_sha256,
    ));
}

test "W4a rejects every wire byte mutation and every truncation atomically" {
    var profiles = fixtureProfilesV1();
    var items = fixtureItemsV1(&profiles);
    const plan = fixturePlanV1(&profiles, &items);
    var encoded_storage: [maximum_plan_bytes]u8 = undefined;
    const encoded = try encodePlanV1(plan, &encoded_storage);

    var mutated_storage: [maximum_plan_bytes]u8 = undefined;
    for (0..encoded.len) |index| {
        @memcpy(mutated_storage[0..encoded.len], encoded);
        mutated_storage[index] ^= 0x01;
        try expectDecodeRejectedWithoutMutation(
            mutated_storage[0..encoded.len],
            Error.InvalidEvidence,
        );
    }
    for (0..encoded.len) |length| {
        try expectDecodeRejectedWithoutMutation(
            encoded[0..length],
            Error.InvalidEvidence,
        );
    }
}

test "W4a rejects fully resealed exact-binding substitutions" {
    var profiles = fixtureProfilesV1();
    var items = fixtureItemsV1(&profiles);
    const plan = fixturePlanV1(&profiles, &items);
    var encoded_storage: [maximum_plan_bytes]u8 = undefined;
    const encoded = try encodePlanV1(plan, &encoded_storage);

    var forged_claim_wire: [maximum_plan_bytes]u8 = undefined;
    @memcpy(forged_claim_wire[0..encoded.len], encoded);
    items[0].claim = profiles[1].claim;
    items[0].item_sha256 = itemSha256V1(items[0]);
    const forged_claim_plan = fixturePlanV1(&profiles, &items);
    resealWireForTest(
        forged_claim_wire[0..encoded.len],
        forged_claim_plan,
    );
    try expectDecodeRejectedWithoutMutation(
        forged_claim_wire[0..encoded.len],
        Error.InvalidEvidence,
    );

    items = fixtureItemsV1(&profiles);
    var forged_profile_wire: [maximum_plan_bytes]u8 = undefined;
    @memcpy(forged_profile_wire[0..encoded.len], encoded);
    items[0].profile_sha256 = profiles[1].profile_sha256;
    items[0].claim = profiles[1].claim;
    items[0].item_sha256 = itemSha256V1(items[0]);
    const forged_profile_plan = fixturePlanV1(&profiles, &items);
    resealWireForTest(
        forged_profile_wire[0..encoded.len],
        forged_profile_plan,
    );
    try expectDecodeRejectedWithoutMutation(
        forged_profile_wire[0..encoded.len],
        Error.InvalidEvidence,
    );

    items = fixtureItemsV1(&profiles);
    var duplicate_profile_wire: [maximum_plan_bytes]u8 = undefined;
    @memcpy(duplicate_profile_wire[0..encoded.len], encoded);
    profiles[1] = profiles[0];
    const duplicate_profile_plan = fixturePlanV1(&profiles, &items);
    resealWireForTest(
        duplicate_profile_wire[0..encoded.len],
        duplicate_profile_plan,
    );
    try expectDecodeRejectedWithoutMutation(
        duplicate_profile_wire[0..encoded.len],
        Error.InvalidEvidence,
    );
}

test "W4a encode and decode failures preserve caller buffers" {
    var profiles = fixtureProfilesV1();
    var items = fixtureItemsV1(&profiles);
    var plan = fixturePlanV1(&profiles, &items);

    var destination = [_]u8{0xa5} ** maximum_plan_bytes;
    const before_destination = destination;
    items[0].claim = profiles[1].claim;
    try std.testing.expectError(
        Error.InvalidPlan,
        encodePlanV1(plan, &destination),
    );
    try std.testing.expectEqualSlices(
        u8,
        &before_destination,
        &destination,
    );

    items = fixtureItemsV1(&profiles);
    plan = fixturePlanV1(&profiles, &items);
    const needed = try requiredPlanBytesV1(profiles.len, items.len);
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodePlanV1(plan, destination[0 .. needed - 1]),
    );
    try std.testing.expectEqualSlices(
        u8,
        &before_destination,
        &destination,
    );

    const encoded = try encodePlanV1(plan, &destination);
    var profile_storage: [1]ProfileV1 = .{fixtureProfileV1(0)};
    const before_profiles = profile_storage;
    var item_storage: [maximum_items]ItemV1 = undefined;
    try std.testing.expectError(
        Error.BufferTooSmall,
        decodePlanV1(encoded, &profile_storage, &item_storage),
    );
    try std.testing.expectEqualDeep(before_profiles, profile_storage);
}

test "W4a nonzero absolute deadline must follow arrival" {
    var profiles = fixtureProfilesV1();
    var items = fixtureItemsV1(&profiles);
    var plan = fixturePlanV1(&profiles, &items);

    items[2].deadline_tick = items[2].arrival_step;
    items[2].item_sha256 = itemSha256V1(items[2]);
    try std.testing.expectError(Error.InvalidPlan, validatePlanV1(plan));

    items[2].deadline_tick = items[2].arrival_step - 1;
    items[2].item_sha256 = itemSha256V1(items[2]);
    try std.testing.expectError(Error.InvalidPlan, validatePlanV1(plan));

    items[2].deadline_tick = items[2].arrival_step + 1;
    items[2].item_sha256 = itemSha256V1(items[2]);
    plan = fixturePlanV1(&profiles, &items);
    try validatePlanV1(plan);
}
