//! Canonical generation-one source replay contract for prepared text.
//!
//! The contract is pointer-free evidence. It records the complete pre-tokenized
//! request input needed to reproduce a fresh source attempt, but grants no
//! Scheduler, ResourceBank, checkpoint, result-sink, or target authority.
//! Contextual verification requires caller-recomputed `PlanV1` and
//! `BoundPlanV1` values and independently reconstructs the exact empty result
//! ledger and selector.

const std = @import("std");
const core = @import("core");
const model_contract = core.model_contract;
const resource_bank = core.resource_bank;
const session = @import("prepared_text_session.zig");
const successor = @import("prepared_text_successor.zig");
const result_sink_file =
    @import("prepared_text_result_sink_file.zig");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const contract_abi: u64 = 0x4750_5452_0000_0001;
pub const contract_magic =
    [_]u8{ 'G', 'P', 'T', 'R', 'E', 'P', 'L', '1' };
pub const allowed_flags: u64 = 0;
pub const header_bytes: usize = 128;
pub const fixed_payload_bytes: usize = 832;
pub const footer_bytes: usize = @sizeOf(Digest);
pub const prompt_offset: usize =
    header_bytes + fixed_payload_bytes;
pub const minimum_encoded_bytes: usize =
    prompt_offset + footer_bytes;

const options_offset: usize = header_bytes;
const scheduling_offset: usize = options_offset + 24;
const bound_plan_input_offset: usize = scheduling_offset + 48;
const source_runtime_offset: usize =
    bound_plan_input_offset + 136;
const request_offset: usize = source_runtime_offset + 24;
const plan_bindings_offset: usize = request_offset + 48;
const target_offset: usize = plan_bindings_offset + 192;
const target_root_offset: usize = target_offset + 176;
const sink_offset: usize = target_root_offset + 32;

comptime {
    if (options_offset != 128 or
        scheduling_offset != 152 or
        bound_plan_input_offset != 200 or
        source_runtime_offset != 336 or
        request_offset != 360 or
        plan_bindings_offset != 408 or
        target_offset != 600 or
        target_root_offset != 776 or
        sink_offset != 808 or
        sink_offset + 152 != prompt_offset)
        @compileError("prepared-text source replay layout drift");
}

const contract_domain =
    "glacier-prepared-text-source-replay-contract-v1\x00";
const prompt_domain = "glacier-prepared-text-prompt-v1\x00";
const plan_domain = "glacier-prepared-text-plan-v1\x00";
const source_ownership_domain =
    "glacier-prepared-text-ownership-v1\x00";
const target_ownership_domain =
    "glacier-prepared-text-source-replay-target-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidBoundPlan,
    InvalidContract,
    InvalidContext,
    InvalidEncoding,
    InvalidPlan,
    InvalidPrompt,
    InvalidSink,
    InvalidSourceRuntime,
    InvalidTargetOwnership,
    UnsafeDestination,
};

/// Durable logical identity for the source runtime. No process address or
/// operating-system identifier is admitted.
pub const SourceRuntimeIdentityV1 = struct {
    scheduler_epoch: u64,
    coordinator_id: u64,
    bank_epoch: u64,
};

/// Exact empty result-sink facts expected before generation two can become
/// visible.
pub const SinkFactsV1 = struct {
    storage_epoch: u64,
    capacity: u64,
    initial_sequence: u64,
    implementation_sha256: Digest,
    instance_sha256: Digest,
    empty_ledger_sha256: Digest,
    empty_selector_sha256: Digest,
};

/// Caller-recomputed generation-one context. The plan and bound plan are
/// validated but only their canonical roots are serialized.
pub const InputV1 = struct {
    prompt: []const u32,
    options: session.OptionsV1,
    scheduling: session.SchedulingV1,
    bound_plan_input: session.BoundPlanInputV1,
    plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
    source_runtime: SourceRuntimeIdentityV1,
    request_epoch: u64,
    publication_next_sequence: u64,
    challenge_sha256: Digest,
    target: successor.TargetOwnershipV1,
    sink_storage_epoch: u64,
    sink_capacity: usize,
    sink_initial_sequence: u64,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
};

pub const EncodedV1 = struct {
    bytes: []const u8,
    contract_sha256: Digest,
};

/// Alignment-independent, zero-copy decoded view. Prompt bytes borrow
/// `encoded`; use `promptToken` rather than casting them.
pub const DecodedV1 = struct {
    encoded: []const u8,
    canonical_prompt_u32_le: []const u8,
    options: session.OptionsV1,
    scheduling: session.SchedulingV1,
    bound_plan_input: session.BoundPlanInputV1,
    source_runtime: SourceRuntimeIdentityV1,
    request_epoch: u64,
    publication_next_sequence: u64,
    challenge_sha256: Digest,
    plan_sha256: Digest,
    bound_plan_sha256: Digest,
    prompt_sha256: Digest,
    artifact_sha256: Digest,
    execution_plan_sha256: Digest,
    residency_binding_sha256: Digest,
    target: successor.TargetOwnershipV1,
    target_ownership_sha256: Digest,
    sink: SinkFactsV1,
    contract_sha256: Digest,

    pub fn promptCount(self: *const DecodedV1) usize {
        return self.canonical_prompt_u32_le.len / @sizeOf(u32);
    }

    pub fn promptToken(
        self: *const DecodedV1,
        index: usize,
    ) Error!u32 {
        if (index >= self.promptCount())
            return Error.InvalidPrompt;
        const offset = index * @sizeOf(u32);
        return std.mem.readInt(
            u32,
            self.canonical_prompt_u32_le[offset..][0..4],
            .little,
        );
    }
};

const DerivedV1 = struct {
    prompt_sha256: Digest,
    plan_sha256: Digest,
    bound_plan_sha256: Digest,
    artifact_sha256: Digest,
    execution_plan_sha256: Digest,
    residency_binding_sha256: Digest,
    target_ownership_sha256: Digest,
    sink: SinkFactsV1,
};

pub fn encodedBytesV1(prompt_tokens: usize) Error!usize {
    const prompt_bytes = std.math.mul(
        usize,
        prompt_tokens,
        @sizeOf(u32),
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        minimum_encoded_bytes,
        prompt_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Validate every contextual value before publishing any destination byte.
pub fn encodeV1(
    input: InputV1,
    destination: []u8,
) Error!EncodedV1 {
    const derived = try validateInputV1(input);
    const required = try encodedBytesV1(input.prompt.len);
    if (destination.len < required)
        return Error.BufferTooSmall;
    const output = destination[0..required];
    if (slicesOverlap(
        output,
        std.mem.sliceAsBytes(input.prompt),
    ))
        return Error.UnsafeDestination;

    @memset(output, 0);
    const body = output[0 .. output.len - footer_bytes];
    var writer: Writer = .{ .bytes = body };
    writer.writeBytes(&contract_magic);
    writer.writeU64(contract_abi);
    writer.writeU64(@as(u64, @intCast(output.len)));
    writer.writeU64(allowed_flags);
    writer.writeU64(header_bytes);
    writer.writeU64(fixed_payload_bytes);
    writer.writeU64(@as(u64, @intCast(input.prompt.len)));
    writer.writeU64(@as(
        u64,
        @intCast(input.prompt.len * @sizeOf(u32)),
    ));
    writer.writeZeros(header_bytes - writer.position);
    std.debug.assert(writer.position == options_offset);

    writer.writeU64(input.options.max_new_tokens);
    writer.writeU64(input.options.eos_token);
    writer.writeU64(input.options.seed);
    std.debug.assert(writer.position == scheduling_offset);
    writer.writeU64(input.scheduling.tenant_key);
    writer.writeU64(input.scheduling.request_key);
    writer.writeU64(input.scheduling.request_generation);
    writer.writeU64(input.scheduling.resource_owner_key);
    writer.writeU64(input.scheduling.weight);
    writer.writeU64(input.scheduling.deadline_tick);
    std.debug.assert(writer.position == bound_plan_input_offset);
    writer.writeU64(input.bound_plan_input.request_epoch);
    writer.writeDigest(
        input.bound_plan_input.token_domain_sha256,
    );
    writer.writeDigest(
        input.bound_plan_input.token_domain_config_sha256,
    );
    writer.writeDigest(
        input.bound_plan_input.artifact_license_sha256,
    );
    writer.writeDigest(
        input.bound_plan_input.previous_plan_sha256,
    );
    std.debug.assert(writer.position == source_runtime_offset);
    writer.writeU64(input.source_runtime.scheduler_epoch);
    writer.writeU64(input.source_runtime.coordinator_id);
    writer.writeU64(input.source_runtime.bank_epoch);
    std.debug.assert(writer.position == request_offset);
    writer.writeU64(input.request_epoch);
    writer.writeU64(input.publication_next_sequence);
    writer.writeDigest(input.challenge_sha256);
    std.debug.assert(writer.position == plan_bindings_offset);
    writer.writeDigest(derived.plan_sha256);
    writer.writeDigest(derived.bound_plan_sha256);
    writer.writeDigest(derived.prompt_sha256);
    writer.writeDigest(derived.artifact_sha256);
    writer.writeDigest(derived.execution_plan_sha256);
    writer.writeDigest(derived.residency_binding_sha256);
    std.debug.assert(writer.position == target_offset);
    writeTargetV1(&writer, input.target);
    std.debug.assert(writer.position == target_root_offset);
    writer.writeDigest(derived.target_ownership_sha256);
    std.debug.assert(writer.position == sink_offset);
    writeSinkV1(&writer, derived.sink);
    std.debug.assert(writer.position == prompt_offset);
    for (input.prompt) |token| writer.writeU32(token);
    std.debug.assert(writer.position == body.len);

    const contract_sha256 = contractRootV1(body);
    @memcpy(output[body.len..], &contract_sha256);
    return .{
        .bytes = output,
        .contract_sha256 = contract_sha256,
    };
}

pub fn decodeV1(encoded: []const u8) Error!DecodedV1 {
    if (encoded.len < minimum_encoded_bytes)
        return Error.InvalidEncoding;
    const body = encoded[0 .. encoded.len - footer_bytes];
    const committed_sha256: Digest =
        encoded[body.len..][0..footer_bytes].*;
    const contract_sha256 = contractRootV1(body);
    if (!digestEqual(
        committed_sha256,
        contract_sha256,
    ))
        return Error.InvalidContract;

    var reader: Reader = .{ .bytes = body };
    if (!std.mem.eql(
        u8,
        try reader.readBytes(contract_magic.len),
        &contract_magic,
    ) or
        try reader.readU64() != contract_abi or
        try reader.readU64() != encoded.len or
        try reader.readU64() != allowed_flags or
        try reader.readU64() != header_bytes or
        try reader.readU64() != fixed_payload_bytes)
        return Error.InvalidEncoding;
    const prompt_count_u64 = try reader.readU64();
    const prompt_bytes_u64 = try reader.readU64();
    const reserved = try reader.readBytes(
        header_bytes - reader.position,
    );
    if (!allZero(reserved) or reader.position != options_offset)
        return Error.InvalidEncoding;
    const prompt_count = std.math.cast(
        usize,
        prompt_count_u64,
    ) orelse return Error.InvalidEncoding;
    const prompt_bytes = std.math.mul(
        usize,
        prompt_count,
        @sizeOf(u32),
    ) catch return Error.InvalidEncoding;
    if (prompt_bytes_u64 != prompt_bytes or
        try encodedBytesV1(prompt_count) != encoded.len)
        return Error.InvalidEncoding;

    const maximum_tokens_u64 = try reader.readU64();
    const maximum_tokens = std.math.cast(
        usize,
        maximum_tokens_u64,
    ) orelse return Error.InvalidEncoding;
    const eos_token = std.math.cast(
        u32,
        try reader.readU64(),
    ) orelse return Error.InvalidEncoding;
    const options: session.OptionsV1 = .{
        .max_new_tokens = maximum_tokens,
        .eos_token = eos_token,
        .seed = try reader.readU64(),
    };
    if (reader.position != scheduling_offset)
        return Error.InvalidEncoding;
    const scheduling: session.SchedulingV1 = .{
        .tenant_key = try reader.readU64(),
        .request_key = try reader.readU64(),
        .request_generation = try reader.readU64(),
        .resource_owner_key = try reader.readU64(),
        .weight = std.math.cast(
            u16,
            try reader.readU64(),
        ) orelse return Error.InvalidEncoding,
        .deadline_tick = try reader.readU64(),
    };
    if (reader.position != bound_plan_input_offset)
        return Error.InvalidEncoding;
    const bound_plan_input: session.BoundPlanInputV1 = .{
        .request_epoch = try reader.readU64(),
        .token_domain_sha256 = try reader.readDigest(),
        .token_domain_config_sha256 = try reader.readDigest(),
        .artifact_license_sha256 = try reader.readDigest(),
        .previous_plan_sha256 = try reader.readDigest(),
    };
    if (reader.position != source_runtime_offset)
        return Error.InvalidEncoding;
    const source_runtime: SourceRuntimeIdentityV1 = .{
        .scheduler_epoch = try reader.readU64(),
        .coordinator_id = try reader.readU64(),
        .bank_epoch = try reader.readU64(),
    };
    if (reader.position != request_offset)
        return Error.InvalidEncoding;
    const request_epoch = try reader.readU64();
    const publication_next_sequence = try reader.readU64();
    const challenge_sha256 = try reader.readDigest();
    if (reader.position != plan_bindings_offset)
        return Error.InvalidEncoding;
    const plan_sha256 = try reader.readDigest();
    const bound_plan_sha256 = try reader.readDigest();
    const prompt_sha256 = try reader.readDigest();
    const artifact_sha256 = try reader.readDigest();
    const execution_plan_sha256 = try reader.readDigest();
    const residency_binding_sha256 =
        try reader.readDigest();
    if (reader.position != target_offset)
        return Error.InvalidEncoding;
    const target = try readTargetV1(&reader);
    if (reader.position != target_root_offset)
        return Error.InvalidEncoding;
    const target_ownership_sha256 =
        try reader.readDigest();
    if (reader.position != sink_offset)
        return Error.InvalidEncoding;
    const sink = try readSinkV1(&reader);
    if (reader.position != prompt_offset)
        return Error.InvalidEncoding;
    const canonical_prompt_u32_le =
        try reader.readBytes(prompt_bytes);
    if (reader.position != body.len)
        return Error.InvalidEncoding;

    const decoded: DecodedV1 = .{
        .encoded = encoded,
        .canonical_prompt_u32_le = canonical_prompt_u32_le,
        .options = options,
        .scheduling = scheduling,
        .bound_plan_input = bound_plan_input,
        .source_runtime = source_runtime,
        .request_epoch = request_epoch,
        .publication_next_sequence = publication_next_sequence,
        .challenge_sha256 = challenge_sha256,
        .plan_sha256 = plan_sha256,
        .bound_plan_sha256 = bound_plan_sha256,
        .prompt_sha256 = prompt_sha256,
        .artifact_sha256 = artifact_sha256,
        .execution_plan_sha256 = execution_plan_sha256,
        .residency_binding_sha256 = residency_binding_sha256,
        .target = target,
        .target_ownership_sha256 = target_ownership_sha256,
        .sink = sink,
        .contract_sha256 = contract_sha256,
    };
    try validateDecodedShapeV1(decoded);
    return decoded;
}

/// Bind a decoded record back to independently recomputed request, plan,
/// target, runtime, and sink context.
pub fn verifyContextV1(
    supplied: DecodedV1,
    input: InputV1,
) Error!void {
    // DecodedV1 is a public view and can be assembled by a caller. Re-decode
    // its immutable wire image so contextual admission never trusts copied or
    // substituted fields in that view.
    const decoded = decodeV1(supplied.encoded) catch
        return Error.InvalidContext;
    if (!decodedViewEqualV1(supplied, decoded))
        return Error.InvalidContext;
    const derived = try validateInputV1(input);
    if (decoded.promptCount() != input.prompt.len or
        !std.meta.eql(decoded.options, input.options) or
        !std.meta.eql(decoded.scheduling, input.scheduling) or
        !std.meta.eql(
            decoded.bound_plan_input,
            input.bound_plan_input,
        ) or !std.meta.eql(
        decoded.source_runtime,
        input.source_runtime,
    ) or decoded.request_epoch != input.request_epoch or
        decoded.publication_next_sequence !=
            input.publication_next_sequence or
        !digestEqual(
            decoded.challenge_sha256,
            input.challenge_sha256,
        ) or !digestEqual(
        decoded.plan_sha256,
        derived.plan_sha256,
    ) or !digestEqual(
        decoded.bound_plan_sha256,
        derived.bound_plan_sha256,
    ) or !digestEqual(
        decoded.prompt_sha256,
        derived.prompt_sha256,
    ) or !digestEqual(
        decoded.artifact_sha256,
        derived.artifact_sha256,
    ) or !digestEqual(
        decoded.execution_plan_sha256,
        derived.execution_plan_sha256,
    ) or !digestEqual(
        decoded.residency_binding_sha256,
        derived.residency_binding_sha256,
    ) or !std.meta.eql(decoded.target, input.target) or
        !digestEqual(
            decoded.target_ownership_sha256,
            derived.target_ownership_sha256,
        ) or !std.meta.eql(decoded.sink, derived.sink))
        return Error.InvalidContext;

    for (input.prompt, 0..) |token, index| {
        if (try decoded.promptToken(index) != token)
            return Error.InvalidContext;
    }
}

fn decodedViewEqualV1(
    supplied: DecodedV1,
    canonical: DecodedV1,
) bool {
    return supplied.encoded.ptr == canonical.encoded.ptr and
        supplied.encoded.len == canonical.encoded.len and
        supplied.canonical_prompt_u32_le.ptr ==
            canonical.canonical_prompt_u32_le.ptr and
        supplied.canonical_prompt_u32_le.len ==
            canonical.canonical_prompt_u32_le.len and
        std.meta.eql(supplied.options, canonical.options) and
        std.meta.eql(supplied.scheduling, canonical.scheduling) and
        std.meta.eql(
            supplied.bound_plan_input,
            canonical.bound_plan_input,
        ) and
        std.meta.eql(
            supplied.source_runtime,
            canonical.source_runtime,
        ) and
        supplied.request_epoch == canonical.request_epoch and
        supplied.publication_next_sequence ==
            canonical.publication_next_sequence and
        digestEqual(
            supplied.challenge_sha256,
            canonical.challenge_sha256,
        ) and
        digestEqual(
            supplied.plan_sha256,
            canonical.plan_sha256,
        ) and
        digestEqual(
            supplied.bound_plan_sha256,
            canonical.bound_plan_sha256,
        ) and
        digestEqual(
            supplied.prompt_sha256,
            canonical.prompt_sha256,
        ) and
        digestEqual(
            supplied.artifact_sha256,
            canonical.artifact_sha256,
        ) and
        digestEqual(
            supplied.execution_plan_sha256,
            canonical.execution_plan_sha256,
        ) and
        digestEqual(
            supplied.residency_binding_sha256,
            canonical.residency_binding_sha256,
        ) and
        std.meta.eql(supplied.target, canonical.target) and
        digestEqual(
            supplied.target_ownership_sha256,
            canonical.target_ownership_sha256,
        ) and
        std.meta.eql(supplied.sink, canonical.sink) and
        digestEqual(
            supplied.contract_sha256,
            canonical.contract_sha256,
        );
}

pub fn contractRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(contract_domain);
    hash.update(body);
    return finish(&hash);
}

pub fn promptRootV1(prompt: []const u32) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prompt_domain);
    hashU64(&hash, @as(u64, @intCast(prompt.len)));
    for (prompt) |token| hashU32(&hash, token);
    return finish(&hash);
}

pub fn planRootV1(plan: session.PlanV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, plan.abi_version);
    hash.update(&plan.image_identity.source_fingerprint);
    hash.update(&plan.image_identity.abi_fingerprint);
    hashU64(&hash, plan.image_identity.container_bytes);
    hash.update(&plan.image_identity.container_sha256);
    hashU64(&hash, plan.prompt_tokens);
    hash.update(&plan.prompt_sha256);
    hashU64(&hash, plan.max_new_tokens);
    hashU32(&hash, plan.eos_token);
    hashU64(&hash, plan.seed);
    hashClaimV1(&hash, plan.claim);
    return finish(&hash);
}

/// Reproduce the ownership root installed by `makeBoundPlanV1` without
/// retaining a live Scheduler pointer.
pub fn sourceOwnershipRootV1(
    scheduling: session.SchedulingV1,
    source_runtime: SourceRuntimeIdentityV1,
    request_epoch: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_ownership_domain);
    hashU64(&hash, request_epoch);
    hashU64(&hash, source_runtime.scheduler_epoch);
    hashU64(&hash, source_runtime.bank_epoch);
    hashU64(&hash, scheduling.tenant_key);
    hashU64(&hash, scheduling.request_key);
    hashU64(&hash, scheduling.request_generation);
    hashU64(&hash, scheduling.resource_owner_key);
    hashU64(&hash, scheduling.weight);
    hashU64(&hash, scheduling.deadline_tick);
    return finish(&hash);
}

/// Contract-local canonical root over all target ownership fields. The
/// post-step successor intent later adds source checkpoint and boundary roots.
pub fn targetOwnershipRootV1(
    target: successor.TargetOwnershipV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(target_ownership_domain);
    hashU64(&hash, contract_abi);
    hashU64(&hash, successor.ownership_intent_abi);
    hashU64(&hash, resource_bank.abi);
    hashTargetV1(&hash, target);
    return finish(&hash);
}

fn validateInputV1(input: InputV1) Error!DerivedV1 {
    const prompt_count = std.math.cast(
        u64,
        input.prompt.len,
    ) orelse return Error.ArithmeticOverflow;
    const maximum_tokens = std.math.cast(
        u64,
        input.options.max_new_tokens,
    ) orelse return Error.ArithmeticOverflow;
    const sink_capacity = std.math.cast(
        u64,
        input.sink_capacity,
    ) orelse return Error.ArithmeticOverflow;
    if (input.prompt.len == 0)
        return Error.InvalidPrompt;
    if (input.options.max_new_tokens == 0 or
        input.request_epoch == 0 or
        input.publication_next_sequence == 0 or
        input.publication_next_sequence >= maximum_tokens or
        isZero(input.challenge_sha256))
        return Error.InvalidContext;
    if (input.scheduling.tenant_key == 0 or
        input.scheduling.request_key == 0 or
        input.scheduling.request_generation == 0 or
        input.scheduling.resource_owner_key == 0 or
        input.scheduling.weight == 0)
        return Error.InvalidContext;
    if (input.source_runtime.scheduler_epoch == 0 or
        input.source_runtime.coordinator_id == 0 or
        input.source_runtime.bank_epoch == 0)
        return Error.InvalidSourceRuntime;
    if (input.bound_plan_input.request_epoch !=
        input.request_epoch or
        isZero(input.bound_plan_input.token_domain_sha256) or
        isZero(
            input.bound_plan_input
                .token_domain_config_sha256,
        ) or isZero(
        input.bound_plan_input.artifact_license_sha256,
    ))
        return Error.InvalidContext;

    const prompt_sha256 = promptRootV1(input.prompt);
    const plan_sha256 = planRootV1(input.plan);
    const expected_output_journal = std.math.mul(
        u64,
        maximum_tokens,
        @sizeOf(u32),
    ) catch return Error.ArithmeticOverflow;
    _ = input.plan.claim.hostBytes() catch
        return Error.InvalidPlan;
    if (input.plan.abi_version != session.plan_abi or
        input.plan.image_identity.container_bytes == 0 or
        isZero(
            input.plan.image_identity.source_fingerprint,
        ) or isZero(
        input.plan.image_identity.abi_fingerprint,
    ) or isZero(
        input.plan.image_identity.container_sha256,
    ) or input.plan.prompt_tokens != prompt_count or
        !digestEqual(
            input.plan.prompt_sha256,
            prompt_sha256,
        ) or input.plan.max_new_tokens != maximum_tokens or
        input.plan.eos_token != input.options.eos_token or
        input.plan.seed != input.options.seed or
        input.plan.claim.queue_slots != 1 or
        input.plan.claim.output_journal_bytes !=
            expected_output_journal or
        !digestEqual(input.plan.plan_sha256, plan_sha256))
        return Error.InvalidPlan;

    session.validateBoundPlanV1(input.bound_plan) catch
        return Error.InvalidBoundPlan;
    const bound_plan_sha256 =
        session.boundPlanRootV1(input.bound_plan);
    const next_target_generation = std.math.add(
        u64,
        input.scheduling.request_generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (!digestEqual(
        input.bound_plan.bound_plan_sha256,
        bound_plan_sha256,
    ) or !digestEqual(
        input.bound_plan.local_plan_sha256,
        plan_sha256,
    ) or !digestEqual(
        input.bound_plan.token_domain_sha256,
        input.bound_plan_input.token_domain_sha256,
    ) or !digestEqual(
        input.bound_plan.token_domain_config_sha256,
        input.bound_plan_input
            .token_domain_config_sha256,
    ) or !digestEqual(
        input.bound_plan.artifact_license_sha256,
        input.bound_plan_input.artifact_license_sha256,
    ) or input.bound_plan.artifact.input_features !=
        prompt_count or
        input.bound_plan.artifact.output_dimensions !=
            maximum_tokens or
        input.bound_plan.artifact.weight_bytes !=
            input.plan.image_identity.container_bytes or
        !digestEqual(
            input.bound_plan.artifact.weights_sha256,
            input.plan.image_identity.container_sha256,
        ) or input.bound_plan.execution.request_epoch !=
        input.request_epoch or
        input.bound_plan.execution.generation !=
            input.scheduling.request_generation or
        input.bound_plan.execution.publication_next_sequence !=
            0 or
        !digestEqual(
            input.bound_plan.execution.media_object_sha256,
            prompt_sha256,
        ) or !digestEqual(
        input.bound_plan.execution.processor_state_sha256,
        input.bound_plan_input.token_domain_sha256,
    ) or !digestEqual(
        input.bound_plan.execution.processor_bundle_sha256,
        input.bound_plan_input
            .token_domain_config_sha256,
    ) or !digestEqual(
        input.bound_plan.execution.challenge_sha256,
        input.challenge_sha256,
    ) or !digestEqual(
        input.bound_plan.execution.previous_plan_sha256,
        input.bound_plan_input.previous_plan_sha256,
    ) or !digestEqual(
        input.bound_plan.execution.ownership_sha256,
        sourceOwnershipRootV1(
            input.scheduling,
            input.source_runtime,
            input.request_epoch,
        ),
    ) or !std.meta.eql(
        input.bound_plan.residency.request_claim,
        input.plan.claim,
    ))
        return Error.InvalidBoundPlan;

    try validateTargetV1(
        input.target,
        input.plan.claim,
        input.source_runtime,
        input.scheduling,
        next_target_generation,
    );
    if (input.sink_storage_epoch == 0 or
        sink_capacity == 0 or
        input.sink_initial_sequence !=
            input.publication_next_sequence or
        isZero(input.sink_implementation_sha256) or
        isZero(input.sink_instance_sha256))
        return Error.InvalidSink;
    const expected_capacity = std.math.sub(
        u64,
        maximum_tokens,
        input.publication_next_sequence,
    ) catch return Error.InvalidSink;
    if (sink_capacity != expected_capacity)
        return Error.InvalidSink;
    const sink = try makeSinkFactsV1(
        plan_sha256,
        input.request_epoch,
        input.sink_storage_epoch,
        sink_capacity,
        input.sink_initial_sequence,
        input.sink_implementation_sha256,
        input.sink_instance_sha256,
    );

    return .{
        .prompt_sha256 = prompt_sha256,
        .plan_sha256 = plan_sha256,
        .bound_plan_sha256 = bound_plan_sha256,
        .artifact_sha256 = input.bound_plan.artifact.artifact_sha256,
        .execution_plan_sha256 = input.bound_plan.execution.plan_sha256,
        .residency_binding_sha256 = input.bound_plan.residency.binding_sha256,
        .target_ownership_sha256 = targetOwnershipRootV1(input.target),
        .sink = sink,
    };
}

fn validateDecodedShapeV1(decoded: DecodedV1) Error!void {
    const maximum_tokens = std.math.cast(
        u64,
        decoded.options.max_new_tokens,
    ) orelse return Error.InvalidContract;
    if (decoded.promptCount() == 0 or
        decoded.options.max_new_tokens == 0 or
        decoded.scheduling.tenant_key == 0 or
        decoded.scheduling.request_key == 0 or
        decoded.scheduling.request_generation == 0 or
        decoded.scheduling.resource_owner_key == 0 or
        decoded.scheduling.weight == 0 or
        decoded.source_runtime.scheduler_epoch == 0 or
        decoded.source_runtime.coordinator_id == 0 or
        decoded.source_runtime.bank_epoch == 0 or
        decoded.request_epoch == 0 or
        decoded.publication_next_sequence == 0 or
        decoded.publication_next_sequence >= maximum_tokens or
        decoded.bound_plan_input.request_epoch !=
            decoded.request_epoch or
        isZero(
            decoded.bound_plan_input.token_domain_sha256,
        ) or isZero(
        decoded.bound_plan_input.token_domain_config_sha256,
    ) or isZero(
        decoded.bound_plan_input.artifact_license_sha256,
    ) or isZero(decoded.challenge_sha256) or
        isZero(decoded.plan_sha256) or
        isZero(decoded.bound_plan_sha256) or
        isZero(decoded.prompt_sha256) or
        isZero(decoded.artifact_sha256) or
        isZero(decoded.execution_plan_sha256) or
        isZero(decoded.residency_binding_sha256) or
        !digestEqual(
            decoded.prompt_sha256,
            promptRootFromWireV1(
                decoded.promptCount(),
                decoded.canonical_prompt_u32_le,
            ),
        ))
        return Error.InvalidContract;
    const expected_target_generation = std.math.add(
        u64,
        decoded.scheduling.request_generation,
        1,
    ) catch return Error.InvalidContract;
    try validateTargetV1(
        decoded.target,
        decoded.target.request_claim,
        decoded.source_runtime,
        decoded.scheduling,
        expected_target_generation,
    );
    if (!digestEqual(
        decoded.target_ownership_sha256,
        targetOwnershipRootV1(decoded.target),
    ))
        return Error.InvalidContract;
    const expected_capacity = std.math.sub(
        u64,
        maximum_tokens,
        decoded.publication_next_sequence,
    ) catch return Error.InvalidContract;
    if (decoded.sink.storage_epoch == 0 or
        decoded.sink.capacity == 0 or
        decoded.sink.capacity != expected_capacity or
        decoded.sink.initial_sequence !=
            decoded.publication_next_sequence or
        isZero(decoded.sink.implementation_sha256) or
        isZero(decoded.sink.instance_sha256))
        return Error.InvalidSink;
    const expected_sink = try makeSinkFactsV1(
        decoded.plan_sha256,
        decoded.request_epoch,
        decoded.sink.storage_epoch,
        decoded.sink.capacity,
        decoded.sink.initial_sequence,
        decoded.sink.implementation_sha256,
        decoded.sink.instance_sha256,
    );
    if (!std.meta.eql(decoded.sink, expected_sink))
        return Error.InvalidSink;
}

fn validateTargetV1(
    target: successor.TargetOwnershipV1,
    expected_claim: resource_bank.Claim,
    source_runtime: SourceRuntimeIdentityV1,
    scheduling: session.SchedulingV1,
    expected_generation: u64,
) Error!void {
    _ = target.request_claim.hostBytes() catch
        return Error.InvalidTargetOwnership;
    if (target.scheduler_epoch == 0 or
        target.coordinator_id == 0 or
        target.bank_epoch == 0 or
        target.request_generation == 0 or
        target.resource_owner_key == 0 or
        target.tree_key == 0 or
        target.authority_key == 0 or
        target.tenant_key == 0 or
        target.scope_key == 0 or
        target.cache_node_key == 0 or
        target.cache_binding_key == 0 or
        target.intent_generation == 0 or
        target.request_generation != expected_generation or
        target.intent_generation != expected_generation or
        target.bank_epoch == source_runtime.bank_epoch or
        target.resource_owner_key ==
            scheduling.resource_owner_key or
        !std.meta.eql(target.request_claim, expected_claim))
        return Error.InvalidTargetOwnership;
}

fn makeSinkFactsV1(
    request_sha256: Digest,
    request_epoch: u64,
    storage_epoch: u64,
    capacity: u64,
    initial_sequence: u64,
    implementation_sha256: Digest,
    instance_sha256: Digest,
) Error!SinkFactsV1 {
    var ledger_storage: [
        result_sink_file.ledger_header_bytes +
            result_sink_file.ledger_footer_bytes
    ]u8 = undefined;
    const ledger = result_sink_file.encodeLedgerV1(
        request_sha256,
        request_epoch,
        initial_sequence,
        implementation_sha256,
        instance_sha256,
        &.{},
        &ledger_storage,
    ) catch return Error.InvalidSink;
    const selector =
        result_sink_file.prepareInitialSelectorV1(
            ledger,
        ) catch return Error.InvalidSink;
    return .{
        .storage_epoch = storage_epoch,
        .capacity = capacity,
        .initial_sequence = initial_sequence,
        .implementation_sha256 = implementation_sha256,
        .instance_sha256 = instance_sha256,
        .empty_ledger_sha256 = ledger.ledger_sha256,
        .empty_selector_sha256 = selector.selector_sha256,
    };
}

fn writeTargetV1(
    writer: *Writer,
    target: successor.TargetOwnershipV1,
) void {
    writer.writeU64(target.scheduler_epoch);
    writer.writeU64(target.coordinator_id);
    writer.writeU64(target.bank_epoch);
    writer.writeU64(target.request_generation);
    writer.writeU64(target.resource_owner_key);
    writer.writeU64(target.tree_key);
    writer.writeU64(target.authority_key);
    writer.writeU64(target.tenant_key);
    writer.writeU64(target.scope_key);
    writer.writeU64(target.cache_node_key);
    writer.writeU64(target.cache_binding_key);
    writer.writeU64(target.intent_generation);
    writeClaimV1(writer, target.request_claim);
}

fn readTargetV1(
    reader: *Reader,
) Error!successor.TargetOwnershipV1 {
    return .{
        .scheduler_epoch = try reader.readU64(),
        .coordinator_id = try reader.readU64(),
        .bank_epoch = try reader.readU64(),
        .request_generation = try reader.readU64(),
        .resource_owner_key = try reader.readU64(),
        .tree_key = try reader.readU64(),
        .authority_key = try reader.readU64(),
        .tenant_key = try reader.readU64(),
        .scope_key = try reader.readU64(),
        .cache_node_key = try reader.readU64(),
        .cache_binding_key = try reader.readU64(),
        .intent_generation = try reader.readU64(),
        .request_claim = try readClaimV1(reader),
    };
}

fn writeSinkV1(writer: *Writer, sink: SinkFactsV1) void {
    writer.writeU64(sink.storage_epoch);
    writer.writeU64(sink.capacity);
    writer.writeU64(sink.initial_sequence);
    writer.writeDigest(sink.implementation_sha256);
    writer.writeDigest(sink.instance_sha256);
    writer.writeDigest(sink.empty_ledger_sha256);
    writer.writeDigest(sink.empty_selector_sha256);
}

fn readSinkV1(reader: *Reader) Error!SinkFactsV1 {
    return .{
        .storage_epoch = try reader.readU64(),
        .capacity = try reader.readU64(),
        .initial_sequence = try reader.readU64(),
        .implementation_sha256 = try reader.readDigest(),
        .instance_sha256 = try reader.readDigest(),
        .empty_ledger_sha256 = try reader.readDigest(),
        .empty_selector_sha256 = try reader.readDigest(),
    };
}

fn writeClaimV1(
    writer: *Writer,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        writer.writeU64(@field(claim, field.name));
}

fn readClaimV1(
    reader: *Reader,
) Error!resource_bank.Claim {
    return .{
        .capsule_bytes = try reader.readU64(),
        .kv_bytes = try reader.readU64(),
        .activation_bytes = try reader.readU64(),
        .partial_bytes = try reader.readU64(),
        .logits_bytes = try reader.readU64(),
        .output_journal_bytes = try reader.readU64(),
        .staging_bytes = try reader.readU64(),
        .device_bytes = try reader.readU64(),
        .io_bytes = try reader.readU64(),
        .queue_slots = try reader.readU64(),
    };
}

fn hashTargetV1(
    hash: *std.crypto.hash.sha2.Sha256,
    target: successor.TargetOwnershipV1,
) void {
    hashU64(hash, target.scheduler_epoch);
    hashU64(hash, target.coordinator_id);
    hashU64(hash, target.bank_epoch);
    hashU64(hash, target.request_generation);
    hashU64(hash, target.resource_owner_key);
    hashU64(hash, target.tree_key);
    hashU64(hash, target.authority_key);
    hashU64(hash, target.tenant_key);
    hashU64(hash, target.scope_key);
    hashU64(hash, target.cache_node_key);
    hashU64(hash, target.cache_binding_key);
    hashU64(hash, target.intent_generation);
    hashClaimV1(hash, target.request_claim);
}

fn hashClaimV1(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn promptRootFromWireV1(
    prompt_count: usize,
    canonical_u32_le: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prompt_domain);
    hashU64(&hash, @as(u64, @intCast(prompt_count)));
    hash.update(canonical_u32_le);
    return finish(&hash);
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

fn finish(
    hash: *std.crypto.hash.sha2.Sha256,
) Digest {
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn slicesOverlap(
    left: []const u8,
    right: []const u8,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(
        usize,
        left_start,
        left.len,
    ) catch std.math.maxInt(usize);
    const right_end = std.math.add(
        usize,
        right_start,
        right.len,
    ) catch std.math.maxInt(usize);
    return left_start < right_end and
        right_start < left_end;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(
        self: *Writer,
        value: []const u8,
    ) void {
        const end = self.position + value.len;
        std.debug.assert(end <= self.bytes.len);
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeZeros(self: *Writer, count: usize) void {
        const end = self.position + count;
        std.debug.assert(end <= self.bytes.len);
        @memset(self.bytes[self.position..end], 0);
        self.position = end;
    }

    fn writeU32(self: *Writer, value: u32) void {
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, value, .little);
        self.writeBytes(&encoded);
    }

    fn writeU64(self: *Writer, value: anytype) void {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, @intCast(value), .little);
        self.writeBytes(&encoded);
    }

    fn writeDigest(self: *Writer, value: Digest) void {
        self.writeBytes(&value);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(
        self: *Reader,
        count: usize,
    ) Error![]const u8 {
        const end = std.math.add(
            usize,
            self.position,
            count,
        ) catch return Error.InvalidEncoding;
        if (end > self.bytes.len)
            return Error.InvalidEncoding;
        const value = self.bytes[self.position..end];
        self.position = end;
        return value;
    }

    fn readU64(self: *Reader) Error!u64 {
        return std.mem.readInt(
            u64,
            (try self.readBytes(8))[0..8],
            .little,
        );
    }

    fn readDigest(self: *Reader) Error!Digest {
        return (try self.readBytes(32))[0..32].*;
    }
};

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

const TestFixture = struct {
    prompt: [3]u32,
    input_value: InputV1,

    fn init() !TestFixture {
        const prompt = [_]u32{ 5, 7, 11 };
        const options: session.OptionsV1 = .{
            .max_new_tokens = 5,
            .eos_token = std.math.maxInt(u32),
            .seed = 0x1020_3040_5060_7080,
        };
        const scheduling: session.SchedulingV1 = .{
            .tenant_key = 0x501,
            .request_key = 0x502,
            .request_generation = 1,
            .resource_owner_key = 0x503,
            .weight = 1,
        };
        const source_runtime: SourceRuntimeIdentityV1 = .{
            .scheduler_epoch = 0x601,
            .coordinator_id = 0x602,
            .bank_epoch = 0x603,
        };
        const bound_plan_input: session.BoundPlanInputV1 = .{
            .request_epoch = 0x0102_0304_0506_0708,
            .token_domain_sha256 = filledDigest(0x32),
            .token_domain_config_sha256 = filledDigest(0x33),
            .artifact_license_sha256 = filledDigest(0x43),
        };
        const request_claim: resource_bank.Claim = .{
            .capsule_bytes = 64,
            .kv_bytes = 224,
            .activation_bytes = 12,
            .partial_bytes = 64,
            .logits_bytes = 1024,
            .output_journal_bytes = options.max_new_tokens * @sizeOf(u32),
            .staging_bytes = 32,
            .queue_slots = 1,
        };
        const total_claim: resource_bank.Claim = .{
            .capsule_bytes = 4160,
            .kv_bytes = request_claim.kv_bytes,
            .activation_bytes = request_claim.activation_bytes,
            .partial_bytes = request_claim.partial_bytes,
            .logits_bytes = request_claim.logits_bytes,
            .output_journal_bytes = request_claim.output_journal_bytes,
            .staging_bytes = request_claim.staging_bytes,
            .queue_slots = request_claim.queue_slots,
        };
        var plan: session.PlanV1 = .{
            .image_identity = .{
                .source_fingerprint = filledDigest(0x51),
                .abi_fingerprint = filledDigest(0x52),
                .container_bytes = 4096,
                .container_sha256 = filledDigest(0x41),
            },
            .prompt_tokens = prompt.len,
            .prompt_sha256 = promptRootV1(&prompt),
            .max_new_tokens = options.max_new_tokens,
            .eos_token = options.eos_token,
            .seed = options.seed,
            .claim = request_claim,
            .plan_sha256 = zero_digest,
        };
        plan.plan_sha256 = planRootV1(plan);
        const artifact =
            try model_contract.makeArtifactManifestFromDigestV1(
                .autoregressive,
                session.prepared_artifact_profile_abi,
                .token_ids,
                .token_ids,
                .implementation_defined,
                1,
                prompt.len,
                options.max_new_tokens,
                @sizeOf(u32),
                @sizeOf(u32),
                1,
                plan.image_identity.container_bytes,
                plan.image_identity.container_sha256,
                filledDigest(0x42),
                bound_plan_input.artifact_license_sha256,
            );
        const challenge = filledDigest(0xcc);
        const execution =
            try model_contract.makeExecutionPlanV1(
                artifact,
                .generate_sequence,
                .{
                    .request_epoch = bound_plan_input.request_epoch,
                    .generation = scheduling.request_generation,
                    .batch_items = 1,
                    .publication_next_sequence = 0,
                    .maximum_absolute_output = 255,
                    .claim = total_claim,
                    .media_object_sha256 = plan.prompt_sha256,
                    .processor_state_sha256 = bound_plan_input
                        .token_domain_sha256,
                    .processor_bundle_sha256 = bound_plan_input
                        .token_domain_config_sha256,
                    .cache_bundle_sha256 = filledDigest(0x34),
                    .cache_payload_sha256 = filledDigest(0x35),
                    .ownership_sha256 = sourceOwnershipRootV1(
                        scheduling,
                        source_runtime,
                        bound_plan_input.request_epoch,
                    ),
                    .challenge_sha256 = challenge,
                    .previous_plan_sha256 = bound_plan_input.previous_plan_sha256,
                    .input_schema_sha256 = filledDigest(0x37),
                    .output_schema_sha256 = filledDigest(0x38),
                    .scratch_bytes = request_claim.partial_bytes,
                },
            );
        const residency =
            try model_contract.makeExecutionResidencyBindingV1(
                execution,
                .shared_read_only,
                plan.image_identity.container_bytes,
                request_claim,
            );
        var bound_plan: session.BoundPlanV1 = .{
            .local_plan_sha256 = plan.plan_sha256,
            .artifact = artifact,
            .execution = execution,
            .residency = residency,
            .token_domain_sha256 = bound_plan_input.token_domain_sha256,
            .token_domain_config_sha256 = bound_plan_input
                .token_domain_config_sha256,
            .artifact_license_sha256 = bound_plan_input.artifact_license_sha256,
            .bound_plan_sha256 = zero_digest,
        };
        bound_plan.bound_plan_sha256 =
            session.boundPlanRootV1(bound_plan);
        try session.validateBoundPlanV1(bound_plan);
        const target: successor.TargetOwnershipV1 = .{
            .scheduler_epoch = 0x701,
            .coordinator_id = 0x702,
            .bank_epoch = 0x703,
            .request_generation = 2,
            .resource_owner_key = 0x704,
            .tree_key = 0x705,
            .authority_key = 0x706,
            .tenant_key = 0x707,
            .scope_key = 0x708,
            .cache_node_key = 0x709,
            .cache_binding_key = 0x70a,
            .intent_generation = 2,
            .request_claim = request_claim,
        };
        var result: TestFixture = undefined;
        result.prompt = prompt;
        result.input_value = .{
            // `input()` installs the final, post-return address.
            .prompt = &.{},
            .options = options,
            .scheduling = scheduling,
            .bound_plan_input = bound_plan_input,
            .plan = plan,
            .bound_plan = bound_plan,
            .source_runtime = source_runtime,
            .request_epoch = bound_plan_input.request_epoch,
            .publication_next_sequence = 2,
            .challenge_sha256 = challenge,
            .target = target,
            .sink_storage_epoch = 0x801,
            .sink_capacity = 3,
            .sink_initial_sequence = 2,
            .sink_implementation_sha256 = filledDigest(0x91),
            .sink_instance_sha256 = filledDigest(0x92),
        };
        return result;
    }

    fn input(self: *const TestFixture) InputV1 {
        var value = self.input_value;
        value.prompt = &self.prompt;
        return value;
    }
};

test "source replay contract is canonical and context bound" {
    const fixture = try TestFixture.init();
    const required = try encodedBytesV1(
        fixture.prompt.len,
    );
    try std.testing.expectEqual(@as(usize, 1004), required);
    var first: [1004]u8 = undefined;
    var second: [1004]u8 = undefined;
    const encoded = try encodeV1(
        fixture.input(),
        &first,
    );
    const repeated = try encodeV1(
        fixture.input(),
        &second,
    );
    try std.testing.expectEqualSlices(
        u8,
        encoded.bytes,
        repeated.bytes,
    );
    try std.testing.expectEqual(
        encoded.contract_sha256,
        repeated.contract_sha256,
    );

    const decoded = try decodeV1(encoded.bytes);
    try verifyContextV1(decoded, fixture.input());
    try std.testing.expectEqual(
        fixture.prompt.len,
        decoded.promptCount(),
    );
    for (fixture.prompt, 0..) |token, index|
        try std.testing.expectEqual(
            token,
            try decoded.promptToken(index),
        );
    try std.testing.expectEqual(
        @as(u64, 3),
        decoded.sink.capacity,
    );
    try std.testing.expectEqual(
        fixture.input_value.sink_storage_epoch,
        decoded.sink.storage_epoch,
    );
    try std.testing.expect(
        !isZero(decoded.sink.empty_ledger_sha256) and
            !isZero(decoded.sink.empty_selector_sha256),
    );
}

test "source replay contract rejects every single byte mutation" {
    const fixture = try TestFixture.init();
    var canonical: [1004]u8 = undefined;
    const encoded = try encodeV1(
        fixture.input(),
        &canonical,
    );
    var mutated: [1004]u8 = undefined;
    for (0..encoded.bytes.len) |index| {
        @memcpy(&mutated, encoded.bytes);
        mutated[index] ^= 0x01;
        try std.testing.expectError(
            Error.InvalidContract,
            decodeV1(&mutated),
        );
    }
}

test "source replay context rejects coherent foreign roots" {
    const fixture = try TestFixture.init();
    var canonical: [1004]u8 = undefined;
    const encoded = try encodeV1(
        fixture.input(),
        &canonical,
    );

    var coherently_rerooted = canonical;
    const coordinator =
        std.mem.readInt(
            u64,
            coherently_rerooted[source_runtime_offset + 8 ..][0..8],
            .little,
        );
    std.mem.writeInt(
        u64,
        coherently_rerooted[source_runtime_offset + 8 ..][0..8],
        coordinator + 1,
        .little,
    );
    const body =
        coherently_rerooted[0 .. coherently_rerooted.len - footer_bytes];
    const rerooted = contractRootV1(body);
    @memcpy(
        coherently_rerooted[body.len..],
        &rerooted,
    );
    const decoded = try decodeV1(&coherently_rerooted);
    try std.testing.expectError(
        Error.InvalidContext,
        verifyContextV1(decoded, fixture.input()),
    );

    const canonical_decoded = try decodeV1(encoded.bytes);
    var forged_view = canonical_decoded;
    forged_view.source_runtime.coordinator_id += 1;
    try std.testing.expectError(
        Error.InvalidContext,
        verifyContextV1(
            forged_view,
            fixture.input(),
        ),
    );

    var foreign_target_wire: [1004]u8 = undefined;
    var foreign_target_contract = fixture.input();
    foreign_target_contract.target.authority_key += 1;
    const foreign_target_encoded = try encodeV1(
        foreign_target_contract,
        &foreign_target_wire,
    );
    const foreign_target_decoded = try decodeV1(
        foreign_target_encoded.bytes,
    );
    try std.testing.expectError(
        Error.InvalidContext,
        verifyContextV1(
            foreign_target_decoded,
            fixture.input(),
        ),
    );

    var foreign_sink = fixture.input();
    foreign_sink.sink_instance_sha256 =
        filledDigest(0xa2);
    try std.testing.expectError(
        Error.InvalidContext,
        verifyContextV1(
            canonical_decoded,
            foreign_sink,
        ),
    );
    var foreign_target = fixture.input();
    foreign_target.target.authority_key += 1;
    try std.testing.expectError(
        Error.InvalidContext,
        verifyContextV1(
            canonical_decoded,
            foreign_target,
        ),
    );
}

test "source replay rejects zero overflow and overlap inputs" {
    const fixture = try TestFixture.init();
    var storage = [_]u8{0xa5} ** 1004;

    var zero_runtime = fixture.input();
    zero_runtime.source_runtime.bank_epoch = 0;
    try std.testing.expectError(
        Error.InvalidSourceRuntime,
        encodeV1(zero_runtime, &storage),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &storage, 0xa5),
    );

    var zero_target = fixture.input();
    zero_target.target.cache_node_key = 0;
    try std.testing.expectError(
        Error.InvalidTargetOwnership,
        encodeV1(zero_target, &storage),
    );
    var wrong_capacity = fixture.input();
    wrong_capacity.sink_capacity = 2;
    try std.testing.expectError(
        Error.InvalidSink,
        encodeV1(wrong_capacity, &storage),
    );
    var overflowing_claim = fixture.input();
    overflowing_claim.target.request_claim.capsule_bytes =
        std.math.maxInt(u64);
    try std.testing.expectError(
        Error.InvalidTargetOwnership,
        encodeV1(overflowing_claim, &storage),
    );

    var overlap_storage: [1004]u8 align(@alignOf(u32)) =
        [_]u8{0x5a} ** 1004;
    @memcpy(
        overlap_storage[0 .. fixture.prompt.len * @sizeOf(u32)],
        std.mem.sliceAsBytes(&fixture.prompt),
    );
    const before = overlap_storage;
    var overlap_input = fixture.input();
    overlap_input.prompt = std.mem.bytesAsSlice(
        u32,
        overlap_storage[0 .. fixture.prompt.len * @sizeOf(u32)],
    );
    try std.testing.expectError(
        Error.UnsafeDestination,
        encodeV1(overlap_input, &overlap_storage),
    );
    try std.testing.expectEqualSlices(
        u8,
        &before,
        &overlap_storage,
    );
}
