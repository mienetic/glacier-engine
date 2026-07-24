//! Experimental, allocation-free C ABI for verifying a complete Model
//! Contract V1 chain.
//!
//! This surface deliberately exposes canonical wire bytes rather than Zig
//! struct layouts. It is not yet a stable ABI.

const std = @import("std");
const core = @import("glacier_core");
const contract = core.model_contract;
const support = core.runtime_support_registry;

pub const contract_c_abi_v1: u64 = 1;

pub const Status = enum(u32) {
    ok = 0,
    null_argument = 1,
    invalid_size = 2,
    invalid_artifact = 3,
    invalid_plan = 4,
    invalid_result = 5,
    binding_mismatch = 6,
    out_of_range = 7,
    invalid_query = 8,
};

const zero_digest: contract.Digest = [_]u8{0} ** 32;

pub const ModelSupportProfileV1 = extern struct {
    profile_abi: u64,
    lifecycle: u64,
    evidence: u64,
    family: u64,
    operation: u64,
    input_kind: u64,
    output_kind: u64,
    numerical_policy: u64,
    max_batch_items: u64,
    max_input_features: u64,
    max_output_dimensions: u64,
    allowed_capabilities: u64,
};

pub const ModelSupportQueryV1 = extern struct {
    family: u64,
    operation: u64,
    input_kind: u64,
    output_kind: u64,
    numerical_policy: u64,
    batch_items: u64,
    input_features: u64,
    output_dimensions: u64,
    required_capabilities: u64,
};

pub const ModelSupportResultV1 = extern struct {
    compatible: u64,
    unsupported_reason: u64,
    matching_profile_mask: u64,
};

export fn glacier_contract_abi_v1() callconv(.c) u64 {
    return contract_c_abi_v1;
}

export fn glacier_model_support_registry_abi_v1() callconv(.c) u64 {
    return support.registry_abi;
}

export fn glacier_model_contract_verify_v1(
    artifact_wire: ?[*]const u8,
    artifact_wire_size: usize,
    plan_wire: ?[*]const u8,
    plan_wire_size: usize,
    result_wire: ?[*]const u8,
    result_wire_size: usize,
    out_result_root: ?*[32]u8,
) callconv(.c) u32 {
    const result_root = out_result_root orelse
        return statusCode(.null_argument);
    var verified_root = zero_digest;
    const status = verifyModelContractV1(
        artifact_wire,
        artifact_wire_size,
        plan_wire,
        plan_wire_size,
        result_wire,
        result_wire_size,
        &verified_root,
    );
    result_root.* = verified_root;
    return statusCode(status);
}

export fn glacier_model_support_profile_count_v1() callconv(.c) u64 {
    return support.profiles.len;
}

export fn glacier_model_support_profile_get_v1(
    index: u64,
    out_profile: ?*ModelSupportProfileV1,
    out_profile_size: usize,
) callconv(.c) u32 {
    const output = out_profile orelse return statusCode(.null_argument);
    if (out_profile_size != @sizeOf(ModelSupportProfileV1))
        return statusCode(.invalid_size);
    output.* = std.mem.zeroes(ModelSupportProfileV1);
    if (index >= support.profiles.len)
        return statusCode(.out_of_range);

    const profile = support.profiles[@intCast(index)];
    output.* = .{
        .profile_abi = profile.profile_abi,
        .lifecycle = @intFromEnum(profile.lifecycle),
        .evidence = @intFromEnum(profile.evidence),
        .family = @intFromEnum(profile.support.family),
        .operation = @intFromEnum(profile.support.operation),
        .input_kind = @intFromEnum(profile.support.input_kind),
        .output_kind = @intFromEnum(profile.support.output_kind),
        .numerical_policy = @intFromEnum(
            profile.support.numerical_policy,
        ),
        .max_batch_items = profile.support.max_batch_items,
        .max_input_features = profile.support.max_input_features,
        .max_output_dimensions = profile.support.max_output_dimensions,
        .allowed_capabilities = profile.support.allowed_capabilities,
    };
    return statusCode(.ok);
}

export fn glacier_model_support_query_v1(
    query: ?*const ModelSupportQueryV1,
    query_size: usize,
    out_result: ?*ModelSupportResultV1,
    out_result_size: usize,
) callconv(.c) u32 {
    const output = out_result orelse return statusCode(.null_argument);
    if (out_result_size != @sizeOf(ModelSupportResultV1))
        return statusCode(.invalid_size);

    const query_pointer = query orelse {
        output.* = std.mem.zeroes(ModelSupportResultV1);
        return statusCode(.null_argument);
    };
    if (query_size != @sizeOf(ModelSupportQueryV1)) {
        output.* = std.mem.zeroes(ModelSupportResultV1);
        return statusCode(.invalid_size);
    }
    const raw_query = query_pointer.*;
    output.* = std.mem.zeroes(ModelSupportResultV1);

    const family = std.meta.intToEnum(
        contract.ModelFamilyIdV1,
        raw_query.family,
    ) catch return statusCode(.invalid_query);
    const operation = std.meta.intToEnum(
        contract.OperationIdV1,
        raw_query.operation,
    ) catch return statusCode(.invalid_query);
    const input_kind = std.meta.intToEnum(
        contract.InputKindV1,
        raw_query.input_kind,
    ) catch return statusCode(.invalid_query);
    const output_kind = std.meta.intToEnum(
        contract.OutputKindV1,
        raw_query.output_kind,
    ) catch return statusCode(.invalid_query);
    const numerical_policy = std.meta.intToEnum(
        contract.NumericalPolicyV1,
        raw_query.numerical_policy,
    ) catch return statusCode(.invalid_query);

    const result = support.querySupportV1(.{
        .family = family,
        .operation = operation,
        .input_kind = input_kind,
        .output_kind = output_kind,
        .numerical_policy = numerical_policy,
        .batch_items = raw_query.batch_items,
        .input_features = raw_query.input_features,
        .output_dimensions = raw_query.output_dimensions,
        .required_capabilities = raw_query.required_capabilities,
    });
    output.* = .{
        .compatible = @intFromBool(result.matching_profile_mask != 0),
        .unsupported_reason = if (result.deepest_unsupported_reason) |reason|
            @intFromEnum(reason)
        else
            0,
        .matching_profile_mask = result.matching_profile_mask,
    };
    return statusCode(.ok);
}

fn verifyModelContractV1(
    artifact_wire: ?[*]const u8,
    artifact_wire_size: usize,
    plan_wire: ?[*]const u8,
    plan_wire_size: usize,
    result_wire: ?[*]const u8,
    result_wire_size: usize,
    verified_root: *contract.Digest,
) Status {
    if (artifact_wire == null or plan_wire == null or result_wire == null)
        return .null_argument;
    if (artifact_wire_size != contract.artifact_manifest_bytes or
        plan_wire_size != contract.execution_plan_bytes or
        result_wire_size != contract.result_envelope_bytes)
        return .invalid_size;

    const artifact = contract.decodeArtifactManifestV1(
        artifact_wire.?[0..contract.artifact_manifest_bytes],
    ) catch return .invalid_artifact;
    const plan = contract.decodeExecutionPlanV1(
        plan_wire.?[0..contract.execution_plan_bytes],
    ) catch return .invalid_plan;
    const result = contract.decodeResultEnvelopeV1(
        result_wire.?[0..contract.result_envelope_bytes],
    ) catch return .invalid_result;

    if (!artifactBindsPlan(artifact, plan) or
        !planBindsResult(plan, result))
        return .binding_mismatch;

    verified_root.* = result.result_sha256;
    return .ok;
}

fn statusCode(status: Status) u32 {
    return @intFromEnum(status);
}

fn digestEqual(left: contract.Digest, right: contract.Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn artifactBindsPlan(
    artifact: contract.ArtifactManifestV1,
    plan: contract.ExecutionPlanV1,
) bool {
    return plan.family == artifact.family and
        plan.input_kind == artifact.input_kind and
        plan.output_kind == artifact.output_kind and
        plan.numerical_policy == artifact.numerical_policy and
        plan.batch_items <= artifact.max_batch_items and
        plan.input_features == artifact.input_features and
        plan.output_dimensions == artifact.output_dimensions and
        plan.weight_bytes == artifact.weight_bytes and
        plan.input_element_bytes == artifact.input_element_bytes and
        plan.output_element_bytes == artifact.output_element_bytes and
        digestEqual(plan.artifact_sha256, artifact.artifact_sha256) and
        digestEqual(plan.weights_sha256, artifact.weights_sha256);
}

fn planBindsResult(
    plan: contract.ExecutionPlanV1,
    result: contract.ResultEnvelopeV1,
) bool {
    return result.family == plan.family and
        result.operation == plan.operation and
        result.output_kind == plan.output_kind and
        result.numerical_policy == plan.numerical_policy and
        result.request_epoch == plan.request_epoch and
        result.generation == plan.generation and
        result.publication_sequence == plan.publication_next_sequence and
        result.batch_items == plan.batch_items and
        result.output_dimensions == plan.output_dimensions and
        result.output_element_bytes == plan.output_element_bytes and
        result.output_bytes == plan.output_bytes and
        std.meta.eql(result.claim, plan.claim) and
        digestEqual(result.artifact_sha256, plan.artifact_sha256) and
        digestEqual(result.plan_sha256, plan.plan_sha256) and
        digestEqual(result.media_object_sha256, plan.media_object_sha256) and
        digestEqual(
            result.processor_state_sha256,
            plan.processor_state_sha256,
        ) and
        digestEqual(result.cache_bundle_sha256, plan.cache_bundle_sha256) and
        digestEqual(result.cache_payload_sha256, plan.cache_payload_sha256) and
        digestEqual(result.ownership_sha256, plan.ownership_sha256) and
        digestEqual(result.challenge_sha256, plan.challenge_sha256);
}

test "C model support profiles use fixed layouts and fail closed" {
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(ModelSupportProfileV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(ModelSupportQueryV1));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ModelSupportResultV1));
    try std.testing.expectEqual(
        support.registry_abi,
        glacier_model_support_registry_abi_v1(),
    );
    try std.testing.expectEqual(
        @as(u64, support.profiles.len),
        glacier_model_support_profile_count_v1(),
    );

    var profile = std.mem.zeroes(ModelSupportProfileV1);
    try std.testing.expectEqual(
        statusCode(.ok),
        glacier_model_support_profile_get_v1(
            0,
            &profile,
            @sizeOf(ModelSupportProfileV1),
        ),
    );
    try std.testing.expectEqual(
        support.profiles[0].profile_abi,
        profile.profile_abi,
    );
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(support.LifecycleV1.stateless)),
        profile.lifecycle,
    );
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(contract.ModelFamilyIdV1.vision_understanding)),
        profile.family,
    );

    profile.profile_abi = 1;
    try std.testing.expectEqual(
        statusCode(.out_of_range),
        glacier_model_support_profile_get_v1(
            support.profiles.len,
            &profile,
            @sizeOf(ModelSupportProfileV1),
        ),
    );
    try std.testing.expect(std.meta.eql(
        std.mem.zeroes(ModelSupportProfileV1),
        profile,
    ));
    try std.testing.expectEqual(
        statusCode(.null_argument),
        glacier_model_support_profile_get_v1(
            0,
            null,
            @sizeOf(ModelSupportProfileV1),
        ),
    );
    try std.testing.expectEqual(
        statusCode(.invalid_size),
        glacier_model_support_profile_get_v1(
            0,
            &profile,
            @sizeOf(ModelSupportProfileV1) - 1,
        ),
    );
}

test "C model support query returns every compatible profile bit" {
    const transcript_mask =
        (@as(u64, 1) << @intFromEnum(
            support.ProfileIndexV1.audio_transcript,
        )) |
        (@as(u64, 1) << @intFromEnum(
            support.ProfileIndexV1.stateful_transcript,
        ));
    const raw_query: ModelSupportQueryV1 = .{
        .family = @intFromEnum(contract.ModelFamilyIdV1.audio_understanding),
        .operation = @intFromEnum(contract.OperationIdV1.transcribe),
        .input_kind = @intFromEnum(contract.InputKindV1.audio_feature_i16),
        .output_kind = @intFromEnum(contract.OutputKindV1.transcript),
        .numerical_policy = @intFromEnum(
            contract.NumericalPolicyV1.exact_integer,
        ),
        .batch_items = 1,
        .input_features = 4,
        .output_dimensions = 64,
        .required_capabilities = 0,
    };
    var result = std.mem.zeroes(ModelSupportResultV1);
    try std.testing.expectEqual(
        statusCode(.ok),
        glacier_model_support_query_v1(
            &raw_query,
            @sizeOf(ModelSupportQueryV1),
            &result,
            @sizeOf(ModelSupportResultV1),
        ),
    );
    try std.testing.expectEqual(@as(u64, 1), result.compatible);
    try std.testing.expectEqual(@as(u64, 0), result.unsupported_reason);
    try std.testing.expectEqual(transcript_mask, result.matching_profile_mask);

    var alias_storage: [@sizeOf(ModelSupportQueryV1)]u8 align(@alignOf(ModelSupportQueryV1)) = undefined;
    const alias_query: *ModelSupportQueryV1 = @ptrCast(&alias_storage);
    const alias_result: *ModelSupportResultV1 = @ptrCast(&alias_storage);
    alias_query.* = raw_query;
    try std.testing.expectEqual(
        statusCode(.ok),
        glacier_model_support_query_v1(
            alias_query,
            @sizeOf(ModelSupportQueryV1),
            alias_result,
            @sizeOf(ModelSupportResultV1),
        ),
    );
    try std.testing.expectEqual(transcript_mask, alias_result.matching_profile_mask);

    var broad_query = raw_query;
    broad_query.input_features = 4_096;
    broad_query.output_dimensions = 384;
    try std.testing.expectEqual(
        statusCode(.ok),
        glacier_model_support_query_v1(
            &broad_query,
            @sizeOf(ModelSupportQueryV1),
            &result,
            @sizeOf(ModelSupportResultV1),
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 1) << @intFromEnum(
            support.ProfileIndexV1.audio_transcript,
        ),
        result.matching_profile_mask,
    );
}

test "C model support query distinguishes invalid and unsupported input" {
    var raw_query: ModelSupportQueryV1 = .{
        .family = @intFromEnum(contract.ModelFamilyIdV1.audio_understanding),
        .operation = @intFromEnum(contract.OperationIdV1.transcribe),
        .input_kind = @intFromEnum(contract.InputKindV1.audio_feature_i16),
        .output_kind = @intFromEnum(contract.OutputKindV1.transcript),
        .numerical_policy = @intFromEnum(
            contract.NumericalPolicyV1.exact_integer,
        ),
        .batch_items = 1,
        .input_features = 4,
        .output_dimensions = 64,
        .required_capabilities = 1,
    };
    var result = std.mem.zeroes(ModelSupportResultV1);
    try std.testing.expectEqual(
        statusCode(.ok),
        glacier_model_support_query_v1(
            &raw_query,
            @sizeOf(ModelSupportQueryV1),
            &result,
            @sizeOf(ModelSupportResultV1),
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), result.compatible);
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(contract.UnsupportedReasonV1.capabilities)),
        result.unsupported_reason,
    );

    raw_query.required_capabilities = 0;
    raw_query.output_dimensions = 0;
    try std.testing.expectEqual(
        statusCode(.ok),
        glacier_model_support_query_v1(
            &raw_query,
            @sizeOf(ModelSupportQueryV1),
            &result,
            @sizeOf(ModelSupportResultV1),
        ),
    );
    try std.testing.expectEqual(
        @as(u64, @intFromEnum(contract.UnsupportedReasonV1.dimensions)),
        result.unsupported_reason,
    );

    raw_query.family = std.math.maxInt(u64);
    result.compatible = 1;
    try std.testing.expectEqual(
        statusCode(.invalid_query),
        glacier_model_support_query_v1(
            &raw_query,
            @sizeOf(ModelSupportQueryV1),
            &result,
            @sizeOf(ModelSupportResultV1),
        ),
    );
    try std.testing.expect(std.meta.eql(
        std.mem.zeroes(ModelSupportResultV1),
        result,
    ));
    try std.testing.expectEqual(
        statusCode(.null_argument),
        glacier_model_support_query_v1(
            null,
            @sizeOf(ModelSupportQueryV1),
            &result,
            @sizeOf(ModelSupportResultV1),
        ),
    );
    try std.testing.expectEqual(
        statusCode(.invalid_size),
        glacier_model_support_query_v1(
            &raw_query,
            @sizeOf(ModelSupportQueryV1),
            &result,
            @sizeOf(ModelSupportResultV1) - 1,
        ),
    );
}

const Fixture = struct {
    artifact_wire: [contract.artifact_manifest_bytes]u8,
    plan_wire: [contract.execution_plan_bytes]u8,
    result_wire: [contract.result_envelope_bytes]u8,
    result_root: contract.Digest,
};

fn makeFixture(seed: u8) !Fixture {
    const weights = [_]u8{
        seed,
        seed +% 1,
        seed +% 2,
        seed +% 3,
        seed +% 4,
        seed +% 5,
        seed +% 6,
        seed +% 7,
    };
    const manifest = try contract.makeArtifactManifestV1(
        .vision_understanding,
        0x5649_5349_4f4e_0001,
        .image_feature_u8,
        .embedding_i32,
        .exact_integer,
        2,
        4,
        2,
        1,
        4,
        1,
        &weights,
        contract.sha256(&[_]u8{ seed, 0x4d }),
        contract.sha256(&[_]u8{ seed, 0x4c }),
    );
    const claim: core.resource_bank.Claim = .{
        .capsule_bytes = weights.len,
        .activation_bytes = 8,
        .partial_bytes = 16,
        .output_journal_bytes = 16,
        .queue_slots = 1,
    };
    const plan = try contract.makeExecutionPlanV1(manifest, .encode, .{
        .request_epoch = 41,
        .generation = 7,
        .batch_items = 2,
        .publication_next_sequence = 0,
        .maximum_absolute_output = 4096,
        .claim = claim,
        .media_object_sha256 = contract.sha256(&[_]u8{ seed, 0x01 }),
        .processor_state_sha256 = contract.sha256(&[_]u8{ seed, 0x02 }),
        .processor_bundle_sha256 = contract.sha256(&[_]u8{ seed, 0x03 }),
        .cache_bundle_sha256 = contract.sha256(&[_]u8{ seed, 0x04 }),
        .cache_payload_sha256 = contract.sha256(&[_]u8{ seed, 0x05 }),
        .ownership_sha256 = contract.sha256(&[_]u8{ seed, 0x06 }),
        .challenge_sha256 = contract.sha256(&[_]u8{ seed, 0x07 }),
        .previous_plan_sha256 = zero_digest,
        .input_schema_sha256 = contract.sha256(&[_]u8{ seed, 0x08 }),
        .output_schema_sha256 = contract.sha256(&[_]u8{ seed, 0x09 }),
        .scratch_bytes = 16,
    });
    const state = try contract.initializePublicationStateV1(
        plan.request_epoch,
        plan.artifact_sha256,
    );
    const receipt: core.resource_bank.Receipt = .{
        .bank_epoch = 3,
        .slot_index = 1,
        .generation = 9,
        .owner_key = 77,
        .claim = claim,
        .integrity = 88,
    };
    const result = try contract.prepareResultEnvelopeV1(
        state,
        plan,
        receipt,
        contract.sha256(&[_]u8{ seed, 0x0a }),
        contract.sha256(&[_]u8{ seed, 0x0b }),
        contract.sha256(&[_]u8{ seed, 0x0c }),
    );

    var fixture: Fixture = undefined;
    try contract.encodeArtifactManifestV1(
        manifest,
        &fixture.artifact_wire,
    );
    try contract.encodeExecutionPlanV1(plan, &fixture.plan_wire);
    try contract.encodeResultEnvelopeV1(result, &fixture.result_wire);
    fixture.result_root = result.result_sha256;
    return fixture;
}

test "C ABI verifies a fully bound Model Contract V1 chain" {
    const fixture = try makeFixture(1);
    var result_root = [_]u8{0xaa} ** 32;

    try std.testing.expectEqual(
        contract_c_abi_v1,
        glacier_contract_abi_v1(),
    );
    try std.testing.expectEqual(
        statusCode(.ok),
        glacier_model_contract_verify_v1(
            fixture.artifact_wire[0..].ptr,
            fixture.artifact_wire.len,
            fixture.plan_wire[0..].ptr,
            fixture.plan_wire.len,
            fixture.result_wire[0..].ptr,
            fixture.result_wire.len,
            &result_root,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.result_root,
        &result_root,
    );
}

test "C artifact binding keeps V1 dimensions exact" {
    const fixture = try makeFixture(1);
    const artifact = try contract.decodeArtifactManifestV1(
        &fixture.artifact_wire,
    );
    const plan = try contract.decodeExecutionPlanV1(&fixture.plan_wire);
    try std.testing.expect(artifactBindsPlan(artifact, plan));

    var different_input = plan;
    different_input.input_features = 3;
    different_input.input_bytes = 6;
    different_input.plan_sha256 = zero_digest;
    var different_input_wire: [contract.execution_plan_bytes]u8 = undefined;
    try contract.encodeExecutionPlanV1(
        different_input,
        &different_input_wire,
    );
    different_input = try contract.decodeExecutionPlanV1(
        &different_input_wire,
    );
    try std.testing.expect(!artifactBindsPlan(artifact, different_input));

    var different_output = plan;
    different_output.output_dimensions = 1;
    different_output.output_bytes = 8;
    different_output.plan_sha256 = zero_digest;
    var different_output_wire: [contract.execution_plan_bytes]u8 = undefined;
    try contract.encodeExecutionPlanV1(
        different_output,
        &different_output_wire,
    );
    different_output = try contract.decodeExecutionPlanV1(
        &different_output_wire,
    );
    try std.testing.expect(!artifactBindsPlan(artifact, different_output));
}

test "C ABI permits the output root to alias the canonical result root" {
    const fixture = try makeFixture(1);
    var result_wire = fixture.result_wire;
    const root_offset = result_wire.len - zero_digest.len;
    const aliased_root: *[32]u8 = @ptrCast(result_wire[root_offset..].ptr);

    try std.testing.expectEqual(
        statusCode(.ok),
        glacier_model_contract_verify_v1(
            fixture.artifact_wire[0..].ptr,
            fixture.artifact_wire.len,
            fixture.plan_wire[0..].ptr,
            fixture.plan_wire.len,
            result_wire[0..].ptr,
            result_wire.len,
            aliased_root,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.result_wire,
        &result_wire,
    );
}

test "C ABI fails closed for invalid input and cross-wire mismatch" {
    const fixture = try makeFixture(1);
    const other = try makeFixture(17);
    var result_root = [_]u8{0xaa} ** 32;

    try std.testing.expectEqual(
        statusCode(.null_argument),
        glacier_model_contract_verify_v1(
            fixture.artifact_wire[0..].ptr,
            fixture.artifact_wire.len,
            fixture.plan_wire[0..].ptr,
            fixture.plan_wire.len,
            fixture.result_wire[0..].ptr,
            fixture.result_wire.len,
            null,
        ),
    );

    try std.testing.expectEqual(
        statusCode(.invalid_size),
        glacier_model_contract_verify_v1(
            fixture.artifact_wire[0..].ptr,
            fixture.artifact_wire.len - 1,
            fixture.plan_wire[0..].ptr,
            fixture.plan_wire.len,
            fixture.result_wire[0..].ptr,
            fixture.result_wire.len,
            &result_root,
        ),
    );
    try std.testing.expectEqualSlices(u8, &zero_digest, &result_root);

    @memset(&result_root, 0xaa);
    try std.testing.expectEqual(
        statusCode(.binding_mismatch),
        glacier_model_contract_verify_v1(
            fixture.artifact_wire[0..].ptr,
            fixture.artifact_wire.len,
            fixture.plan_wire[0..].ptr,
            fixture.plan_wire.len,
            other.result_wire[0..].ptr,
            other.result_wire.len,
            &result_root,
        ),
    );
    try std.testing.expectEqualSlices(u8, &zero_digest, &result_root);

    @memset(&result_root, 0xaa);
    try std.testing.expectEqual(
        statusCode(.binding_mismatch),
        glacier_model_contract_verify_v1(
            fixture.artifact_wire[0..].ptr,
            fixture.artifact_wire.len,
            other.plan_wire[0..].ptr,
            other.plan_wire.len,
            other.result_wire[0..].ptr,
            other.result_wire.len,
            &result_root,
        ),
    );
    try std.testing.expectEqualSlices(u8, &zero_digest, &result_root);

    @memset(&result_root, 0xaa);
    try std.testing.expectEqual(
        statusCode(.null_argument),
        glacier_model_contract_verify_v1(
            null,
            fixture.artifact_wire.len,
            fixture.plan_wire[0..].ptr,
            fixture.plan_wire.len,
            fixture.result_wire[0..].ptr,
            fixture.result_wire.len,
            &result_root,
        ),
    );
    try std.testing.expectEqualSlices(u8, &zero_digest, &result_root);
}

test "C ABI distinguishes invalid canonical wires" {
    const fixture = try makeFixture(1);
    var result_root = [_]u8{0xaa} ** 32;

    var invalid_artifact = fixture.artifact_wire;
    invalid_artifact[0] ^= 0xff;
    try std.testing.expectEqual(
        statusCode(.invalid_artifact),
        glacier_model_contract_verify_v1(
            invalid_artifact[0..].ptr,
            invalid_artifact.len,
            fixture.plan_wire[0..].ptr,
            fixture.plan_wire.len,
            fixture.result_wire[0..].ptr,
            fixture.result_wire.len,
            &result_root,
        ),
    );
    try std.testing.expectEqualSlices(u8, &zero_digest, &result_root);

    var invalid_plan = fixture.plan_wire;
    invalid_plan[0] ^= 0xff;
    @memset(&result_root, 0xaa);
    try std.testing.expectEqual(
        statusCode(.invalid_plan),
        glacier_model_contract_verify_v1(
            fixture.artifact_wire[0..].ptr,
            fixture.artifact_wire.len,
            invalid_plan[0..].ptr,
            invalid_plan.len,
            fixture.result_wire[0..].ptr,
            fixture.result_wire.len,
            &result_root,
        ),
    );
    try std.testing.expectEqualSlices(u8, &zero_digest, &result_root);

    var invalid_result = fixture.result_wire;
    invalid_result[0] ^= 0xff;
    @memset(&result_root, 0xaa);
    try std.testing.expectEqual(
        statusCode(.invalid_result),
        glacier_model_contract_verify_v1(
            fixture.artifact_wire[0..].ptr,
            fixture.artifact_wire.len,
            fixture.plan_wire[0..].ptr,
            fixture.plan_wire.len,
            invalid_result[0..].ptr,
            invalid_result.len,
            &result_root,
        ),
    );
    try std.testing.expectEqualSlices(u8, &zero_digest, &result_root);
}
