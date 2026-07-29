//! Raw UTF-8 input binding for the prepared-text common-plan path.
//!
//! Tokenizer evidence and a valid prepared-text plan are separate claims until
//! this module joins them. The fixed wire proves that one exact raw byte
//! string produced the exact u32 prompt committed by the local plan, and that
//! the common artifact/execution/residency records retained the same tokenizer
//! domain and configuration.

const std = @import("std");
const core = @import("core");
const model_contract = core.model_contract;
const prepared = @import("prepared_text_session.zig");
const tokenizer = @import("tokenizer.zig");

pub const Digest = [32]u8;
pub const binding_abi: u64 = 0x4750_5452_0000_0001;
pub const binding_bytes: usize = 480;
pub const binding_body_bytes: usize = binding_bytes - 32;
pub const binding_flags: u64 = 0;
pub const binding_magic =
    [_]u8{ 'G', 'P', 'T', 'R', 'A', 'W', '1', 0 };

const binding_domain =
    "glacier-prepared-text-raw-input-binding-v1\x00";

pub const Error = error{
    InvalidLength,
    InvalidTokenizer,
    InvalidPlan,
    InvalidBinding,
    InvalidLicense,
    InvalidRequest,
    UnsafeDestination,
};

/// Canonical join between raw-input evidence and the already canonical
/// prepared-text plan family. It contains roots only; callers retain the
/// manifest, prompt receipt, raw text, token ids, and plan wires when they need
/// independent reconstruction.
pub const BindingV1 = struct {
    abi_version: u64 = binding_abi,
    tokenizer_domain_sha256: Digest,
    tokenizer_config_sha256: Digest,
    tokenizer_prompt_receipt_sha256: Digest,
    raw_text_sha256: Digest,
    token_ids_sha256: Digest,
    prepared_prompt_sha256: Digest,
    local_plan_sha256: Digest,
    bound_plan_sha256: Digest,
    artifact_sha256: Digest,
    execution_plan_sha256: Digest,
    residency_binding_sha256: Digest,
    artifact_license_sha256: Digest,
    request_epoch: u64,
    prompt_tokens: u64,
    raw_text_bytes: u64,
    binding_sha256: Digest,
};

/// Derive the common-plan inputs from verified tokenizer bytes rather than
/// accepting opaque tokenizer assertions. The license root is still supplied
/// by the caller; supported commands hash the exact retained license bytes
/// before calling this function.
pub fn makeBoundPlanInputV1(
    request_epoch: u64,
    manifest: tokenizer.Utf8ByteManifestV1,
    artifact_license_sha256: Digest,
) Error!prepared.BoundPlanInputV1 {
    if (request_epoch == 0) return Error.InvalidRequest;
    if (!tokenizer.utf8ByteManifestValidV1(manifest))
        return Error.InvalidTokenizer;
    if (isZeroDigest(artifact_license_sha256))
        return Error.InvalidLicense;
    return .{
        .request_epoch = request_epoch,
        .token_domain_sha256 = manifest.domain_sha256,
        .token_domain_config_sha256 = manifest.config_sha256,
        .artifact_license_sha256 = artifact_license_sha256,
    };
}

pub fn makeBindingV1(
    text: []const u8,
    tokenized: *const tokenizer.Utf8ByteTokenizedPromptV1,
    local_plan: prepared.PlanV1,
    bound_plan: prepared.BoundPlanV1,
) Error!BindingV1 {
    if (!tokenizer.utf8BytePromptValidForTokensV1(
        tokenized.receipt,
        tokenized.manifest,
        text,
        tokenized.tokens,
    ))
        return Error.InvalidTokenizer;
    if (!prepared.planValidV1(local_plan))
        return Error.InvalidPlan;
    prepared.validateBoundPlanV1(bound_plan) catch
        return Error.InvalidPlan;
    const prompt_sha256 =
        prepared.promptTokensSha256V1(tokenized.tokens);
    const input_bytes = std.math.mul(
        u64,
        @intCast(tokenized.tokens.len),
        @sizeOf(u32),
    ) catch return Error.InvalidPlan;
    if (local_plan.prompt_tokens != tokenized.tokens.len or
        !digestEqual(local_plan.prompt_sha256, prompt_sha256) or
        !digestEqual(
            local_plan.plan_sha256,
            bound_plan.local_plan_sha256,
        ) or
        !digestEqual(
            bound_plan.token_domain_sha256,
            tokenized.manifest.domain_sha256,
        ) or
        !digestEqual(
            bound_plan.token_domain_config_sha256,
            tokenized.manifest.config_sha256,
        ) or
        !digestEqual(
            bound_plan.execution.processor_state_sha256,
            tokenized.manifest.domain_sha256,
        ) or
        !digestEqual(
            bound_plan.execution.processor_bundle_sha256,
            tokenized.manifest.config_sha256,
        ) or
        !digestEqual(
            bound_plan.execution.media_object_sha256,
            prompt_sha256,
        ) or
        local_plan.image_identity.container_bytes !=
            bound_plan.artifact.weight_bytes or
        !digestEqual(
            local_plan.image_identity.container_sha256,
            bound_plan.artifact.weights_sha256,
        ) or
        local_plan.max_new_tokens !=
            bound_plan.artifact.output_dimensions or
        local_plan.max_new_tokens !=
            bound_plan.execution.output_dimensions or
        !std.meta.eql(
            local_plan.claim,
            bound_plan.residency.request_claim,
        ) or
        !digestEqual(
            bound_plan.execution.challenge_sha256,
            tokenized.receipt.receipt_sha256,
        ) or
        bound_plan.execution.request_epoch == 0 or
        bound_plan.execution.batch_items != 1 or
        bound_plan.execution.input_features !=
            tokenized.tokens.len or
        bound_plan.execution.input_element_bytes !=
            @sizeOf(u32) or
        bound_plan.execution.input_bytes != input_bytes or
        bound_plan.artifact.input_features !=
            tokenized.tokens.len or
        bound_plan.artifact.input_element_bytes !=
            @sizeOf(u32) or
        !digestEqual(
            bound_plan.artifact.license_sha256,
            bound_plan.artifact_license_sha256,
        ))
        return Error.InvalidPlan;

    var value: BindingV1 = .{
        .tokenizer_domain_sha256 = tokenized.manifest.domain_sha256,
        .tokenizer_config_sha256 = tokenized.manifest.config_sha256,
        .tokenizer_prompt_receipt_sha256 = tokenized.receipt.receipt_sha256,
        .raw_text_sha256 = tokenized.receipt.raw_text_sha256,
        .token_ids_sha256 = tokenized.receipt.token_ids_sha256,
        .prepared_prompt_sha256 = prompt_sha256,
        .local_plan_sha256 = local_plan.plan_sha256,
        .bound_plan_sha256 = bound_plan.bound_plan_sha256,
        .artifact_sha256 = bound_plan.artifact.artifact_sha256,
        .execution_plan_sha256 = bound_plan.execution.plan_sha256,
        .residency_binding_sha256 = bound_plan.residency.binding_sha256,
        .artifact_license_sha256 = bound_plan.artifact_license_sha256,
        .request_epoch = bound_plan.execution.request_epoch,
        .prompt_tokens = @intCast(tokenized.tokens.len),
        .raw_text_bytes = @intCast(text.len),
        .binding_sha256 = undefined,
    };
    var body: [binding_body_bytes]u8 = undefined;
    writeBodyV1(value, &body);
    value.binding_sha256 = rootV1(&body);
    if (!structurallyValidV1(value))
        return Error.InvalidBinding;
    return value;
}

pub fn bindingValidForV1(
    value: BindingV1,
    text: []const u8,
    tokenized: *const tokenizer.Utf8ByteTokenizedPromptV1,
    local_plan: prepared.PlanV1,
    bound_plan: prepared.BoundPlanV1,
) bool {
    const expected = makeBindingV1(
        text,
        tokenized,
        local_plan,
        bound_plan,
    ) catch return false;
    return std.meta.eql(value, expected);
}

pub fn encodeV1(
    value: BindingV1,
    destination: []u8,
) Error![]u8 {
    if (destination.len != binding_bytes)
        return Error.InvalidLength;
    if (!structurallyValidV1(value))
        return Error.InvalidBinding;
    var local: [binding_bytes]u8 = undefined;
    writeBodyV1(value, local[0..binding_body_bytes]);
    @memcpy(
        local[binding_body_bytes..],
        &value.binding_sha256,
    );
    if (slicesOverlap(destination, &local))
        return Error.UnsafeDestination;
    @memcpy(destination, &local);
    return destination;
}

pub fn decodeV1(encoded: []const u8) Error!BindingV1 {
    if (encoded.len != binding_bytes)
        return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &binding_magic) or
        readU64(encoded, 8) != binding_abi or
        readU64(encoded, 16) != binding_bytes or
        readU64(encoded, 24) != binding_flags or
        !allZero(encoded[440..binding_body_bytes]))
        return Error.InvalidBinding;
    const value: BindingV1 = .{
        .tokenizer_domain_sha256 = encoded[32..64].*,
        .tokenizer_config_sha256 = encoded[64..96].*,
        .tokenizer_prompt_receipt_sha256 = encoded[96..128].*,
        .raw_text_sha256 = encoded[128..160].*,
        .token_ids_sha256 = encoded[160..192].*,
        .prepared_prompt_sha256 = encoded[192..224].*,
        .local_plan_sha256 = encoded[224..256].*,
        .bound_plan_sha256 = encoded[256..288].*,
        .artifact_sha256 = encoded[288..320].*,
        .execution_plan_sha256 = encoded[320..352].*,
        .residency_binding_sha256 = encoded[352..384].*,
        .artifact_license_sha256 = encoded[384..416].*,
        .request_epoch = readU64(encoded, 416),
        .prompt_tokens = readU64(encoded, 424),
        .raw_text_bytes = readU64(encoded, 432),
        .binding_sha256 = encoded[binding_body_bytes..][0..32].*,
    };
    if (!structurallyValidV1(value))
        return Error.InvalidBinding;
    return value;
}

pub fn rootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(binding_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn structurallyValidV1(value: BindingV1) bool {
    if (value.abi_version != binding_abi or
        value.request_epoch == 0 or
        value.prompt_tokens == 0 or
        value.raw_text_bytes == 0 or
        value.prompt_tokens != value.raw_text_bytes or
        value.raw_text_bytes >
            tokenizer.utf8_byte_max_input_bytes or
        !digestEqual(
            value.tokenizer_domain_sha256,
            tokenizer.utf8ByteDomainSha256V1(),
        ))
        return false;
    inline for (.{
        value.tokenizer_config_sha256,
        value.tokenizer_prompt_receipt_sha256,
        value.raw_text_sha256,
        value.token_ids_sha256,
        value.prepared_prompt_sha256,
        value.local_plan_sha256,
        value.bound_plan_sha256,
        value.artifact_sha256,
        value.execution_plan_sha256,
        value.residency_binding_sha256,
        value.artifact_license_sha256,
    }) |digest| {
        if (isZeroDigest(digest)) return false;
    }
    var body: [binding_body_bytes]u8 = undefined;
    writeBodyV1(value, &body);
    return digestEqual(value.binding_sha256, rootV1(&body));
}

fn writeBodyV1(
    value: BindingV1,
    destination: []u8,
) void {
    std.debug.assert(destination.len == binding_body_bytes);
    @memset(destination, 0);
    @memcpy(destination[0..8], &binding_magic);
    writeU64(destination, 8, binding_abi);
    writeU64(destination, 16, binding_bytes);
    writeU64(destination, 24, binding_flags);
    @memcpy(
        destination[32..64],
        &value.tokenizer_domain_sha256,
    );
    @memcpy(
        destination[64..96],
        &value.tokenizer_config_sha256,
    );
    @memcpy(
        destination[96..128],
        &value.tokenizer_prompt_receipt_sha256,
    );
    @memcpy(destination[128..160], &value.raw_text_sha256);
    @memcpy(destination[160..192], &value.token_ids_sha256);
    @memcpy(
        destination[192..224],
        &value.prepared_prompt_sha256,
    );
    @memcpy(destination[224..256], &value.local_plan_sha256);
    @memcpy(destination[256..288], &value.bound_plan_sha256);
    @memcpy(destination[288..320], &value.artifact_sha256);
    @memcpy(
        destination[320..352],
        &value.execution_plan_sha256,
    );
    @memcpy(
        destination[352..384],
        &value.residency_binding_sha256,
    );
    @memcpy(
        destination[384..416],
        &value.artifact_license_sha256,
    );
    writeU64(destination, 416, value.request_epoch);
    writeU64(destination, 424, value.prompt_tokens);
    writeU64(destination, 432, value.raw_text_bytes);
}

fn writeU64(
    destination: []u8,
    offset: usize,
    value: u64,
) void {
    std.mem.writeInt(
        u64,
        destination[offset..][0..8],
        value,
        .little,
    );
}

fn readU64(source: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        source[offset..][0..8],
        .little,
    );
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZeroDigest(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
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
    const left_end = left_start + left.len;
    const right_end = right_start + right.len;
    return left_start < right_end and right_start < left_end;
}

test "raw-input binding wire rejects every byte mutation" {
    const digest = model_contract.sha256("raw-input-test");
    var value: BindingV1 = .{
        .tokenizer_domain_sha256 = tokenizer.utf8ByteDomainSha256V1(),
        .tokenizer_config_sha256 = digest,
        .tokenizer_prompt_receipt_sha256 = digest,
        .raw_text_sha256 = digest,
        .token_ids_sha256 = digest,
        .prepared_prompt_sha256 = digest,
        .local_plan_sha256 = digest,
        .bound_plan_sha256 = digest,
        .artifact_sha256 = digest,
        .execution_plan_sha256 = digest,
        .residency_binding_sha256 = digest,
        .artifact_license_sha256 = digest,
        .request_epoch = 1,
        .prompt_tokens = 3,
        .raw_text_bytes = 3,
        .binding_sha256 = undefined,
    };
    var body: [binding_body_bytes]u8 = undefined;
    writeBodyV1(value, &body);
    value.binding_sha256 = rootV1(&body);
    var encoded: [binding_bytes]u8 = undefined;
    _ = try encodeV1(value, &encoded);
    try std.testing.expectEqualDeep(value, try decodeV1(&encoded));

    for (encoded, 0..) |_, index| {
        var mutated = encoded;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidBinding,
            decodeV1(&mutated),
        );
    }
}
