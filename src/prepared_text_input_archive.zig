//! Canonical, durable raw-input context for prepared text.
//!
//! This archive carries the stable model package, one exact native prepared
//! representation, the canonical tokenizer manifest and prompt receipt, the
//! raw-plan binding, and the retained UTF-8 bytes. A fresh process can
//! therefore re-tokenize the original bytes and reconstruct the request
//! without treating caller-supplied tokenizer or license roots as authority.

const std = @import("std");
const package_manifest = @import("model/package_manifest.zig");
const raw_input = @import("prepared_text_raw_input.zig");
const session = @import("prepared_text_session.zig");
const tokenizer = @import("tokenizer.zig");

pub const Digest = [32]u8;
pub const archive_abi: u64 = 0x4750_5449_0000_0001;
pub const archive_magic =
    [_]u8{ 'G', 'P', 'T', 'I', 'N', 'P', '1', 0 };
pub const allowed_flags: u64 = 0;
pub const header_bytes: usize = 128;
pub const footer_bytes: usize = 32;
pub const fixed_payload_bytes: usize =
    package_manifest.manifest_bytes +
    package_manifest.prepared_representation_bytes +
    tokenizer.utf8_byte_manifest_bytes +
    tokenizer.utf8_byte_prompt_bytes +
    raw_input.binding_bytes;
pub const raw_text_offset: usize =
    header_bytes + fixed_payload_bytes;
pub const minimum_encoded_bytes: usize =
    raw_text_offset + footer_bytes;

const package_offset: usize = header_bytes;
const representation_offset: usize =
    package_offset + package_manifest.manifest_bytes;
const tokenizer_manifest_offset: usize =
    representation_offset +
    package_manifest.prepared_representation_bytes;
const tokenizer_prompt_offset: usize =
    tokenizer_manifest_offset +
    tokenizer.utf8_byte_manifest_bytes;
const raw_binding_offset: usize =
    tokenizer_prompt_offset +
    tokenizer.utf8_byte_prompt_bytes;

comptime {
    if (package_offset != 128 or
        representation_offset != 768 or
        tokenizer_manifest_offset != 1024 or
        tokenizer_prompt_offset != 1216 or
        raw_binding_offset != 1472 or
        raw_text_offset != 1952)
        @compileError("prepared-text input archive layout drift");
}

const archive_domain =
    "glacier-prepared-text-input-archive-v1\x00";

pub const Error = package_manifest.Error ||
    raw_input.Error ||
    tokenizer.CanonicalError ||
    error{
        ArithmeticOverflow,
        BufferTooSmall,
        InvalidArchive,
        InvalidContext,
        InvalidPackage,
        InvalidRawInput,
        UnsafeDestination,
    };

pub const InputV1 = struct {
    package: package_manifest.ManifestV1,
    representation: package_manifest.PreparedRepresentationV1,
    raw_text: []const u8,
    tokenized: *const tokenizer.Utf8ByteTokenizedPromptV1,
    local_plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
};

pub const EncodedV1 = struct {
    bytes: []const u8,
    archive_sha256: Digest,
};

pub const DecodedV1 = struct {
    encoded: []const u8,
    package: package_manifest.ManifestV1,
    representation: package_manifest.PreparedRepresentationV1,
    tokenizer_manifest: tokenizer.Utf8ByteManifestV1,
    tokenizer_prompt: tokenizer.Utf8BytePromptReceiptV1,
    binding: raw_input.BindingV1,
    raw_text: []const u8,
    archive_sha256: Digest,
};

pub fn encodedBytesV1(raw_text_bytes: usize) Error!usize {
    if (raw_text_bytes == 0 or
        raw_text_bytes > tokenizer.utf8_byte_max_input_bytes)
        return Error.InvalidRawInput;
    return std.math.add(
        usize,
        minimum_encoded_bytes,
        raw_text_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Validate every component before publishing any destination byte.
pub fn encodeV1(
    input: InputV1,
    destination: []u8,
) Error!EncodedV1 {
    try package_manifest.validateV1(input.package);
    try package_manifest.validatePreparedRepresentationV1(
        input.package,
        input.representation,
    );
    if (!tokenizer.utf8BytePromptValidForTokensV1(
        input.tokenized.receipt,
        input.tokenized.manifest,
        input.raw_text,
        input.tokenized.tokens,
    ))
        return Error.InvalidRawInput;
    const binding = raw_input.makeBindingV1(
        input.raw_text,
        input.tokenized,
        input.local_plan,
        input.bound_plan,
    ) catch return Error.InvalidContext;
    try validateSourceBindingsV1(
        input.package,
        input.representation,
        input.tokenized.manifest,
        input.tokenized.receipt,
        binding,
        input.local_plan,
        input.bound_plan,
    );

    var package_wire: [package_manifest.manifest_bytes]u8 =
        undefined;
    _ = try package_manifest.encodeV1(
        input.package,
        &package_wire,
    );
    var representation_wire: [
        package_manifest.prepared_representation_bytes
    ]u8 = undefined;
    _ = try package_manifest.encodePreparedRepresentationV1(
        input.representation,
        &representation_wire,
    );
    var tokenizer_manifest_wire: [
        tokenizer.utf8_byte_manifest_bytes
    ]u8 = undefined;
    _ = try tokenizer.encodeUtf8ByteManifestV1(
        input.tokenized.manifest,
        &tokenizer_manifest_wire,
    );
    var tokenizer_prompt_wire: [
        tokenizer.utf8_byte_prompt_bytes
    ]u8 = undefined;
    _ = try tokenizer.encodeUtf8BytePromptReceiptV1(
        input.tokenized.receipt,
        &tokenizer_prompt_wire,
    );
    var binding_wire: [raw_input.binding_bytes]u8 =
        undefined;
    _ = try raw_input.encodeV1(binding, &binding_wire);

    const required = try encodedBytesV1(input.raw_text.len);
    if (destination.len < required)
        return Error.BufferTooSmall;
    const output = destination[0..required];
    if (slicesOverlap(output, input.raw_text) or
        slicesOverlap(
            output,
            std.mem.sliceAsBytes(input.tokenized.tokens),
        ))
        return Error.UnsafeDestination;

    @memset(output, 0);
    @memcpy(output[0..8], &archive_magic);
    writeU64(output, 8, archive_abi);
    writeU64(output, 16, @intCast(required));
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, header_bytes);
    writeU64(output, 40, fixed_payload_bytes);
    writeU64(output, 48, @intCast(input.raw_text.len));
    writeU64(output, 56, package_manifest.manifest_bytes);
    writeU64(
        output,
        64,
        package_manifest.prepared_representation_bytes,
    );
    writeU64(
        output,
        72,
        tokenizer.utf8_byte_manifest_bytes,
    );
    writeU64(
        output,
        80,
        tokenizer.utf8_byte_prompt_bytes,
    );
    writeU64(output, 88, raw_input.binding_bytes);
    @memcpy(
        output[package_offset..representation_offset],
        &package_wire,
    );
    @memcpy(
        output[representation_offset..tokenizer_manifest_offset],
        &representation_wire,
    );
    @memcpy(
        output[tokenizer_manifest_offset..tokenizer_prompt_offset],
        &tokenizer_manifest_wire,
    );
    @memcpy(
        output[tokenizer_prompt_offset..raw_binding_offset],
        &tokenizer_prompt_wire,
    );
    @memcpy(
        output[raw_binding_offset..raw_text_offset],
        &binding_wire,
    );
    @memcpy(
        output[raw_text_offset .. raw_text_offset +
            input.raw_text.len],
        input.raw_text,
    );
    const body = output[0 .. output.len - footer_bytes];
    const archive_sha256 = archiveRootV1(body);
    @memcpy(output[body.len..], &archive_sha256);
    return .{
        .bytes = output,
        .archive_sha256 = archive_sha256,
    };
}

pub fn decodeV1(encoded: []const u8) Error!DecodedV1 {
    if (encoded.len < minimum_encoded_bytes)
        return Error.InvalidArchive;
    const body = encoded[0 .. encoded.len - footer_bytes];
    const archive_sha256 = archiveRootV1(body);
    if (!digestEqual(
        archive_sha256,
        encoded[body.len..][0..32].*,
    ) or !std.mem.eql(
        u8,
        encoded[0..8],
        &archive_magic,
    ) or readU64(encoded, 8) != archive_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 32) != header_bytes or
        readU64(encoded, 40) != fixed_payload_bytes or
        readU64(encoded, 56) !=
            package_manifest.manifest_bytes or
        readU64(encoded, 64) !=
            package_manifest.prepared_representation_bytes or
        readU64(encoded, 72) !=
            tokenizer.utf8_byte_manifest_bytes or
        readU64(encoded, 80) !=
            tokenizer.utf8_byte_prompt_bytes or
        readU64(encoded, 88) != raw_input.binding_bytes or
        !allZero(encoded[96..header_bytes]))
        return Error.InvalidArchive;
    const raw_text_bytes = std.math.cast(
        usize,
        readU64(encoded, 48),
    ) orelse return Error.InvalidArchive;
    if (try encodedBytesV1(raw_text_bytes) != encoded.len)
        return Error.InvalidArchive;

    const package = try package_manifest.decodeV1(
        encoded[package_offset..representation_offset],
    );
    const representation =
        try package_manifest.decodePreparedRepresentationV1(
            encoded[representation_offset..tokenizer_manifest_offset],
        );
    try package_manifest.validatePreparedRepresentationV1(
        package,
        representation,
    );
    const tokenizer_manifest =
        try tokenizer.decodeUtf8ByteManifestV1(
            encoded[tokenizer_manifest_offset..tokenizer_prompt_offset],
        );
    const tokenizer_prompt =
        try tokenizer.decodeUtf8BytePromptReceiptV1(
            encoded[tokenizer_prompt_offset..raw_binding_offset],
        );
    const binding = try raw_input.decodeV1(
        encoded[raw_binding_offset..raw_text_offset],
    );
    const raw_text =
        encoded[raw_text_offset .. raw_text_offset +
        raw_text_bytes];
    try validateDecodedBindingsV1(
        package,
        representation,
        tokenizer_manifest,
        tokenizer_prompt,
        binding,
        raw_text,
    );
    return .{
        .encoded = encoded,
        .package = package,
        .representation = representation,
        .tokenizer_manifest = tokenizer_manifest,
        .tokenizer_prompt = tokenizer_prompt,
        .binding = binding,
        .raw_text = raw_text,
        .archive_sha256 = archive_sha256,
    };
}

/// Re-run the tokenizer in a fresh allocator domain and require the exact
/// retained prompt receipt. Caller owns the returned tokenized prompt.
pub fn retokenizeV1(
    allocator: std.mem.Allocator,
    decoded: DecodedV1,
) Error!tokenizer.Utf8ByteTokenizedPromptV1 {
    var tokenized = tokenizer.tokenizeUtf8BytesV1(
        allocator,
        decoded.tokenizer_manifest,
        decoded.raw_text,
    ) catch return Error.InvalidRawInput;
    errdefer tokenized.deinit();
    if (!std.meta.eql(
        tokenized.receipt,
        decoded.tokenizer_prompt,
    ))
        return Error.InvalidRawInput;
    return tokenized;
}

/// Verify the exact source-generation plans named by the raw binding.
pub fn verifySourceContextV1(
    decoded: DecodedV1,
    tokenized: *const tokenizer.Utf8ByteTokenizedPromptV1,
    local_plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
) Error!void {
    if (!std.meta.eql(
        tokenized.manifest,
        decoded.tokenizer_manifest,
    ) or !std.meta.eql(
        tokenized.receipt,
        decoded.tokenizer_prompt,
    ) or !raw_input.bindingValidForV1(
        decoded.binding,
        decoded.raw_text,
        tokenized,
        local_plan,
        bound_plan,
    ))
        return Error.InvalidContext;
    try validateSourceBindingsV1(
        decoded.package,
        decoded.representation,
        decoded.tokenizer_manifest,
        decoded.tokenizer_prompt,
        decoded.binding,
        local_plan,
        bound_plan,
    );
}

/// Later restart generations derive a new bound-plan root but must retain the
/// same local request, package, representation, tokenizer, artifact, and
/// license identities.
pub fn verifyCurrentPlanV1(
    decoded: DecodedV1,
    local_plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
) Error!void {
    try verifyCurrentPlanValuesV1(
        decoded.representation,
        decoded.binding,
        local_plan,
        bound_plan,
    );
    if (!digestEqual(
        bound_plan.artifact.weights_sha256,
        local_plan.image_identity.container_sha256,
    ) or bound_plan.artifact.weight_bytes !=
        local_plan.image_identity.container_bytes)
        return Error.InvalidContext;
}

fn validateSourceBindingsV1(
    package: package_manifest.ManifestV1,
    representation: package_manifest.PreparedRepresentationV1,
    tokenizer_manifest: tokenizer.Utf8ByteManifestV1,
    tokenizer_prompt: tokenizer.Utf8BytePromptReceiptV1,
    binding: raw_input.BindingV1,
    local_plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
) Error!void {
    try package_manifest.validatePreparedRepresentationV1(
        package,
        representation,
    );
    if (package.family != bound_plan.artifact.family or
        package.tokenizer_manifest_abi !=
            tokenizer.utf8_byte_manifest_abi or
        package.tokenizer_manifest_bytes !=
            tokenizer.utf8_byte_manifest_bytes or
        package.config.vocab != tokenizer_manifest.vocab_size or
        !digestEqual(
            package.tokenizer_config_sha256,
            tokenizer_manifest.config_sha256,
        ) or !digestEqual(
        package.tokenizer_domain_sha256,
        tokenizer_manifest.domain_sha256,
    ) or !digestEqual(
        package.tokenizer_behavior_sha256,
        tokenizer_manifest.behavior_sha256,
    ) or !digestEqual(
        package.license_sha256,
        bound_plan.artifact_license_sha256,
    ) or !digestEqual(
        tokenizer_prompt.receipt_sha256,
        binding.tokenizer_prompt_receipt_sha256,
    ) or !digestEqual(
        representation.package_sha256,
        package.package_sha256,
    ))
        return Error.InvalidPackage;
    try verifyCurrentPlanValuesV1(
        representation,
        binding,
        local_plan,
        bound_plan,
    );
    if (!digestEqual(
        binding.bound_plan_sha256,
        bound_plan.bound_plan_sha256,
    ) or !digestEqual(
        binding.execution_plan_sha256,
        bound_plan.execution.plan_sha256,
    ) or !digestEqual(
        binding.residency_binding_sha256,
        bound_plan.residency.binding_sha256,
    ))
        return Error.InvalidContext;
}

fn verifyCurrentPlanValuesV1(
    representation: package_manifest.PreparedRepresentationV1,
    binding: raw_input.BindingV1,
    local_plan: session.PlanV1,
    bound_plan: session.BoundPlanV1,
) Error!void {
    session.validateBoundPlanV1(bound_plan) catch
        return Error.InvalidContext;
    if (!session.planValidV1(local_plan) or
        !digestEqual(
            binding.local_plan_sha256,
            local_plan.plan_sha256,
        ) or !digestEqual(
        bound_plan.local_plan_sha256,
        local_plan.plan_sha256,
    ) or !digestEqual(
        binding.artifact_sha256,
        bound_plan.artifact.artifact_sha256,
    ) or !digestEqual(
        binding.tokenizer_domain_sha256,
        bound_plan.token_domain_sha256,
    ) or !digestEqual(
        binding.tokenizer_config_sha256,
        bound_plan.token_domain_config_sha256,
    ) or !digestEqual(
        binding.artifact_license_sha256,
        bound_plan.artifact_license_sha256,
    ) or !digestEqual(
        representation.source_fingerprint,
        local_plan.image_identity.source_fingerprint,
    ) or !digestEqual(
        representation.abi_fingerprint,
        local_plan.image_identity.abi_fingerprint,
    ) or representation.container_bytes !=
        local_plan.image_identity.container_bytes or
        !digestEqual(
            representation.container_sha256,
            local_plan.image_identity.container_sha256,
        ))
        return Error.InvalidContext;
}

fn validateDecodedBindingsV1(
    package: package_manifest.ManifestV1,
    representation: package_manifest.PreparedRepresentationV1,
    tokenizer_manifest: tokenizer.Utf8ByteManifestV1,
    tokenizer_prompt: tokenizer.Utf8BytePromptReceiptV1,
    binding: raw_input.BindingV1,
    raw_text: []const u8,
) Error!void {
    if (!std.unicode.utf8ValidateSlice(raw_text) or
        raw_text.len == 0 or
        raw_text.len > tokenizer_manifest.max_input_bytes or
        tokenizer_prompt.raw_text_bytes != raw_text.len or
        tokenizer_prompt.token_count != raw_text.len or
        binding.raw_text_bytes != raw_text.len or
        binding.prompt_tokens != raw_text.len or
        package.config.vocab != tokenizer_manifest.vocab_size or
        package.tokenizer_manifest_abi !=
            tokenizer.utf8_byte_manifest_abi or
        package.tokenizer_manifest_bytes !=
            tokenizer.utf8_byte_manifest_bytes or
        !digestEqual(
            tokenizer_prompt.raw_text_sha256,
            tokenizer.utf8ByteRawTextRootV1(raw_text),
        ) or !digestEqual(
        tokenizer_prompt.tokenizer_domain_sha256,
        tokenizer_manifest.domain_sha256,
    ) or !digestEqual(
        tokenizer_prompt.tokenizer_config_sha256,
        tokenizer_manifest.config_sha256,
    ) or !digestEqual(
        binding.tokenizer_prompt_receipt_sha256,
        tokenizer_prompt.receipt_sha256,
    ) or !digestEqual(
        binding.raw_text_sha256,
        tokenizer_prompt.raw_text_sha256,
    ) or !digestEqual(
        binding.token_ids_sha256,
        tokenizer_prompt.token_ids_sha256,
    ) or !digestEqual(
        binding.tokenizer_domain_sha256,
        tokenizer_manifest.domain_sha256,
    ) or !digestEqual(
        binding.tokenizer_config_sha256,
        tokenizer_manifest.config_sha256,
    ) or !digestEqual(
        binding.prepared_prompt_sha256,
        session.promptByteTokensSha256V1(raw_text),
    ) or !digestEqual(
        package.tokenizer_config_sha256,
        tokenizer_manifest.config_sha256,
    ) or !digestEqual(
        package.tokenizer_domain_sha256,
        tokenizer_manifest.domain_sha256,
    ) or !digestEqual(
        package.tokenizer_behavior_sha256,
        tokenizer_manifest.behavior_sha256,
    ) or !digestEqual(
        package.license_sha256,
        binding.artifact_license_sha256,
    ) or !digestEqual(
        representation.package_sha256,
        package.package_sha256,
    ))
        return Error.InvalidRawInput;
}

fn archiveRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(archive_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
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

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = left_start + left.len;
    const right_end = right_start + right.len;
    return left_start < right_end and
        right_start < left_end;
}
