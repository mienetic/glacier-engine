//! Canonical generation-one recovery contract for a one-token terminal
//! prepared-text source.
//!
//! This contract is the terminal-only sibling of
//! `prepared_text_source_recovery`: it retains every value needed to
//! reproduce and independently verify the source execution, while omitting
//! target and result-sink facts that can never be used when the first token
//! is also the final token. It grants no Scheduler, ResourceBank, checkpoint,
//! or publication authority.

const std = @import("std");
const core = @import("core");
const model_contract = core.model_contract;
const resource_bank = core.resource_bank;
const session = @import("prepared_text_session.zig");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const contract_abi: u64 = 0x4750_5454_0000_0001;
pub const contract_magic =
    [_]u8{ 'G', 'P', 'T', 'T', 'R', 'M', '0', '1' };
pub const allowed_flags: u64 = 0;
pub const header_bytes: usize = 128;
pub const fixed_payload_bytes: usize = 472;
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

comptime {
    if (options_offset != 128 or
        scheduling_offset != 152 or
        bound_plan_input_offset != 200 or
        source_runtime_offset != 336 or
        request_offset != 360 or
        plan_bindings_offset != 408 or
        plan_bindings_offset + 192 != prompt_offset)
        @compileError(
            "prepared-text terminal source recovery layout drift",
        );
}

const contract_domain =
    "glacier-prepared-text-terminal-source-recovery-contract-v1\x00";
const prompt_domain = "glacier-prepared-text-prompt-v1\x00";
const plan_domain = "glacier-prepared-text-plan-v1\x00";
const source_ownership_domain =
    "glacier-prepared-text-ownership-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidBoundPlan,
    InvalidContract,
    InvalidContext,
    InvalidEncoding,
    InvalidPlan,
    InvalidPrompt,
    InvalidSourceRuntime,
    UnsafeDestination,
};

/// Durable logical source identity. Process addresses and OS-local
/// identifiers are deliberately excluded.
pub const SourceRuntimeIdentityV1 = struct {
    scheduler_epoch: u64,
    coordinator_id: u64,
    bank_epoch: u64,
};

/// Independently recomputed context for a direct one-token terminal source.
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
};

pub const EncodedV1 = struct {
    bytes: []const u8,
    contract_sha256: Digest,
};

/// Alignment-independent decoded view. The canonical prompt borrows
/// `encoded`; callers must use `promptToken` rather than casting its bytes.
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

/// Validate the complete context before publishing the first destination
/// byte.
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
        .contract_sha256 = contract_sha256,
    };
    try validateDecodedShapeV1(decoded);
    return decoded;
}

/// Bind a decoded record back to independently recomputed model, plan, and
/// source-runtime context.
pub fn verifyContextV1(
    supplied: DecodedV1,
    input: InputV1,
) Error!void {
    // DecodedV1 is public and may be assembled by a caller. Re-decode its
    // immutable wire before trusting any copied view field.
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
    ))
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

/// Reproduce the source ownership root installed by `makeBoundPlanV1`
/// without retaining a Scheduler pointer.
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

fn validateInputV1(input: InputV1) Error!DerivedV1 {
    const prompt_count = std.math.cast(
        u64,
        input.prompt.len,
    ) orelse return Error.ArithmeticOverflow;
    const maximum_tokens = std.math.cast(
        u64,
        input.options.max_new_tokens,
    ) orelse return Error.ArithmeticOverflow;
    if (input.prompt.len == 0)
        return Error.InvalidPrompt;
    if (maximum_tokens != 1 or
        input.request_epoch == 0 or
        input.publication_next_sequence != 1 or
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
        input.bound_plan.artifact.output_dimensions != 1 or
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

    return .{
        .prompt_sha256 = prompt_sha256,
        .plan_sha256 = plan_sha256,
        .bound_plan_sha256 = bound_plan_sha256,
        .artifact_sha256 = input.bound_plan.artifact.artifact_sha256,
        .execution_plan_sha256 = input.bound_plan.execution.plan_sha256,
        .residency_binding_sha256 = input.bound_plan.residency.binding_sha256,
    };
}

fn validateDecodedShapeV1(decoded: DecodedV1) Error!void {
    if (decoded.promptCount() == 0 or
        decoded.options.max_new_tokens != 1 or
        decoded.scheduling.tenant_key == 0 or
        decoded.scheduling.request_key == 0 or
        decoded.scheduling.request_generation == 0 or
        decoded.scheduling.resource_owner_key == 0 or
        decoded.scheduling.weight == 0 or
        decoded.source_runtime.scheduler_epoch == 0 or
        decoded.source_runtime.coordinator_id == 0 or
        decoded.source_runtime.bank_epoch == 0 or
        decoded.request_epoch == 0 or
        decoded.publication_next_sequence != 1 or
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
}

fn writeClaimV1(
    writer: *Writer,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        writer.writeU64(@field(claim, field.name));
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

fn digestFromHex(hex: []const u8) !Digest {
    var output: Digest = undefined;
    _ = try std.fmt.hexToBytes(&output, hex);
    return output;
}

const TestFixture = struct {
    prompt: [3]u32,
    input_value: InputV1,

    fn init() !TestFixture {
        const prompt = [_]u32{ 5, 7, 11 };
        const options: session.OptionsV1 = .{
            .max_new_tokens = 1,
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
                    .previous_plan_sha256 = bound_plan_input
                        .previous_plan_sha256,
                    .input_schema_sha256 = filledDigest(0x37),
                    .output_schema_sha256 = filledDigest(0x38),
                    .scratch_bytes = request_claim.partial_bytes,
                },
            );
        const residency =
            try model_contract
                .makeExecutionResidencyBindingV1(
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
            .publication_next_sequence = 1,
            .challenge_sha256 = challenge,
        };
        return result;
    }

    fn input(self: *const TestFixture) InputV1 {
        var value = self.input_value;
        value.prompt = &self.prompt;
        return value;
    }
};

test "terminal source recovery root matches independent golden" {
    const expected = try digestFromHex(
        "69a4b418e4622d005a1b83812f73bbd2" ++
            "bf3d4e084796893dcfc43936b165781a",
    );
    try std.testing.expectEqual(
        expected,
        contractRootV1(&.{ 0x00, 0x01, 0xfe, 0xff }),
    );
}

test "terminal source recovery wire matches independent layout golden" {
    const fixture = try TestFixture.init();
    const input = fixture.input();
    const derived = try validateInputV1(input);
    try std.testing.expectEqual(
        @as(usize, 644),
        try encodedBytesV1(fixture.prompt.len),
    );

    var storage: [644]u8 = undefined;
    const encoded = try encodeV1(input, &storage);
    var expected_body = [_]u8{0} ** 612;
    @memcpy(expected_body[0..8], "GPTTRM01");
    goldenWriteU64(&expected_body, 8, 0x4750_5454_0000_0001);
    goldenWriteU64(&expected_body, 16, 644);
    goldenWriteU64(&expected_body, 24, 0);
    goldenWriteU64(&expected_body, 32, 128);
    goldenWriteU64(&expected_body, 40, 472);
    goldenWriteU64(&expected_body, 48, 3);
    goldenWriteU64(&expected_body, 56, 12);
    goldenWriteU64(
        &expected_body,
        128,
        input.options.max_new_tokens,
    );
    goldenWriteU64(
        &expected_body,
        136,
        input.options.eos_token,
    );
    goldenWriteU64(
        &expected_body,
        144,
        input.options.seed,
    );
    goldenWriteU64(
        &expected_body,
        152,
        input.scheduling.tenant_key,
    );
    goldenWriteU64(
        &expected_body,
        160,
        input.scheduling.request_key,
    );
    goldenWriteU64(
        &expected_body,
        168,
        input.scheduling.request_generation,
    );
    goldenWriteU64(
        &expected_body,
        176,
        input.scheduling.resource_owner_key,
    );
    goldenWriteU64(
        &expected_body,
        184,
        input.scheduling.weight,
    );
    goldenWriteU64(
        &expected_body,
        192,
        input.scheduling.deadline_tick,
    );
    goldenWriteU64(
        &expected_body,
        200,
        input.bound_plan_input.request_epoch,
    );
    goldenWriteDigest(
        &expected_body,
        208,
        input.bound_plan_input.token_domain_sha256,
    );
    goldenWriteDigest(
        &expected_body,
        240,
        input.bound_plan_input
            .token_domain_config_sha256,
    );
    goldenWriteDigest(
        &expected_body,
        272,
        input.bound_plan_input.artifact_license_sha256,
    );
    goldenWriteDigest(
        &expected_body,
        304,
        input.bound_plan_input.previous_plan_sha256,
    );
    goldenWriteU64(
        &expected_body,
        336,
        input.source_runtime.scheduler_epoch,
    );
    goldenWriteU64(
        &expected_body,
        344,
        input.source_runtime.coordinator_id,
    );
    goldenWriteU64(
        &expected_body,
        352,
        input.source_runtime.bank_epoch,
    );
    goldenWriteU64(
        &expected_body,
        360,
        input.request_epoch,
    );
    goldenWriteU64(
        &expected_body,
        368,
        input.publication_next_sequence,
    );
    goldenWriteDigest(
        &expected_body,
        376,
        input.challenge_sha256,
    );
    goldenWriteDigest(
        &expected_body,
        408,
        derived.plan_sha256,
    );
    goldenWriteDigest(
        &expected_body,
        440,
        derived.bound_plan_sha256,
    );
    goldenWriteDigest(
        &expected_body,
        472,
        derived.prompt_sha256,
    );
    goldenWriteDigest(
        &expected_body,
        504,
        derived.artifact_sha256,
    );
    goldenWriteDigest(
        &expected_body,
        536,
        derived.execution_plan_sha256,
    );
    goldenWriteDigest(
        &expected_body,
        568,
        derived.residency_binding_sha256,
    );
    for (fixture.prompt, 0..) |token, index|
        goldenWriteU32(
            &expected_body,
            600 + index * @sizeOf(u32),
            token,
        );

    try std.testing.expectEqualSlices(
        u8,
        &expected_body,
        encoded.bytes[0..expected_body.len],
    );
    var independent_hash =
        std.crypto.hash.sha2.Sha256.init(.{});
    independent_hash.update(
        "glacier-prepared-text-terminal-source-recovery-contract-v1\x00",
    );
    independent_hash.update(&expected_body);
    var expected_footer: Digest = undefined;
    independent_hash.final(&expected_footer);
    try std.testing.expectEqualSlices(
        u8,
        &expected_footer,
        encoded.bytes[expected_body.len..],
    );
}

test "terminal source recovery is canonical and context bound" {
    const fixture = try TestFixture.init();
    var first: [644]u8 = undefined;
    var second: [644]u8 = undefined;
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
    try std.testing.expectError(
        Error.InvalidPrompt,
        decoded.promptToken(fixture.prompt.len),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        decoded.options.max_new_tokens,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        decoded.publication_next_sequence,
    );
    try std.testing.expectEqual(
        fixture.input_value.plan.plan_sha256,
        decoded.plan_sha256,
    );
    try std.testing.expectEqual(
        fixture.input_value.bound_plan.bound_plan_sha256,
        decoded.bound_plan_sha256,
    );
}

test "terminal source recovery rejects every single-bit mutation" {
    const fixture = try TestFixture.init();
    var canonical: [644]u8 = undefined;
    const encoded = try encodeV1(
        fixture.input(),
        &canonical,
    );
    var mutated: [644]u8 = undefined;
    for (0..encoded.bytes.len) |index| {
        for (0..8) |bit| {
            @memcpy(&mutated, encoded.bytes);
            mutated[index] ^=
                @as(u8, 1) << @intCast(bit);
            try std.testing.expectError(
                Error.InvalidContract,
                decodeV1(&mutated),
            );
        }
    }
}

test "terminal source recovery rejects coherent shape and context drift" {
    const fixture = try TestFixture.init();
    var canonical: [644]u8 = undefined;
    const encoded = try encodeV1(
        fixture.input(),
        &canonical,
    );

    var foreign_runtime = canonical;
    const coordinator = std.mem.readInt(
        u64,
        foreign_runtime[source_runtime_offset + 8 ..][0..8],
        .little,
    );
    std.mem.writeInt(
        u64,
        foreign_runtime[source_runtime_offset + 8 ..][0..8],
        coordinator + 1,
        .little,
    );
    rerootTestWireV1(&foreign_runtime);
    const foreign_decoded = try decodeV1(&foreign_runtime);
    try std.testing.expectError(
        Error.InvalidContext,
        verifyContextV1(
            foreign_decoded,
            fixture.input(),
        ),
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

    var wrong_maximum = canonical;
    goldenWriteU64(&wrong_maximum, options_offset, 2);
    rerootTestWireV1(&wrong_maximum);
    try std.testing.expectError(
        Error.InvalidContract,
        decodeV1(&wrong_maximum),
    );

    var wrong_sequence = canonical;
    goldenWriteU64(
        &wrong_sequence,
        request_offset + 8,
        2,
    );
    rerootTestWireV1(&wrong_sequence);
    try std.testing.expectError(
        Error.InvalidContract,
        decodeV1(&wrong_sequence),
    );

    var zero_plan = canonical;
    @memset(
        zero_plan[plan_bindings_offset .. plan_bindings_offset + @sizeOf(Digest)],
        0,
    );
    rerootTestWireV1(&zero_plan);
    try std.testing.expectError(
        Error.InvalidContract,
        decodeV1(&zero_plan),
    );

    var foreign_plan = canonical;
    foreign_plan[plan_bindings_offset] ^= 0x80;
    rerootTestWireV1(&foreign_plan);
    const foreign_plan_decoded =
        try decodeV1(&foreign_plan);
    try std.testing.expectError(
        Error.InvalidContext,
        verifyContextV1(
            foreign_plan_decoded,
            fixture.input(),
        ),
    );
}

test "terminal source recovery rejects invalid and overlapping inputs" {
    const fixture = try TestFixture.init();
    var storage = [_]u8{0xa5} ** 644;

    var wrong_maximum = fixture.input();
    wrong_maximum.options.max_new_tokens = 2;
    try std.testing.expectError(
        Error.InvalidContext,
        encodeV1(wrong_maximum, &storage),
    );
    var zero_sequence = fixture.input();
    zero_sequence.publication_next_sequence = 0;
    try std.testing.expectError(
        Error.InvalidContext,
        encodeV1(zero_sequence, &storage),
    );
    var advanced_sequence = fixture.input();
    advanced_sequence.publication_next_sequence = 2;
    try std.testing.expectError(
        Error.InvalidContext,
        encodeV1(advanced_sequence, &storage),
    );
    var zero_runtime = fixture.input();
    zero_runtime.source_runtime.bank_epoch = 0;
    try std.testing.expectError(
        Error.InvalidSourceRuntime,
        encodeV1(zero_runtime, &storage),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &storage, 0xa5),
    );

    var wrong_plan = fixture.input();
    wrong_plan.plan.max_new_tokens = 2;
    try std.testing.expectError(
        Error.InvalidPlan,
        encodeV1(wrong_plan, &storage),
    );
    var overflowing_claim = fixture.input();
    overflowing_claim.plan.claim.capsule_bytes =
        std.math.maxInt(u64);
    try std.testing.expectError(
        Error.InvalidPlan,
        encodeV1(overflowing_claim, &storage),
    );
    var wrong_bound_plan = fixture.input();
    wrong_bound_plan.bound_plan.execution
        .publication_next_sequence = 1;
    try std.testing.expectError(
        Error.InvalidBoundPlan,
        encodeV1(wrong_bound_plan, &storage),
    );

    var short_storage = [_]u8{0x6c} ** 643;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeV1(fixture.input(), &short_storage),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &short_storage, 0x6c),
    );

    var overlap_storage: [644]u8 align(@alignOf(u32)) =
        [_]u8{0x5a} ** 644;
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

fn goldenWriteU32(
    bytes: []u8,
    offset: usize,
    value: u32,
) void {
    std.mem.writeInt(
        u32,
        bytes[offset..][0..4],
        value,
        .little,
    );
}

fn goldenWriteU64(
    bytes: []u8,
    offset: usize,
    value: anytype,
) void {
    std.mem.writeInt(
        u64,
        bytes[offset..][0..8],
        @intCast(value),
        .little,
    );
}

fn goldenWriteDigest(
    bytes: []u8,
    offset: usize,
    value: Digest,
) void {
    @memcpy(bytes[offset..][0..32], &value);
}

fn rerootTestWireV1(bytes: []u8) void {
    const body = bytes[0 .. bytes.len - footer_bytes];
    const root = contractRootV1(body);
    @memcpy(bytes[body.len..], &root);
}
