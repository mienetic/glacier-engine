//! Canonical trusted context for a prepared-text fresh-process restart.
//!
//! This pointer-free manifest carries prompt token IDs, local plan identity,
//! complete bound Model Contract records, checkpoint expectations, source
//! publication evidence, and target ownership intent. The source execution and
//! residency values are encoded once inside `BoundPlanV1`; decoding reconstructs
//! `SourceContextV1` from those canonical records instead of admitting
//! contradictory duplicate structs.
//!
//! The manifest is evidence only. It creates no live source Session, Scheduler,
//! ResourceBank, receipt authority, permit, or restored target Session.

const std = @import("std");
const core = @import("core");
const model_contract = core.model_contract;
const resource_bank = core.resource_bank;
const runtime_image = @import("model/runtime_image.zig");
const publication = @import("lane_publication_txn.zig");
const lane_contiguous = @import("lane_contiguous_publication.zig");
const session = @import("prepared_text_session.zig");
const checkpoint = @import("prepared_text_checkpoint.zig");
const successor = @import("prepared_text_successor.zig");

pub const Digest = [32]u8;
pub const manifest_abi: u64 = 0x474c_5458_0000_0001;
pub const manifest_magic = [_]u8{
    'G', 'L', 'T', 'R', 'S', 'T', '0', '1',
};
pub const allowed_flags: u64 = 0;
pub const header_bytes: usize = 96;
pub const footer_bytes: usize = 32;
pub const claim_wire_bytes: usize = 80;
pub const options_wire_bytes: usize = 24;
pub const plan_wire_bytes: usize = 288;
pub const bound_plan_wrapper_bytes: usize = 168;
pub const expected_bindings_wire_bytes: usize = 376;
pub const source_context_wire_bytes: usize = 448;
pub const target_ownership_wire_bytes: usize = 176;
pub const fixed_payload_bytes: usize =
    options_wire_bytes +
    plan_wire_bytes +
    bound_plan_wrapper_bytes +
    model_contract.artifact_manifest_bytes +
    model_contract.execution_plan_bytes +
    model_contract.execution_residency_binding_bytes +
    expected_bindings_wire_bytes +
    source_context_wire_bytes +
    target_ownership_wire_bytes;
pub const minimum_encoded_bytes: usize =
    header_bytes + fixed_payload_bytes + footer_bytes;

const options_offset: usize = header_bytes;
const plan_offset: usize = options_offset + options_wire_bytes;
const bound_plan_offset: usize = plan_offset + plan_wire_bytes;
const artifact_offset: usize =
    bound_plan_offset + bound_plan_wrapper_bytes;
const execution_offset: usize =
    artifact_offset + model_contract.artifact_manifest_bytes;
const residency_offset: usize =
    execution_offset + model_contract.execution_plan_bytes;
const expected_bindings_offset: usize =
    residency_offset +
    model_contract.execution_residency_binding_bytes;
const source_context_offset: usize =
    expected_bindings_offset + expected_bindings_wire_bytes;
const target_ownership_offset: usize =
    source_context_offset + source_context_wire_bytes;
const prompt_offset: usize =
    target_ownership_offset + target_ownership_wire_bytes;

comptime {
    if (claim_wire_bytes != 10 * @sizeOf(u64))
        @compileError("restart manifest claim layout drift");
    if (prompt_offset != header_bytes + fixed_payload_bytes)
        @compileError("restart manifest payload layout drift");
}

const manifest_domain =
    "glacier-prepared-text-restart-manifest-v1\x00";
const prompt_domain = "glacier-prepared-text-prompt-v1\x00";
const plan_domain = "glacier-prepared-text-plan-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidBoundPlan,
    InvalidEncoding,
    InvalidExpectedBindings,
    InvalidManifest,
    InvalidOptions,
    InvalidPlan,
    InvalidPrompt,
    InvalidSourceContext,
    InvalidTargetOwnership,
    UnsafeDestination,
};

pub const InputV1 = struct {
    prompt: []const u32,
    options: session.OptionsV1,
    plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
};

pub const EncodedV1 = struct {
    bytes: []const u8,
    manifest_sha256: Digest,
};

/// Zero-copy view. `canonical_prompt_u32_le` borrows `encoded`; use
/// `promptToken` for alignment-independent typed access.
pub const DecodedV1 = struct {
    encoded: []const u8,
    canonical_prompt_u32_le: []const u8,
    options: session.OptionsV1,
    plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
    manifest_sha256: Digest,

    pub fn promptToken(
        self: *const DecodedV1,
        index: usize,
    ) Error!u32 {
        const count = self.canonical_prompt_u32_le.len / 4;
        if (index >= count) return Error.InvalidPrompt;
        const offset = index * 4;
        return std.mem.readInt(
            u32,
            self.canonical_prompt_u32_le[offset..][0..4],
            .little,
        );
    }

    pub fn promptCount(self: *const DecodedV1) usize {
        return self.canonical_prompt_u32_le.len / 4;
    }
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

/// Validate and canonicalize every input into private fixed-size records
/// before publishing any destination byte.
pub fn encodeV1(
    input: InputV1,
    destination: []u8,
) Error!EncodedV1 {
    const prompt_sha256 = promptRootFromTokensV1(input.prompt);
    try validatePromptTokensV1(
        input.prompt,
        input.expected_checkpoint.vocab_size,
    );
    try validateContextV1(
        input.prompt.len,
        prompt_sha256,
        input.options,
        input.plan,
        input.bound_plan,
        input.expected_checkpoint,
        input.source,
        input.target,
    );

    var artifact_wire: [model_contract.artifact_manifest_bytes]u8 = undefined;
    model_contract.encodeArtifactManifestV1(
        input.bound_plan.artifact,
        &artifact_wire,
    ) catch return Error.InvalidBoundPlan;
    var execution_wire: [model_contract.execution_plan_bytes]u8 = undefined;
    model_contract.encodeExecutionPlanV1(
        input.bound_plan.execution,
        &execution_wire,
    ) catch return Error.InvalidBoundPlan;
    var residency_wire: [model_contract.execution_residency_binding_bytes]u8 =
        undefined;
    model_contract.encodeExecutionResidencyBindingV1(
        input.bound_plan.residency,
        &residency_wire,
    ) catch return Error.InvalidBoundPlan;

    const required = try encodedBytesV1(input.prompt.len);
    if (destination.len < required) return Error.BufferTooSmall;
    const output = destination[0..required];
    if (slicesOverlap(
        output,
        std.mem.sliceAsBytes(input.prompt),
    )) return Error.UnsafeDestination;

    @memset(output, 0);
    const body = output[0 .. output.len - footer_bytes];
    var writer: Writer = .{ .bytes = body };
    writer.writeBytes(&manifest_magic);
    writer.writeU64(manifest_abi);
    writer.writeU64(@intCast(output.len));
    writer.writeU64(allowed_flags);
    writer.writeU64(header_bytes);
    writer.writeU64(fixed_payload_bytes);
    writer.writeU64(@intCast(input.prompt.len));
    writer.writeU64(@intCast(input.prompt.len * @sizeOf(u32)));
    writer.writeU64(model_contract.artifact_manifest_bytes);
    writer.writeU64(model_contract.execution_plan_bytes);
    writer.writeU64(
        model_contract.execution_residency_binding_bytes,
    );
    writer.writeU64(0);
    std.debug.assert(writer.position == options_offset);

    writeOptionsV1(&writer, input.options);
    std.debug.assert(writer.position == plan_offset);
    writePlanV1(&writer, input.plan);
    std.debug.assert(writer.position == bound_plan_offset);
    writeBoundPlanWrapperV1(&writer, input.bound_plan);
    std.debug.assert(writer.position == artifact_offset);
    writer.writeBytes(&artifact_wire);
    std.debug.assert(writer.position == execution_offset);
    writer.writeBytes(&execution_wire);
    std.debug.assert(writer.position == residency_offset);
    writer.writeBytes(&residency_wire);
    std.debug.assert(writer.position == expected_bindings_offset);
    writeExpectedBindingsV1(
        &writer,
        input.expected_checkpoint,
    );
    std.debug.assert(writer.position == source_context_offset);
    writeSourceContextV1(&writer, input.source);
    std.debug.assert(writer.position == target_ownership_offset);
    writeTargetOwnershipV1(&writer, input.target);
    std.debug.assert(writer.position == prompt_offset);
    for (input.prompt) |token| writer.writeU32(token);
    std.debug.assert(writer.position == body.len);

    const manifest_sha256 = manifestRootV1(body);
    @memcpy(output[body.len..], &manifest_sha256);
    return .{
        .bytes = output,
        .manifest_sha256 = manifest_sha256,
    };
}

pub fn decodeV1(encoded: []const u8) Error!DecodedV1 {
    if (encoded.len < minimum_encoded_bytes)
        return Error.InvalidEncoding;
    const body = encoded[0 .. encoded.len - footer_bytes];
    const committed_sha256: Digest =
        encoded[encoded.len - footer_bytes ..][0..footer_bytes].*;
    const manifest_sha256 = manifestRootV1(body);
    if (!digestEqual(committed_sha256, manifest_sha256))
        return Error.InvalidManifest;

    var reader: Reader = .{ .bytes = body };
    if (!std.mem.eql(
        u8,
        try reader.readBytes(manifest_magic.len),
        &manifest_magic,
    ) or
        try reader.readU64() != manifest_abi or
        try reader.readU64() != encoded.len or
        try reader.readU64() != allowed_flags or
        try reader.readU64() != header_bytes or
        try reader.readU64() != fixed_payload_bytes)
        return Error.InvalidEncoding;
    const prompt_count_u64 = try reader.readU64();
    const prompt_bytes_u64 = try reader.readU64();
    if (try reader.readU64() !=
        model_contract.artifact_manifest_bytes or
        try reader.readU64() !=
            model_contract.execution_plan_bytes or
        try reader.readU64() !=
            model_contract.execution_residency_binding_bytes or
        try reader.readU64() != 0)
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
        try encodedBytesV1(prompt_count) != encoded.len or
        reader.position != options_offset)
        return Error.InvalidEncoding;

    const options = try readOptionsV1(&reader);
    if (reader.position != plan_offset)
        return Error.InvalidEncoding;
    const plan = try readPlanV1(&reader);
    if (reader.position != bound_plan_offset)
        return Error.InvalidEncoding;
    const bound_wrapper =
        try readBoundPlanWrapperV1(&reader);
    if (reader.position != artifact_offset)
        return Error.InvalidEncoding;
    const artifact = model_contract.decodeArtifactManifestV1(
        try reader.readBytes(
            model_contract.artifact_manifest_bytes,
        ),
    ) catch return Error.InvalidBoundPlan;
    if (reader.position != execution_offset)
        return Error.InvalidEncoding;
    const execution = model_contract.decodeExecutionPlanV1(
        try reader.readBytes(
            model_contract.execution_plan_bytes,
        ),
    ) catch return Error.InvalidBoundPlan;
    if (reader.position != residency_offset)
        return Error.InvalidEncoding;
    const residency =
        model_contract.decodeExecutionResidencyBindingV1(
            try reader.readBytes(
                model_contract
                    .execution_residency_binding_bytes,
            ),
        ) catch return Error.InvalidBoundPlan;
    const bound_plan: session.BoundPlanV1 = .{
        .abi_version = bound_wrapper.abi_version,
        .local_plan_sha256 = bound_wrapper.local_plan_sha256,
        .artifact = artifact,
        .execution = execution,
        .residency = residency,
        .token_domain_sha256 = bound_wrapper.token_domain_sha256,
        .token_domain_config_sha256 = bound_wrapper.token_domain_config_sha256,
        .artifact_license_sha256 = bound_wrapper.artifact_license_sha256,
        .bound_plan_sha256 = bound_wrapper.bound_plan_sha256,
    };

    if (reader.position != expected_bindings_offset)
        return Error.InvalidEncoding;
    const expected_checkpoint =
        try readExpectedBindingsV1(&reader);
    if (reader.position != source_context_offset)
        return Error.InvalidEncoding;
    const source_wrapper = try readSourceContextV1(&reader);
    const source: successor.SourceContextV1 = .{
        .bound_plan_sha256 = source_wrapper.bound_plan_sha256,
        .execution = bound_plan.execution,
        .residency = bound_plan.residency,
        .boundary_sha256 = source_wrapper.boundary_sha256,
        .publication = source_wrapper.publication,
        .receipt = source_wrapper.receipt,
    };
    if (reader.position != target_ownership_offset)
        return Error.InvalidEncoding;
    const target = try readTargetOwnershipV1(&reader);
    if (reader.position != prompt_offset)
        return Error.InvalidEncoding;
    const canonical_prompt_u32_le =
        try reader.readBytes(prompt_bytes);
    if (reader.position != body.len)
        return Error.InvalidEncoding;

    const prompt_sha256 = promptRootFromWireV1(
        prompt_count_u64,
        canonical_prompt_u32_le,
    );
    try validatePromptWireV1(
        canonical_prompt_u32_le,
        expected_checkpoint.vocab_size,
    );
    try validateContextV1(
        prompt_count,
        prompt_sha256,
        options,
        plan,
        bound_plan,
        expected_checkpoint,
        source,
        target,
    );

    return .{
        .encoded = encoded,
        .canonical_prompt_u32_le = canonical_prompt_u32_le,
        .options = options,
        .plan = plan,
        .bound_plan = bound_plan,
        .expected_checkpoint = expected_checkpoint,
        .source = source,
        .target = target,
        .manifest_sha256 = manifest_sha256,
    };
}

pub fn manifestRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(manifest_domain);
    hash.update(body);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

const BoundPlanWrapperV1 = struct {
    abi_version: u64,
    local_plan_sha256: Digest,
    token_domain_sha256: Digest,
    token_domain_config_sha256: Digest,
    artifact_license_sha256: Digest,
    bound_plan_sha256: Digest,
};

const SourceContextWrapperV1 = struct {
    bound_plan_sha256: Digest,
    boundary_sha256: Digest,
    publication: publication.TranscriptSnapshotV1,
    receipt: resource_bank.Receipt,
};

fn validateContextV1(
    prompt_count: usize,
    prompt_sha256: Digest,
    options: session.OptionsV1,
    plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
    expected: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
) Error!void {
    const prompt_count_u64 = std.math.cast(
        u64,
        prompt_count,
    ) orelse return Error.InvalidPrompt;
    const option_max_new_tokens = std.math.cast(
        u64,
        options.max_new_tokens,
    ) orelse return Error.InvalidOptions;
    if (prompt_count == 0 or
        options.max_new_tokens == 0 or
        plan.abi_version != session.plan_abi or
        plan.prompt_tokens != prompt_count_u64 or
        !digestEqual(plan.prompt_sha256, prompt_sha256) or
        plan.max_new_tokens != option_max_new_tokens or
        plan.eos_token != options.eos_token or
        plan.seed != options.seed or
        plan.image_identity.container_bytes == 0 or
        isZero(plan.image_identity.source_fingerprint) or
        isZero(plan.image_identity.abi_fingerprint) or
        isZero(plan.image_identity.container_sha256) or
        !digestEqual(plan.plan_sha256, planRootV1(plan)))
        return Error.InvalidPlan;
    _ = plan.claim.hostBytes() catch
        return Error.InvalidPlan;

    session.validateBoundPlanV1(bound_plan) catch
        return Error.InvalidBoundPlan;
    if (!digestEqual(
        bound_plan.local_plan_sha256,
        plan.plan_sha256,
    ) or
        bound_plan.artifact.input_features != plan.prompt_tokens or
        bound_plan.artifact.output_dimensions !=
            plan.max_new_tokens or
        bound_plan.artifact.weight_bytes !=
            plan.image_identity.container_bytes or
        !digestEqual(
            bound_plan.artifact.weights_sha256,
            plan.image_identity.container_sha256,
        ) or
        bound_plan.execution.input_features !=
            plan.prompt_tokens or
        bound_plan.execution.output_dimensions !=
            plan.max_new_tokens or
        !digestEqual(
            bound_plan.execution.media_object_sha256,
            plan.prompt_sha256,
        ) or
        bound_plan.residency.resident_weight_bytes !=
            plan.image_identity.container_bytes or
        !std.meta.eql(
            bound_plan.residency.request_claim,
            plan.claim,
        ))
        return Error.InvalidBoundPlan;

    try validateExpectedBindingsV1(
        expected,
        plan,
        bound_plan,
        source,
    );
    try validateSourceContextV1(
        expected,
        plan,
        bound_plan,
        source,
    );
    try validateTargetOwnershipV1(
        bound_plan,
        source,
        target,
    );
}

fn validateExpectedBindingsV1(
    expected: checkpoint.ExpectedBindingsV1,
    plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
    source: successor.SourceContextV1,
) Error!void {
    if (expected.request_epoch == 0 or
        expected.publication_next_sequence == 0 or
        expected.prompt_tokens == 0 or
        expected.max_new_tokens == 0 or
        expected.vocab_size < 2 or
        expected.vocab_size >
            @as(u64, std.math.maxInt(u32)) + 1 or
        expected.num_layers == 0 or
        expected.kv_dim == 0 or
        expected.output_count == 0 or
        expected.output_count >= expected.max_new_tokens or
        expected.publication_next_sequence !=
            expected.output_count or
        expected.sampling_calls != expected.output_count or
        expected.prompt_tokens != plan.prompt_tokens or
        expected.max_new_tokens != plan.max_new_tokens or
        @as(u64, plan.eos_token) < expected.vocab_size or
        !digestEqual(
            expected.local_plan_sha256,
            plan.plan_sha256,
        ) or
        !digestEqual(
            expected.bound_plan_sha256,
            bound_plan.bound_plan_sha256,
        ) or
        !digestEqual(
            expected.artifact_sha256,
            bound_plan.artifact.artifact_sha256,
        ) or
        !digestEqual(
            expected.execution_plan_sha256,
            bound_plan.execution.plan_sha256,
        ) or
        !digestEqual(
            expected.residency_binding_sha256,
            bound_plan.residency.binding_sha256,
        ) or
        !digestEqual(
            expected.boundary_sha256,
            source.boundary_sha256,
        ) or
        !digestEqual(
            expected.transcript_sha256,
            source.publication.transcript_sha256,
        ) or
        !digestEqual(
            expected.state_commitment_sha256,
            source.publication.state.commitment_sha256,
        ) or
        isZero(expected.challenge_sha256))
        return Error.InvalidExpectedBindings;

    const expected_kv_positions = std.math.add(
        u64,
        expected.prompt_tokens,
        expected.output_count - 1,
    ) catch return Error.InvalidExpectedBindings;
    const expected_max_kv_positions = std.math.add(
        u64,
        expected.prompt_tokens,
        expected.max_new_tokens - 1,
    ) catch return Error.InvalidExpectedBindings;
    const expected_vocab_size = std.math.add(
        u64,
        bound_plan.execution.maximum_absolute_output,
        1,
    ) catch return Error.InvalidExpectedBindings;
    if (expected.kv_positions != expected_kv_positions or
        expected.max_kv_positions !=
            expected_max_kv_positions or
        expected.kv_positions > expected.max_kv_positions or
        expected.vocab_size != expected_vocab_size)
        return Error.InvalidExpectedBindings;

    const layer_sides = std.math.mul(
        u64,
        expected.num_layers,
        2,
    ) catch return Error.InvalidExpectedBindings;
    const positioned_sides = std.math.mul(
        u64,
        layer_sides,
        expected.kv_positions,
    ) catch return Error.InvalidExpectedBindings;
    _ = std.math.mul(
        u64,
        positioned_sides,
        expected.kv_dim,
    ) catch return Error.InvalidExpectedBindings;
}

fn validateSourceContextV1(
    expected: checkpoint.ExpectedBindingsV1,
    plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
    source: successor.SourceContextV1,
) Error!void {
    if (!resource_bank.receiptIntegrityValidV1(source.receipt) or
        !publication.transcriptSnapshotValidV1(
            source.publication,
        ) or
        source.publication.terminal or
        source.publication.execution_abi !=
            lane_contiguous.abi or
        source.publication.state.execution_abi !=
            lane_contiguous.abi or
        source.publication.state.rng_state_abi !=
            lane_contiguous.rng_state_abi or
        source.publication.request_epoch !=
            expected.request_epoch or
        source.publication.sequence_base !=
            bound_plan.execution.publication_next_sequence or
        source.publication.next_sequence !=
            expected.publication_next_sequence or
        source.publication.state.kv_position !=
            expected.kv_positions or
        source.publication.state.output_length !=
            expected.output_count or
        source.publication.state.sampling_calls !=
            expected.sampling_calls or
        source.publication.last_resource_permit_generation == 0 or
        bound_plan.execution.request_epoch !=
            expected.request_epoch or
        bound_plan.execution.publication_next_sequence >=
            expected.publication_next_sequence or
        !digestEqual(
            source.bound_plan_sha256,
            bound_plan.bound_plan_sha256,
        ) or
        !std.meta.eql(
            source.execution,
            bound_plan.execution,
        ) or
        !std.meta.eql(
            source.residency,
            bound_plan.residency,
        ) or
        !std.meta.eql(source.receipt.claim, plan.claim))
        return Error.InvalidSourceContext;
    _ = source.receipt.claim.hostBytes() catch
        return Error.InvalidSourceContext;
}

fn validateTargetOwnershipV1(
    bound_plan: session.BoundPlanV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
) Error!void {
    const successor_generation = std.math.add(
        u64,
        bound_plan.execution.generation,
        1,
    ) catch return Error.InvalidTargetOwnership;
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
        target.bank_epoch == source.receipt.bank_epoch or
        target.resource_owner_key == source.receipt.owner_key or
        target.request_generation != successor_generation or
        target.intent_generation != successor_generation or
        !std.meta.eql(
            target.request_claim,
            bound_plan.residency.request_claim,
        ))
        return Error.InvalidTargetOwnership;
    _ = target.request_claim.hostBytes() catch
        return Error.InvalidTargetOwnership;
}

fn writeOptionsV1(
    writer: *Writer,
    options: session.OptionsV1,
) void {
    writer.writeU64(@intCast(options.max_new_tokens));
    writer.writeU32(options.eos_token);
    writer.writeU32(0);
    writer.writeU64(options.seed);
}

fn readOptionsV1(reader: *Reader) Error!session.OptionsV1 {
    const max_new_tokens_u64 = try reader.readU64();
    const eos_token = try reader.readU32();
    if (try reader.readU32() != 0)
        return Error.InvalidEncoding;
    const max_new_tokens = std.math.cast(
        usize,
        max_new_tokens_u64,
    ) orelse return Error.InvalidOptions;
    return .{
        .max_new_tokens = max_new_tokens,
        .eos_token = eos_token,
        .seed = try reader.readU64(),
    };
}

fn writePlanV1(writer: *Writer, plan: session.PlanV1) void {
    writer.writeU64(plan.abi_version);
    writeImageIdentityV1(writer, plan.image_identity);
    writer.writeU64(plan.prompt_tokens);
    writer.writeDigest(plan.prompt_sha256);
    writer.writeU64(plan.max_new_tokens);
    writer.writeU32(plan.eos_token);
    writer.writeU32(0);
    writer.writeU64(plan.seed);
    writeClaimV1(writer, plan.claim);
    writer.writeDigest(plan.plan_sha256);
}

fn readPlanV1(reader: *Reader) Error!session.PlanV1 {
    const abi_version = try reader.readU64();
    const image_identity = try readImageIdentityV1(reader);
    const prompt_tokens = try reader.readU64();
    const prompt_sha256 = try reader.readDigest();
    const max_new_tokens = try reader.readU64();
    const eos_token = try reader.readU32();
    if (try reader.readU32() != 0)
        return Error.InvalidEncoding;
    return .{
        .abi_version = abi_version,
        .image_identity = image_identity,
        .prompt_tokens = prompt_tokens,
        .prompt_sha256 = prompt_sha256,
        .max_new_tokens = max_new_tokens,
        .eos_token = eos_token,
        .seed = try reader.readU64(),
        .claim = try readClaimV1(reader),
        .plan_sha256 = try reader.readDigest(),
    };
}

fn writeImageIdentityV1(
    writer: *Writer,
    identity: runtime_image.ImageIdentityV1,
) void {
    writer.writeDigest(identity.source_fingerprint);
    writer.writeDigest(identity.abi_fingerprint);
    writer.writeU64(identity.container_bytes);
    writer.writeDigest(identity.container_sha256);
}

fn readImageIdentityV1(
    reader: *Reader,
) Error!runtime_image.ImageIdentityV1 {
    return .{
        .source_fingerprint = try reader.readDigest(),
        .abi_fingerprint = try reader.readDigest(),
        .container_bytes = try reader.readU64(),
        .container_sha256 = try reader.readDigest(),
    };
}

fn writeBoundPlanWrapperV1(
    writer: *Writer,
    value: session.BoundPlanV1,
) void {
    writer.writeU64(value.abi_version);
    writer.writeDigest(value.local_plan_sha256);
    writer.writeDigest(value.token_domain_sha256);
    writer.writeDigest(value.token_domain_config_sha256);
    writer.writeDigest(value.artifact_license_sha256);
    writer.writeDigest(value.bound_plan_sha256);
}

fn readBoundPlanWrapperV1(
    reader: *Reader,
) Error!BoundPlanWrapperV1 {
    return .{
        .abi_version = try reader.readU64(),
        .local_plan_sha256 = try reader.readDigest(),
        .token_domain_sha256 = try reader.readDigest(),
        .token_domain_config_sha256 = try reader.readDigest(),
        .artifact_license_sha256 = try reader.readDigest(),
        .bound_plan_sha256 = try reader.readDigest(),
    };
}

fn writeExpectedBindingsV1(
    writer: *Writer,
    value: checkpoint.ExpectedBindingsV1,
) void {
    writer.writeDigest(value.local_plan_sha256);
    writer.writeDigest(value.bound_plan_sha256);
    writer.writeDigest(value.artifact_sha256);
    writer.writeDigest(value.execution_plan_sha256);
    writer.writeDigest(value.residency_binding_sha256);
    writer.writeDigest(value.boundary_sha256);
    writer.writeDigest(value.transcript_sha256);
    writer.writeDigest(value.state_commitment_sha256);
    writer.writeU64(value.request_epoch);
    writer.writeU64(value.publication_next_sequence);
    writer.writeU64(value.prompt_tokens);
    writer.writeU64(value.max_new_tokens);
    writer.writeU64(value.vocab_size);
    writer.writeU64(value.num_layers);
    writer.writeU64(value.kv_dim);
    writer.writeU64(value.max_kv_positions);
    writer.writeU64(value.kv_positions);
    writer.writeU64(value.output_count);
    writer.writeU64(value.sampling_calls);
    writer.writeDigest(value.challenge_sha256);
}

fn readExpectedBindingsV1(
    reader: *Reader,
) Error!checkpoint.ExpectedBindingsV1 {
    return .{
        .local_plan_sha256 = try reader.readDigest(),
        .bound_plan_sha256 = try reader.readDigest(),
        .artifact_sha256 = try reader.readDigest(),
        .execution_plan_sha256 = try reader.readDigest(),
        .residency_binding_sha256 = try reader.readDigest(),
        .boundary_sha256 = try reader.readDigest(),
        .transcript_sha256 = try reader.readDigest(),
        .state_commitment_sha256 = try reader.readDigest(),
        .request_epoch = try reader.readU64(),
        .publication_next_sequence = try reader.readU64(),
        .prompt_tokens = try reader.readU64(),
        .max_new_tokens = try reader.readU64(),
        .vocab_size = try reader.readU64(),
        .num_layers = try reader.readU64(),
        .kv_dim = try reader.readU64(),
        .max_kv_positions = try reader.readU64(),
        .kv_positions = try reader.readU64(),
        .output_count = try reader.readU64(),
        .sampling_calls = try reader.readU64(),
        .challenge_sha256 = try reader.readDigest(),
    };
}

fn writeSourceContextV1(
    writer: *Writer,
    source: successor.SourceContextV1,
) void {
    writer.writeDigest(source.bound_plan_sha256);
    writer.writeDigest(source.boundary_sha256);
    writeTranscriptSnapshotV1(writer, source.publication);
    writeReceiptV1(writer, source.receipt);
}

fn readSourceContextV1(
    reader: *Reader,
) Error!SourceContextWrapperV1 {
    return .{
        .bound_plan_sha256 = try reader.readDigest(),
        .boundary_sha256 = try reader.readDigest(),
        .publication = try readTranscriptSnapshotV1(
            reader,
        ),
        .receipt = try readReceiptV1(reader),
    };
}

fn writeTranscriptSnapshotV1(
    writer: *Writer,
    value: publication.TranscriptSnapshotV1,
) void {
    writer.writeU64(value.abi_version);
    writer.writeU64(value.request_epoch);
    writer.writeU64(value.execution_abi);
    writer.writeU64(value.sequence_base);
    writer.writeU64(value.next_sequence);
    writer.writeU64(value.last_resource_permit_generation);
    writer.writeU64(@intFromBool(value.terminal));
    writeStateCommitmentV1(writer, value.state);
    writer.writeDigest(value.transcript_sha256);
}

fn readTranscriptSnapshotV1(
    reader: *Reader,
) Error!publication.TranscriptSnapshotV1 {
    const abi_version = try reader.readU64();
    const request_epoch = try reader.readU64();
    const execution_abi = try reader.readU64();
    const sequence_base = try reader.readU64();
    const next_sequence = try reader.readU64();
    const last_resource_permit_generation =
        try reader.readU64();
    const terminal_u64 = try reader.readU64();
    if (terminal_u64 > 1) return Error.InvalidEncoding;
    return .{
        .abi_version = abi_version,
        .request_epoch = request_epoch,
        .execution_abi = execution_abi,
        .sequence_base = sequence_base,
        .next_sequence = next_sequence,
        .last_resource_permit_generation = last_resource_permit_generation,
        .terminal = terminal_u64 == 1,
        .state = try readStateCommitmentV1(reader),
        .transcript_sha256 = try reader.readDigest(),
    };
}

fn writeStateCommitmentV1(
    writer: *Writer,
    value: publication.StateCommitmentV1,
) void {
    writer.writeU64(value.abi_version);
    writer.writeU64(value.execution_abi);
    writer.writeU64(value.kv_position);
    writer.writeDigest(value.kv_state_sha256);
    writer.writeU64(value.rng_state_abi);
    writer.writeDigest(value.rng_state_sha256);
    writer.writeU64(value.sampling_calls);
    writer.writeU64(value.output_length);
    writer.writeDigest(value.output_state_sha256);
    writer.writeDigest(value.commitment_sha256);
}

fn readStateCommitmentV1(
    reader: *Reader,
) Error!publication.StateCommitmentV1 {
    return .{
        .abi_version = try reader.readU64(),
        .execution_abi = try reader.readU64(),
        .kv_position = try reader.readU64(),
        .kv_state_sha256 = try reader.readDigest(),
        .rng_state_abi = try reader.readU64(),
        .rng_state_sha256 = try reader.readDigest(),
        .sampling_calls = try reader.readU64(),
        .output_length = try reader.readU64(),
        .output_state_sha256 = try reader.readDigest(),
        .commitment_sha256 = try reader.readDigest(),
    };
}

fn writeReceiptV1(
    writer: *Writer,
    value: resource_bank.Receipt,
) void {
    writer.writeU64(value.bank_epoch);
    writer.writeU32(value.slot_index);
    writer.writeU32(0);
    writer.writeU64(value.generation);
    writer.writeU64(value.owner_key);
    writeClaimV1(writer, value.claim);
    writer.writeU64(value.integrity);
}

fn readReceiptV1(
    reader: *Reader,
) Error!resource_bank.Receipt {
    const bank_epoch = try reader.readU64();
    const slot_index = try reader.readU32();
    if (try reader.readU32() != 0)
        return Error.InvalidEncoding;
    return .{
        .bank_epoch = bank_epoch,
        .slot_index = slot_index,
        .generation = try reader.readU64(),
        .owner_key = try reader.readU64(),
        .claim = try readClaimV1(reader),
        .integrity = try reader.readU64(),
    };
}

fn writeTargetOwnershipV1(
    writer: *Writer,
    value: successor.TargetOwnershipV1,
) void {
    writer.writeU64(value.scheduler_epoch);
    writer.writeU64(value.coordinator_id);
    writer.writeU64(value.bank_epoch);
    writer.writeU64(value.request_generation);
    writer.writeU64(value.resource_owner_key);
    writer.writeU64(value.tree_key);
    writer.writeU64(value.authority_key);
    writer.writeU64(value.tenant_key);
    writer.writeU64(value.scope_key);
    writer.writeU64(value.cache_node_key);
    writer.writeU64(value.cache_binding_key);
    writer.writeU64(value.intent_generation);
    writeClaimV1(writer, value.request_claim);
}

fn readTargetOwnershipV1(
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

fn writeClaimV1(
    writer: *Writer,
    value: resource_bank.Claim,
) void {
    writer.writeU64(value.capsule_bytes);
    writer.writeU64(value.kv_bytes);
    writer.writeU64(value.activation_bytes);
    writer.writeU64(value.partial_bytes);
    writer.writeU64(value.logits_bytes);
    writer.writeU64(value.output_journal_bytes);
    writer.writeU64(value.staging_bytes);
    writer.writeU64(value.device_bytes);
    writer.writeU64(value.io_bytes);
    writer.writeU64(value.queue_slots);
}

fn readClaimV1(reader: *Reader) Error!resource_bank.Claim {
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

fn promptRootFromTokensV1(prompt: []const u32) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prompt_domain);
    hashU64(&hash, @intCast(prompt.len));
    for (prompt) |token| hashU32(&hash, token);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn promptRootFromWireV1(
    prompt_count: u64,
    canonical_u32_le: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prompt_domain);
    hashU64(&hash, prompt_count);
    hash.update(canonical_u32_le);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn planRootV1(plan: session.PlanV1) Digest {
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
    writeClaimHashV1(&hash, plan.claim);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn validatePromptTokensV1(
    prompt: []const u32,
    vocab_size: u64,
) Error!void {
    for (prompt) |token| {
        if (@as(u64, token) >= vocab_size)
            return Error.InvalidPrompt;
    }
}

fn validatePromptWireV1(
    canonical_u32_le: []const u8,
    vocab_size: u64,
) Error!void {
    if (canonical_u32_le.len % 4 != 0)
        return Error.InvalidPrompt;
    var offset: usize = 0;
    while (offset < canonical_u32_le.len) : (offset += 4) {
        const token = std.mem.readInt(
            u32,
            canonical_u32_le[offset..][0..4],
            .little,
        );
        if (@as(u64, token) >= vocab_size)
            return Error.InvalidPrompt;
    }
}

fn writeClaimHashV1(
    hash: *std.crypto.hash.sha2.Sha256,
    value: resource_bank.Claim,
) void {
    hashU64(hash, value.capsule_bytes);
    hashU64(hash, value.kv_bytes);
    hashU64(hash, value.activation_bytes);
    hashU64(hash, value.partial_bytes);
    hashU64(hash, value.logits_bytes);
    hashU64(hash, value.output_journal_bytes);
    hashU64(hash, value.staging_bytes);
    hashU64(hash, value.device_bytes);
    hashU64(hash, value.io_bytes);
    hashU64(hash, value.queue_slots);
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) void {
        const end = self.position + value.len;
        std.debug.assert(end <= self.bytes.len);
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeU32(self: *Writer, value: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        self.writeBytes(&bytes);
    }

    fn writeU64(self: *Writer, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.writeBytes(&bytes);
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

    fn readU32(self: *Reader) Error!u32 {
        return std.mem.readInt(
            u32,
            (try self.readBytes(4))[0..4],
            .little,
        );
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

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return digestEqual(value, [_]u8{0} ** 32);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(
        usize,
        a_start,
        a.len,
    ) catch std.math.maxInt(usize);
    const b_end = std.math.add(
        usize,
        b_start,
        b.len,
    ) catch std.math.maxInt(usize);
    return a_start < b_end and b_start < a_end;
}

const TestFixture = struct {
    prompt: [3]u32,
    options: session.OptionsV1,
    plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,

    fn init() !TestFixture {
        const prompt = [_]u32{ 5, 7, 11 };
        const options: session.OptionsV1 = .{
            .max_new_tokens = 5,
            .eos_token = std.math.maxInt(u32),
            .seed = 0x1020_3040_5060_7080,
        };
        const request_claim: resource_bank.Claim = .{
            .capsule_bytes = 64,
            .kv_bytes = 224,
            .activation_bytes = 12,
            .partial_bytes = 64,
            .logits_bytes = 1024,
            .output_journal_bytes = 20,
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
            .prompt_sha256 = promptRootFromTokensV1(&prompt),
            .max_new_tokens = options.max_new_tokens,
            .eos_token = options.eos_token,
            .seed = options.seed,
            .claim = request_claim,
            .plan_sha256 = [_]u8{0} ** 32,
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
                filledDigest(0x43),
            );
        const source_execution =
            try model_contract.makeExecutionPlanV1(
                artifact,
                .generate_sequence,
                .{
                    .request_epoch = 0x0102_0304_0506_0708,
                    .generation = 7,
                    .batch_items = 1,
                    .publication_next_sequence = 0,
                    .maximum_absolute_output = 255,
                    .claim = total_claim,
                    .media_object_sha256 = plan.prompt_sha256,
                    .processor_state_sha256 = filledDigest(0x32),
                    .processor_bundle_sha256 = filledDigest(0x33),
                    .cache_bundle_sha256 = filledDigest(0x34),
                    .cache_payload_sha256 = filledDigest(0x35),
                    .ownership_sha256 = filledDigest(0x36),
                    .challenge_sha256 = filledDigest(0xcc),
                    .previous_plan_sha256 = [_]u8{0} ** 32,
                    .input_schema_sha256 = filledDigest(0x37),
                    .output_schema_sha256 = filledDigest(0x38),
                    .scratch_bytes = request_claim.partial_bytes,
                },
            );
        const source_residency =
            try model_contract.makeExecutionResidencyBindingV1(
                source_execution,
                .shared_read_only,
                plan.image_identity.container_bytes,
                request_claim,
            );
        var bound_plan: session.BoundPlanV1 = .{
            .local_plan_sha256 = plan.plan_sha256,
            .artifact = artifact,
            .execution = source_execution,
            .residency = source_residency,
            .token_domain_sha256 = filledDigest(0x32),
            .token_domain_config_sha256 = filledDigest(0x33),
            .artifact_license_sha256 = filledDigest(0x43),
            .bound_plan_sha256 = [_]u8{0} ** 32,
        };
        bound_plan.bound_plan_sha256 =
            session.boundPlanRootV1(bound_plan);
        try session.validateBoundPlanV1(bound_plan);

        var slots = [_]resource_bank.Slot{.{}};
        var bank = try resource_bank.Bank.init(
            &slots,
            .{
                .host_bytes = 1 << 20,
                .capsule_bytes = 1 << 20,
                .kv_bytes = 1 << 20,
                .activation_bytes = 1 << 20,
                .partial_bytes = 1 << 20,
                .logits_bytes = 1 << 20,
                .output_journal_bytes = 1 << 20,
                .staging_bytes = 1 << 20,
                .device_bytes = 1 << 20,
                .io_bytes = 1 << 20,
                .queue_slots = 4,
            },
            41,
        );
        const reservation =
            try bank.reserve(1001, request_claim);
        const receipt = try bank.commit(reservation);
        const state = publication.makeStateCommitmentV1(
            lane_contiguous.abi,
            4,
            filledDigest(0x81),
            lane_contiguous.rng_state_abi,
            filledDigest(0x82),
            2,
            2,
            filledDigest(0x83),
        );
        const transcript_sha256 = filledDigest(0x77);
        const boundary_sha256 = filledDigest(0x66);
        const expected_checkpoint: checkpoint.ExpectedBindingsV1 =
            .{
                .local_plan_sha256 = plan.plan_sha256,
                .bound_plan_sha256 = bound_plan.bound_plan_sha256,
                .artifact_sha256 = artifact.artifact_sha256,
                .execution_plan_sha256 = source_execution.plan_sha256,
                .residency_binding_sha256 = source_residency.binding_sha256,
                .boundary_sha256 = boundary_sha256,
                .transcript_sha256 = transcript_sha256,
                .state_commitment_sha256 = state.commitment_sha256,
                .request_epoch = source_execution.request_epoch,
                .publication_next_sequence = 2,
                .prompt_tokens = prompt.len,
                .max_new_tokens = options.max_new_tokens,
                .vocab_size = 256,
                .num_layers = 2,
                .kv_dim = 2,
                .max_kv_positions = 7,
                .kv_positions = 4,
                .output_count = 2,
                .sampling_calls = 2,
                .challenge_sha256 = filledDigest(0xcc),
            };
        const source: successor.SourceContextV1 = .{
            .bound_plan_sha256 = bound_plan.bound_plan_sha256,
            .execution = source_execution,
            .residency = source_residency,
            .boundary_sha256 = boundary_sha256,
            .publication = .{
                .request_epoch = source_execution.request_epoch,
                .execution_abi = lane_contiguous.abi,
                .sequence_base = 0,
                .next_sequence = 2,
                .last_resource_permit_generation = 19,
                .terminal = false,
                .state = state,
                .transcript_sha256 = transcript_sha256,
            },
            .receipt = receipt,
        };
        return .{
            .prompt = prompt,
            .options = options,
            .plan = plan,
            .bound_plan = bound_plan,
            .expected_checkpoint = expected_checkpoint,
            .source = source,
            .target = .{
                .scheduler_epoch = 51,
                .coordinator_id = 52,
                .bank_epoch = 42,
                .request_generation = 8,
                .resource_owner_key = 2001,
                .tree_key = 2002,
                .authority_key = 2003,
                .tenant_key = 2004,
                .scope_key = 2005,
                .cache_node_key = 2006,
                .cache_binding_key = 2007,
                .intent_generation = 8,
                .request_claim = request_claim,
            },
        };
    }

    fn input(self: *const TestFixture) InputV1 {
        return .{
            .prompt = &self.prompt,
            .options = self.options,
            .plan = self.plan,
            .bound_plan = self.bound_plan,
            .expected_checkpoint = self.expected_checkpoint,
            .source = self.source,
            .target = self.target,
        };
    }
};

fn withTokenElementWidthsForTest(
    original: session.BoundPlanV1,
    input_element_bytes: u64,
    output_element_bytes: u64,
) !session.BoundPlanV1 {
    const artifact =
        try model_contract.makeArtifactManifestFromDigestV1(
            original.artifact.family,
            original.artifact.artifact_abi,
            original.artifact.input_kind,
            original.artifact.output_kind,
            original.artifact.numerical_policy,
            original.artifact.max_batch_items,
            original.artifact.input_features,
            original.artifact.output_dimensions,
            input_element_bytes,
            output_element_bytes,
            original.artifact.weight_element_bytes,
            original.artifact.weight_bytes,
            original.artifact.weights_sha256,
            original.artifact.metadata_sha256,
            original.artifact.license_sha256,
        );
    const execution = try model_contract.makeExecutionPlanV1(
        artifact,
        original.execution.operation,
        .{
            .request_epoch = original.execution.request_epoch,
            .generation = original.execution.generation,
            .batch_items = original.execution.batch_items,
            .publication_next_sequence = original.execution.publication_next_sequence,
            .maximum_absolute_output = original.execution.maximum_absolute_output,
            .required_capabilities = original.execution.required_capabilities,
            .claim = original.execution.claim,
            .media_object_sha256 = original.execution.media_object_sha256,
            .processor_state_sha256 = original.execution.processor_state_sha256,
            .processor_bundle_sha256 = original.execution.processor_bundle_sha256,
            .cache_bundle_sha256 = original.execution.cache_bundle_sha256,
            .cache_payload_sha256 = original.execution.cache_payload_sha256,
            .ownership_sha256 = original.execution.ownership_sha256,
            .challenge_sha256 = original.execution.challenge_sha256,
            .previous_plan_sha256 = original.execution.previous_plan_sha256,
            .input_schema_sha256 = original.execution.input_schema_sha256,
            .output_schema_sha256 = original.execution.output_schema_sha256,
            .scratch_bytes = original.execution.scratch_bytes,
        },
    );
    const residency =
        try model_contract.makeExecutionResidencyBindingV1(
            execution,
            original.residency.residency,
            original.residency.resident_weight_bytes,
            original.residency.request_claim,
        );
    var value = original;
    value.artifact = artifact;
    value.execution = execution;
    value.residency = residency;
    value.bound_plan_sha256 = [_]u8{0} ** 32;
    value.bound_plan_sha256 = session.boundPlanRootV1(value);
    return value;
}

test "prepared bound plan rejects coherent foreign token element widths" {
    const fixture = try TestFixture.init();
    const cases = [_]struct {
        input_element_bytes: u64,
        output_element_bytes: u64,
    }{
        .{
            .input_element_bytes = @sizeOf(u16),
            .output_element_bytes = @sizeOf(u32),
        },
        .{
            .input_element_bytes = @sizeOf(u32),
            .output_element_bytes = @sizeOf(u16),
        },
    };

    for (cases) |case| {
        const foreign = try withTokenElementWidthsForTest(
            fixture.bound_plan,
            case.input_element_bytes,
            case.output_element_bytes,
        );
        try model_contract.validateArtifactManifestV1(
            foreign.artifact,
        );
        try model_contract.validateExecutionPlanV1(
            foreign.execution,
        );
        try model_contract.validateExecutionResidencyBindingV1(
            foreign.residency,
            foreign.execution,
        );
        try std.testing.expectEqual(
            foreign.artifact.input_element_bytes,
            foreign.execution.input_element_bytes,
        );
        try std.testing.expectEqual(
            foreign.artifact.output_element_bytes,
            foreign.execution.output_element_bytes,
        );
        try std.testing.expectEqualDeep(
            fixture.bound_plan.local_plan_sha256,
            foreign.local_plan_sha256,
        );
        try std.testing.expectEqualDeep(
            fixture.bound_plan.token_domain_sha256,
            foreign.token_domain_sha256,
        );
        try std.testing.expectEqualDeep(
            fixture.bound_plan.token_domain_config_sha256,
            foreign.token_domain_config_sha256,
        );
        try std.testing.expectEqualDeep(
            fixture.bound_plan.artifact_license_sha256,
            foreign.artifact_license_sha256,
        );
        try std.testing.expectEqualDeep(
            foreign.bound_plan_sha256,
            session.boundPlanRootV1(foreign),
        );
        try std.testing.expectError(
            session.Error.InvalidBoundPlan,
            session.validateBoundPlanV1(foreign),
        );
    }
}

test "prepared text restart manifest is canonical and complete" {
    const fixture = try TestFixture.init();
    const required = try encodedBytesV1(fixture.prompt.len);
    try std.testing.expectEqual(@as(usize, 2964), required);
    const first_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(first_storage);
    const second_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(second_storage);
    const first = try encodeV1(
        fixture.input(),
        first_storage,
    );
    const second = try encodeV1(
        fixture.input(),
        second_storage,
    );
    try std.testing.expectEqualSlices(
        u8,
        first.bytes,
        second.bytes,
    );
    try std.testing.expectEqualSlices(
        u8,
        &first.manifest_sha256,
        &second.manifest_sha256,
    );

    const decoded = try decodeV1(first.bytes);
    try std.testing.expectEqual(
        fixture.prompt.len,
        decoded.promptCount(),
    );
    for (fixture.prompt, 0..) |token, index| {
        try std.testing.expectEqual(
            token,
            try decoded.promptToken(index),
        );
    }
    try std.testing.expectError(
        Error.InvalidPrompt,
        decoded.promptToken(fixture.prompt.len),
    );
    try std.testing.expectEqual(
        @intFromPtr(first.bytes.ptr) + prompt_offset,
        @intFromPtr(decoded.canonical_prompt_u32_le.ptr),
    );
    try std.testing.expect(std.meta.eql(
        fixture.options,
        decoded.options,
    ));
    try std.testing.expect(std.meta.eql(
        fixture.plan,
        decoded.plan,
    ));
    try std.testing.expect(std.meta.eql(
        fixture.bound_plan,
        decoded.bound_plan,
    ));
    try std.testing.expect(std.meta.eql(
        fixture.expected_checkpoint,
        decoded.expected_checkpoint,
    ));
    try std.testing.expect(std.meta.eql(
        fixture.source,
        decoded.source,
    ));
    try std.testing.expect(std.meta.eql(
        fixture.target,
        decoded.target,
    ));
    try std.testing.expectEqualSlices(
        u8,
        &first.manifest_sha256,
        &decoded.manifest_sha256,
    );
    try std.testing.expectEqual(
        @as(u64, fixture.options.max_new_tokens),
        std.mem.readInt(
            u64,
            first.bytes[options_offset..][0..8],
            .little,
        ),
    );
}

test "prepared text restart manifest rejects every committed mutation" {
    const fixture = try TestFixture.init();
    const required = try encodedBytesV1(fixture.prompt.len);
    const storage = try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(storage);
    const encoded = try encodeV1(
        fixture.input(),
        storage,
    );
    const mutated = try std.testing.allocator.dupe(
        u8,
        encoded.bytes,
    );
    defer std.testing.allocator.free(mutated);
    for (mutated) |*byte| {
        byte.* ^= 0x01;
        try expectDecodeReject(mutated);
        byte.* ^= 0x01;
    }
}

test "prepared text restart manifest rejects rehashed contradictions" {
    const fixture = try TestFixture.init();
    const required = try encodedBytesV1(fixture.prompt.len);
    const storage = try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(storage);
    const encoded = try encodeV1(
        fixture.input(),
        storage,
    );
    const mutated = try std.testing.allocator.dupe(
        u8,
        encoded.bytes,
    );
    defer std.testing.allocator.free(mutated);

    std.mem.writeInt(
        u64,
        mutated[options_offset..][0..8],
        fixture.options.max_new_tokens + 1,
        .little,
    );
    resealManifestV1(mutated);
    try expectDecodeReject(mutated);

    @memcpy(mutated, encoded.bytes);
    mutated[expected_bindings_offset] ^= 0x40;
    resealManifestV1(mutated);
    try expectDecodeReject(mutated);

    @memcpy(mutated, encoded.bytes);
    mutated[target_ownership_offset + 96] ^= 0x01;
    resealManifestV1(mutated);
    try expectDecodeReject(mutated);

    @memcpy(mutated, encoded.bytes);
    std.mem.writeInt(
        u64,
        mutated[88..96],
        1,
        .little,
    );
    resealManifestV1(mutated);
    try expectDecodeReject(mutated);
}

test "prepared text restart manifest encode failures preserve output" {
    const fixture = try TestFixture.init();
    const required = try encodedBytesV1(fixture.prompt.len);
    const destination =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(destination);
    @memset(destination, 0x6d);
    const before = try std.testing.allocator.dupe(
        u8,
        destination,
    );
    defer std.testing.allocator.free(before);

    var invalid = fixture.input();
    invalid.options.max_new_tokens += 1;
    try expectEncodeReject(invalid, destination);
    try std.testing.expectEqualSlices(
        u8,
        before,
        destination,
    );

    try expectEncodeReject(
        fixture.input(),
        destination[0 .. destination.len - 1],
    );
    try std.testing.expectEqualSlices(
        u8,
        before,
        destination,
    );

    var invalid_prompt = fixture.prompt;
    invalid_prompt[1] =
        @intCast(fixture.expected_checkpoint.vocab_size);
    invalid = fixture.input();
    invalid.prompt = &invalid_prompt;
    try expectEncodeReject(invalid, destination);
    try std.testing.expectEqualSlices(
        u8,
        before,
        destination,
    );

    const word_count = (required + 3) / 4;
    const overlap_words =
        try std.testing.allocator.alloc(u32, word_count);
    defer std.testing.allocator.free(overlap_words);
    @memset(overlap_words, 0xa5a5_a5a5);
    @memcpy(overlap_words[0..fixture.prompt.len], &fixture.prompt);
    const overlap_bytes = std.mem.sliceAsBytes(overlap_words);
    const overlap_before = try std.testing.allocator.dupe(
        u8,
        overlap_bytes,
    );
    defer std.testing.allocator.free(overlap_before);
    var overlap_input = fixture.input();
    overlap_input.prompt =
        overlap_words[0..fixture.prompt.len];
    try expectEncodeReject(
        overlap_input,
        overlap_bytes[0..required],
    );
    try std.testing.expectEqualSlices(
        u8,
        overlap_before,
        overlap_bytes,
    );

    try std.testing.expectError(
        Error.ArithmeticOverflow,
        encodedBytesV1(std.math.maxInt(usize)),
    );
}

fn expectDecodeReject(encoded: []const u8) !void {
    if (decodeV1(encoded)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

fn expectEncodeReject(
    input: InputV1,
    destination: []u8,
) !void {
    if (encodeV1(input, destination)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

fn resealManifestV1(encoded: []u8) void {
    const body = encoded[0 .. encoded.len - footer_bytes];
    const root = manifestRootV1(body);
    @memcpy(encoded[body.len..], &root);
}

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}
