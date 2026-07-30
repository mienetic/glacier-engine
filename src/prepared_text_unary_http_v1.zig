//! Canonical bounded JSON profile for prepared-text unary HTTP/1.1.
//!
//! The route names and outer JSON shape are intentionally familiar, while
//! this R1 profile remains strict and small: one user message, non-streaming
//! output, and fixed request/response limits.

const std = @import("std");

pub const Digest = [32]u8;

pub const schema_v1 = "glacier.prepared-text-unary-http/r1-v1";
pub const models_path_v1 = "/v1/models";
pub const completions_path_v1 = "/v1/chat/completions";
pub const json_content_type = "application/json";
pub const idempotency_header = "Idempotency-Key";
pub const tenant_header = "Glacier-Tenant-Key";
pub const deadline_header = "Glacier-Deadline-Tick";
pub const model_id_prefix = "glacier-r1-";
pub const completion_id_prefix = "chatcmpl-";

pub const header_max_bytes = 8 * 1024;
pub const request_body_max_bytes = 32 * 1024;
pub const response_body_max_bytes = 8 * 1024;
pub const parser_workspace_bytes = 64 * 1024;
pub const prompt_max_bytes = 4096;
pub const output_max_tokens = 64;
pub const idempotency_key_max_bytes = 128;
pub const model_id_bytes = model_id_prefix.len + 64;
pub const completion_id_bytes = completion_id_prefix.len + 64;

const idempotency_domain =
    "glacier.prepared-text-unary-http/idempotency/r1-v1\x00";
const request_domain =
    "glacier.prepared-text-unary-http/request/r1-v1\x00";

pub const Error = error{
    OutOfMemory,
    BufferTooSmall,
    InvalidRequest,
    RequestTooLarge,
    InvalidHeader,
    InvalidIdempotencyKey,
    InvalidTenantKey,
    InvalidDeadline,
    InvalidUtf8,
    UnsupportedProfile,
    ModelNotFound,
    NonUtf8Output,
    InvalidResponse,
};

pub const HeaderFactsV1 = struct {
    idempotency_key: ?[]const u8 = null,
    tenant_key: ?[]const u8 = null,
    deadline_tick: ?[]const u8 = null,
};

pub const RequestV1 = struct {
    model_id: []const u8,
    tenant_key: u64,
    idempotency_key: []const u8,
    prompt_utf8: []const u8,
    max_new_tokens: u16,
    deadline_tick: u64 = 0,
};

const MessageJsonV1 = struct {
    role: []const u8,
    content: []const u8,
};

const RequestJsonV1 = struct {
    model: []const u8,
    messages: []const MessageJsonV1,
    max_tokens: u16,
    stream: bool,
};

pub const DecodedRequestV1 = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(RequestJsonV1),
    request: RequestV1,

    pub fn deinit(self: *DecodedRequestV1) void {
        self.allocator.free(
            @constCast(self.request.idempotency_key),
        );
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const ModelListV1 = struct {
    model_id: [model_id_bytes]u8,
    model_binding_sha256: Digest,
};

pub const CompletionFactsV1 = struct {
    model_id: []const u8,
    content_utf8: []const u8,
    output_tokens: []const u32,
    prompt_tokens: u32,
    handle_sha256: Digest,
    request_sha256: Digest,
    response_sha256: Digest,
    terminal_evidence_sha256: Digest,
    output_sha256: Digest,
};

pub const CompletionV1 = struct {
    id: [completion_id_bytes]u8,
    model_id: [model_id_bytes]u8,
    content: [output_max_tokens]u8 = [_]u8{0} ** output_max_tokens,
    content_bytes: u8,
    output_tokens: [output_max_tokens]u32 =
        [_]u32{0} ** output_max_tokens,
    output_count: u8,
    prompt_tokens: u32,
    request_sha256: Digest,
    response_sha256: Digest,
    terminal_evidence_sha256: Digest,
    output_sha256: Digest,

    pub fn contentSlice(self: *const CompletionV1) []const u8 {
        return self.content[0..self.content_bytes];
    }

    pub fn outputSlice(self: *const CompletionV1) []const u32 {
        return self.output_tokens[0..self.output_count];
    }
};

pub const ErrorCodeV1 = enum {
    invalid_request,
    request_too_large,
    route_not_found,
    method_not_allowed,
    unsupported_media_type,
    http_version_not_supported,
    missing_content_length,
    header_too_large,
    unsupported_profile,
    model_not_found,
    idempotency_conflict,
    service_capacity,
    scheduler_rejected,
    request_cancelled,
    execution_failed,
    non_utf8_model_output,
    recovery_required,
    service_closed,
    runtime_unavailable,
    fail_stop_required,
    state_drift,
    sequence_exhausted,
    out_of_memory,
    internal_error,
};

pub const RetryDispositionV1 = enum {
    never,
    same_request_after_backoff,
    inspect_runtime,
};

pub const ApiErrorV1 = struct {
    code: ErrorCodeV1,
    retry: RetryDispositionV1,
    request_sha256: ?Digest = null,
};

const ModelEntryJsonV1 = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    owned_by: []const u8,
};

const ModelListEvidenceJsonV1 = struct {
    schema: []const u8,
    model_binding_sha256: []const u8,
};

const ModelListJsonV1 = struct {
    object: []const u8,
    data: []const ModelEntryJsonV1,
    glacier: ModelListEvidenceJsonV1,
};

const AssistantMessageJsonV1 = struct {
    role: []const u8,
    content: []const u8,
};

const ChoiceJsonV1 = struct {
    index: u32,
    message: AssistantMessageJsonV1,
    finish_reason: []const u8,
};

const UsageJsonV1 = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

const CompletionEvidenceJsonV1 = struct {
    schema: []const u8,
    request_sha256: []const u8,
    response_sha256: []const u8,
    terminal_evidence_sha256: []const u8,
    output_sha256: []const u8,
    output_tokens: []const u32,
};

const CompletionJsonV1 = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []const ChoiceJsonV1,
    usage: UsageJsonV1,
    glacier: CompletionEvidenceJsonV1,
};

const ErrorDetailsJsonV1 = struct {
    schema: []const u8,
    code: ErrorCodeV1,
    message: []const u8,
    retry: RetryDispositionV1,
    request_sha256: ?[]const u8,
};

const ErrorJsonV1 = struct {
    @"error": ErrorDetailsJsonV1,
};

pub fn modelIdV1(binding_sha256: Digest) [model_id_bytes]u8 {
    var result: [model_id_bytes]u8 = undefined;
    @memcpy(result[0..model_id_prefix.len], model_id_prefix);
    const hex = std.fmt.bytesToHex(binding_sha256, .lower);
    @memcpy(result[model_id_prefix.len..], &hex);
    return result;
}

pub fn idempotencyKeySha256V1(
    key: []const u8,
) Error!Digest {
    try validateIdempotencyKey(key);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(idempotency_domain);
    hashU16(&hasher, @intCast(key.len));
    hasher.update(key);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn requestSha256V1(request: RequestV1) Error!Digest {
    try validateRequest(request, null);
    const idempotency_sha256 =
        try idempotencyKeySha256V1(request.idempotency_key);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(request_domain);
    hashU16(&hasher, @intCast(request.model_id.len));
    hasher.update(request.model_id);
    hashU64(&hasher, request.tenant_key);
    hasher.update(&idempotency_sha256);
    hashU32(&hasher, @intCast(request.prompt_utf8.len));
    hasher.update(request.prompt_utf8);
    hashU16(&hasher, request.max_new_tokens);
    hashU64(&hasher, request.deadline_tick);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn decodeRequestV1(
    allocator: std.mem.Allocator,
    body: []const u8,
    headers: HeaderFactsV1,
    expected_model_id: []const u8,
) Error!DecodedRequestV1 {
    if (body.len == 0) return Error.InvalidRequest;
    if (body.len > request_body_max_bytes) return Error.RequestTooLarge;

    var parsed = std.json.parseFromSlice(
        RequestJsonV1,
        allocator,
        body,
        .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = request_body_max_bytes,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.InvalidRequest,
    };
    errdefer parsed.deinit();

    const idempotency_key = headers.idempotency_key orelse
        return Error.InvalidHeader;
    const tenant_bytes = headers.tenant_key orelse
        return Error.InvalidHeader;
    const tenant_key = parseCanonicalU64(tenant_bytes, false) catch
        return Error.InvalidTenantKey;
    const deadline_tick = if (headers.deadline_tick) |value|
        parseCanonicalU64(value, true) catch
            return Error.InvalidDeadline
    else
        0;
    const owned_idempotency_key = allocator.dupe(
        u8,
        idempotency_key,
    ) catch return Error.OutOfMemory;
    errdefer allocator.free(owned_idempotency_key);

    if (parsed.value.messages.len != 1)
        return Error.UnsupportedProfile;
    const message = parsed.value.messages[0];
    const request: RequestV1 = .{
        .model_id = parsed.value.model,
        .tenant_key = tenant_key,
        .idempotency_key = owned_idempotency_key,
        .prompt_utf8 = message.content,
        .max_new_tokens = parsed.value.max_tokens,
        .deadline_tick = deadline_tick,
    };
    try validateRequest(request, expected_model_id);
    if (!std.mem.eql(u8, message.role, "user"))
        return Error.UnsupportedProfile;
    if (parsed.value.stream) return Error.UnsupportedProfile;

    return .{
        .allocator = allocator,
        .parsed = parsed,
        .request = request,
    };
}

pub fn encodeRequestV1(
    request: RequestV1,
    destination: []u8,
) Error![]const u8 {
    try validateRequest(request, null);
    const message = MessageJsonV1{
        .role = "user",
        .content = request.prompt_utf8,
    };
    const messages = [_]MessageJsonV1{message};
    return encodeJson(.{
        .model = request.model_id,
        .messages = messages[0..],
        .max_tokens = request.max_new_tokens,
        .stream = false,
    }, destination);
}

pub fn encodeModelListV1(
    model_id: []const u8,
    binding_sha256: Digest,
    destination: []u8,
) Error![]const u8 {
    try validateModelId(model_id);
    const expected = modelIdV1(binding_sha256);
    if (!std.mem.eql(u8, model_id, &expected))
        return Error.InvalidRequest;
    const binding_hex = std.fmt.bytesToHex(binding_sha256, .lower);
    const entry = ModelEntryJsonV1{
        .id = model_id,
        .object = "model",
        .created = 0,
        .owned_by = "glacier",
    };
    const entries = [_]ModelEntryJsonV1{entry};
    return encodeJson(.{
        .object = "list",
        .data = entries[0..],
        .glacier = .{
            .schema = schema_v1,
            .model_binding_sha256 = binding_hex[0..],
        },
    }, destination);
}

pub fn decodeModelListV1(
    allocator: std.mem.Allocator,
    body: []const u8,
) Error!ModelListV1 {
    if (body.len == 0 or body.len > response_body_max_bytes)
        return Error.InvalidResponse;
    var parsed = std.json.parseFromSlice(
        ModelListJsonV1,
        allocator,
        body,
        strictResponseOptions(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.InvalidResponse,
    };
    defer parsed.deinit();

    const value = parsed.value;
    if (!std.mem.eql(u8, value.object, "list") or
        value.data.len != 1 or
        !std.mem.eql(u8, value.data[0].object, "model") or
        value.data[0].created != 0 or
        !std.mem.eql(u8, value.data[0].owned_by, "glacier") or
        !std.mem.eql(u8, value.glacier.schema, schema_v1))
    {
        return Error.InvalidResponse;
    }
    try validateModelId(value.data[0].id);
    const binding_sha256 =
        try parseDigest(value.glacier.model_binding_sha256);
    const expected_model_id = modelIdV1(binding_sha256);
    if (!std.mem.eql(u8, value.data[0].id, &expected_model_id))
        return Error.InvalidResponse;
    return .{
        .model_id = expected_model_id,
        .model_binding_sha256 = binding_sha256,
    };
}

pub fn encodeCompletionV1(
    facts: CompletionFactsV1,
    destination: []u8,
) Error![]const u8 {
    try validateModelId(facts.model_id);
    if (facts.content_utf8.len == 0 or
        facts.content_utf8.len > output_max_tokens or
        facts.output_tokens.len != facts.content_utf8.len or
        !std.unicode.utf8ValidateSlice(facts.content_utf8))
    {
        return Error.NonUtf8Output;
    }
    for (facts.output_tokens, facts.content_utf8) |token, byte| {
        const token_byte = std.math.cast(u8, token) orelse
            return Error.NonUtf8Output;
        if (token_byte != byte) return Error.NonUtf8Output;
    }
    if (facts.prompt_tokens == 0 or
        isZeroDigest(facts.handle_sha256) or
        isZeroDigest(facts.request_sha256) or
        isZeroDigest(facts.response_sha256) or
        isZeroDigest(facts.terminal_evidence_sha256) or
        isZeroDigest(facts.output_sha256))
    {
        return Error.InvalidResponse;
    }

    var id: [completion_id_bytes]u8 = undefined;
    @memcpy(id[0..completion_id_prefix.len], completion_id_prefix);
    const handle_hex = std.fmt.bytesToHex(facts.handle_sha256, .lower);
    @memcpy(id[completion_id_prefix.len..], &handle_hex);
    const request_hex = std.fmt.bytesToHex(
        facts.request_sha256,
        .lower,
    );
    const response_hex = std.fmt.bytesToHex(
        facts.response_sha256,
        .lower,
    );
    const terminal_hex = std.fmt.bytesToHex(
        facts.terminal_evidence_sha256,
        .lower,
    );
    const output_hex = std.fmt.bytesToHex(
        facts.output_sha256,
        .lower,
    );
    const choice = ChoiceJsonV1{
        .index = 0,
        .message = .{
            .role = "assistant",
            .content = facts.content_utf8,
        },
        .finish_reason = "length",
    };
    const choices = [_]ChoiceJsonV1{choice};
    const completion_tokens: u32 = @intCast(facts.output_tokens.len);
    const total_tokens = std.math.add(
        u32,
        facts.prompt_tokens,
        completion_tokens,
    ) catch return Error.InvalidResponse;
    return encodeJson(.{
        .id = id[0..],
        .object = "chat.completion",
        .created = @as(u64, 0),
        .model = facts.model_id,
        .choices = choices[0..],
        .usage = .{
            .prompt_tokens = facts.prompt_tokens,
            .completion_tokens = completion_tokens,
            .total_tokens = total_tokens,
        },
        .glacier = .{
            .schema = schema_v1,
            .request_sha256 = request_hex[0..],
            .response_sha256 = response_hex[0..],
            .terminal_evidence_sha256 = terminal_hex[0..],
            .output_sha256 = output_hex[0..],
            .output_tokens = facts.output_tokens,
        },
    }, destination);
}

pub fn decodeCompletionV1(
    allocator: std.mem.Allocator,
    body: []const u8,
) Error!CompletionV1 {
    if (body.len == 0 or body.len > response_body_max_bytes)
        return Error.InvalidResponse;
    var parsed = std.json.parseFromSlice(
        CompletionJsonV1,
        allocator,
        body,
        strictResponseOptions(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.InvalidResponse,
    };
    defer parsed.deinit();

    const value = parsed.value;
    const expected_total_tokens = std.math.add(
        u32,
        value.usage.prompt_tokens,
        value.usage.completion_tokens,
    ) catch return Error.InvalidResponse;
    if (value.id.len != completion_id_bytes or
        !std.mem.startsWith(
            u8,
            value.id,
            completion_id_prefix,
        ) or
        !std.mem.eql(u8, value.object, "chat.completion") or
        value.created != 0 or
        value.choices.len != 1 or
        value.choices[0].index != 0 or
        !std.mem.eql(
            u8,
            value.choices[0].message.role,
            "assistant",
        ) or
        !std.mem.eql(
            u8,
            value.choices[0].finish_reason,
            "length",
        ) or
        !std.mem.eql(u8, value.glacier.schema, schema_v1))
    {
        return Error.InvalidResponse;
    }
    try validateModelId(value.model);
    const content = value.choices[0].message.content;
    if (content.len == 0 or
        content.len > output_max_tokens or
        !std.unicode.utf8ValidateSlice(content) or
        value.glacier.output_tokens.len != content.len or
        value.usage.prompt_tokens == 0 or
        value.usage.completion_tokens != content.len or
        value.usage.total_tokens != expected_total_tokens)
    {
        return Error.InvalidResponse;
    }
    for (value.glacier.output_tokens, content) |token, byte| {
        const token_byte = std.math.cast(u8, token) orelse
            return Error.InvalidResponse;
        if (token_byte != byte) return Error.InvalidResponse;
    }

    const handle_sha256 =
        try parseDigest(value.id[completion_id_prefix.len..]);
    if (isZeroDigest(handle_sha256)) return Error.InvalidResponse;
    var result: CompletionV1 = .{
        .id = undefined,
        .model_id = undefined,
        .content_bytes = @intCast(content.len),
        .output_count = @intCast(
            value.glacier.output_tokens.len,
        ),
        .prompt_tokens = value.usage.prompt_tokens,
        .request_sha256 = try parseDigest(value.glacier.request_sha256),
        .response_sha256 = try parseDigest(value.glacier.response_sha256),
        .terminal_evidence_sha256 = try parseDigest(
            value.glacier.terminal_evidence_sha256,
        ),
        .output_sha256 = try parseDigest(value.glacier.output_sha256),
    };
    if (isZeroDigest(result.request_sha256) or
        isZeroDigest(result.response_sha256) or
        isZeroDigest(result.terminal_evidence_sha256) or
        isZeroDigest(result.output_sha256))
    {
        return Error.InvalidResponse;
    }
    @memcpy(&result.id, value.id);
    @memcpy(&result.model_id, value.model);
    @memcpy(result.content[0..content.len], content);
    @memcpy(
        result.output_tokens[0..value.glacier.output_tokens.len],
        value.glacier.output_tokens,
    );
    return result;
}

pub fn encodeErrorV1(
    api_error: ApiErrorV1,
    destination: []u8,
) Error![]const u8 {
    var request_hex: [64]u8 = undefined;
    const request_sha256: ?[]const u8 =
        if (api_error.request_sha256) |digest| blk: {
            if (isZeroDigest(digest)) return Error.InvalidResponse;
            request_hex =
                std.fmt.bytesToHex(digest, .lower);
            break :blk request_hex[0..];
        } else null;
    if (api_error.retry != retryDispositionV1(api_error.code))
        return Error.InvalidResponse;
    return encodeJson(.{
        .@"error" = .{
            .schema = schema_v1,
            .code = api_error.code,
            .message = errorMessageV1(api_error.code),
            .retry = api_error.retry,
            .request_sha256 = request_sha256,
        },
    }, destination);
}

pub fn decodeErrorV1(
    allocator: std.mem.Allocator,
    body: []const u8,
) Error!ApiErrorV1 {
    if (body.len == 0 or body.len > response_body_max_bytes)
        return Error.InvalidResponse;
    var parsed = std.json.parseFromSlice(
        ErrorJsonV1,
        allocator,
        body,
        strictResponseOptions(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.InvalidResponse,
    };
    defer parsed.deinit();

    const details = parsed.value.@"error";
    if (!std.mem.eql(u8, details.schema, schema_v1) or
        !std.mem.eql(
            u8,
            details.message,
            errorMessageV1(details.code),
        ) or
        details.retry != retryDispositionV1(details.code))
    {
        return Error.InvalidResponse;
    }
    return .{
        .code = details.code,
        .retry = details.retry,
        .request_sha256 = if (details.request_sha256) |value|
            try parseDigest(value)
        else
            null,
    };
}

pub fn retryDispositionV1(
    code: ErrorCodeV1,
) RetryDispositionV1 {
    return switch (code) {
        .service_capacity,
        .scheduler_rejected,
        .runtime_unavailable,
        .out_of_memory,
        => .same_request_after_backoff,
        .recovery_required,
        .service_closed,
        .fail_stop_required,
        .state_drift,
        .sequence_exhausted,
        .internal_error,
        => .inspect_runtime,
        else => .never,
    };
}

pub fn httpStatusV1(code: ErrorCodeV1) std.http.Status {
    return switch (code) {
        .invalid_request, .unsupported_profile => .bad_request,
        .request_too_large => .payload_too_large,
        .route_not_found, .model_not_found => .not_found,
        .method_not_allowed => .method_not_allowed,
        .unsupported_media_type => .unsupported_media_type,
        .http_version_not_supported => .http_version_not_supported,
        .missing_content_length => .length_required,
        .header_too_large => .request_header_fields_too_large,
        .idempotency_conflict, .request_cancelled => .conflict,
        .service_capacity, .scheduler_rejected => .too_many_requests,
        .execution_failed,
        .non_utf8_model_output,
        .state_drift,
        .internal_error,
        => .internal_server_error,
        .recovery_required,
        .service_closed,
        .runtime_unavailable,
        .fail_stop_required,
        .sequence_exhausted,
        .out_of_memory,
        => .service_unavailable,
    };
}

pub fn errorMessageV1(code: ErrorCodeV1) []const u8 {
    return switch (code) {
        .invalid_request => "request is malformed",
        .request_too_large => "request exceeds the bounded profile",
        .route_not_found => "route is not available",
        .method_not_allowed => "method is not available for this route",
        .unsupported_media_type => "content type must be application/json",
        .http_version_not_supported => "HTTP/1.1 is required",
        .missing_content_length => "a bounded content length is required",
        .header_too_large => "request headers exceed the bounded profile",
        .unsupported_profile => "request uses an unsupported R1 option",
        .model_not_found => "requested model is not loaded",
        .idempotency_conflict => "idempotency key conflicts with retained intent",
        .service_capacity => "service retention or active capacity is full",
        .scheduler_rejected => "scheduler rejected admission",
        .request_cancelled => "retained request has no public response",
        .execution_failed => "model execution failed",
        .non_utf8_model_output => "terminal model output is not strict UTF-8",
        .recovery_required => "runtime recovery is required",
        .service_closed => "service is closed",
        .runtime_unavailable => "runtime is unavailable",
        .fail_stop_required => "runtime entered fail-stop",
        .state_drift => "runtime evidence is inconsistent",
        .sequence_exhausted => "runtime sequence is exhausted",
        .out_of_memory => "bounded runtime allocation failed",
        .internal_error => "internal transport error",
    };
}

fn validateRequest(
    request: RequestV1,
    expected_model_id: ?[]const u8,
) Error!void {
    try validateModelId(request.model_id);
    if (expected_model_id) |expected| {
        if (!std.mem.eql(u8, request.model_id, expected))
            return Error.ModelNotFound;
    }
    if (request.tenant_key == 0) return Error.InvalidTenantKey;
    try validateIdempotencyKey(request.idempotency_key);
    if (request.prompt_utf8.len == 0)
        return Error.InvalidRequest;
    if (request.prompt_utf8.len > prompt_max_bytes)
        return Error.RequestTooLarge;
    if (!std.unicode.utf8ValidateSlice(request.prompt_utf8))
        return Error.InvalidUtf8;
    if (request.max_new_tokens == 0 or
        request.max_new_tokens > output_max_tokens)
    {
        return Error.UnsupportedProfile;
    }
}

fn validateIdempotencyKey(key: []const u8) Error!void {
    if (key.len == 0 or
        key.len > idempotency_key_max_bytes)
    {
        return Error.InvalidIdempotencyKey;
    }
    for (key) |byte| {
        if (byte < 0x21 or byte > 0x7e)
            return Error.InvalidIdempotencyKey;
    }
}

fn validateModelId(model_id: []const u8) Error!void {
    if (model_id.len != model_id_bytes or
        !std.mem.startsWith(u8, model_id, model_id_prefix))
    {
        return Error.ModelNotFound;
    }
    const digest =
        parseDigest(model_id[model_id_prefix.len..]) catch
            return Error.ModelNotFound;
    if (isZeroDigest(digest)) return Error.ModelNotFound;
}

fn parseCanonicalU64(
    bytes: []const u8,
    allow_zero: bool,
) error{InvalidInteger}!u64 {
    if (bytes.len == 0 or
        (bytes.len > 1 and bytes[0] == '0'))
    {
        return error.InvalidInteger;
    }
    for (bytes) |byte| {
        if (byte < '0' or byte > '9')
            return error.InvalidInteger;
    }
    const value = std.fmt.parseInt(u64, bytes, 10) catch
        return error.InvalidInteger;
    if (!allow_zero and value == 0)
        return error.InvalidInteger;
    return value;
}

fn parseDigest(bytes: []const u8) Error!Digest {
    if (bytes.len != 64) return Error.InvalidResponse;
    for (bytes) |byte| {
        if (!std.ascii.isDigit(byte) and
            (byte < 'a' or byte > 'f'))
        {
            return Error.InvalidResponse;
        }
    }
    var digest: Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, bytes) catch
        return Error.InvalidResponse;
    return digest;
}

fn strictResponseOptions() std.json.ParseOptions {
    return .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = response_body_max_bytes,
    };
}

fn encodeJson(value: anytype, destination: []u8) Error![]const u8 {
    var writer = std.Io.Writer.fixed(destination);
    std.json.Stringify.value(value, .{}, &writer) catch
        return Error.BufferTooSmall;
    return writer.buffered();
}

fn hashU16(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: u16,
) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    hasher.update(&bytes);
}

fn hashU32(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hasher.update(&bytes);
}

fn hashU64(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn isZeroDigest(digest: Digest) bool {
    for (digest) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

test "bounded request codec is strict and canonical" {
    const binding = [_]u8{0x41} ** 32;
    const model_id = modelIdV1(binding);
    const request: RequestV1 = .{
        .model_id = &model_id,
        .tenant_key = 7,
        .idempotency_key = "request-a",
        .prompt_utf8 = "hello",
        .max_new_tokens = 4,
        .deadline_tick = 11,
    };
    var body: [request_body_max_bytes]u8 = undefined;
    const encoded = try encodeRequestV1(request, &body);
    var parsed = try decodeRequestV1(
        std.testing.allocator,
        encoded,
        .{
            .idempotency_key = "request-a",
            .tenant_key = "7",
            .deadline_tick = "11",
        },
        &model_id,
    );
    defer parsed.deinit();
    try std.testing.expectEqual(request.tenant_key, parsed.request.tenant_key);
    try std.testing.expectEqualStrings(
        request.prompt_utf8,
        parsed.request.prompt_utf8,
    );
    try std.testing.expectEqual(
        try requestSha256V1(request),
        try requestSha256V1(parsed.request),
    );

    const duplicate =
        "{\"model\":\"" ++ ("a" ** model_id_bytes) ++
        "\",\"model\":\"x\",\"messages\":[],\"max_tokens\":1,\"stream\":false}";
    try std.testing.expectError(
        Error.InvalidRequest,
        decodeRequestV1(
            std.testing.allocator,
            duplicate,
            .{
                .idempotency_key = "request-a",
                .tenant_key = "7",
            },
            &model_id,
        ),
    );
}

test "model list and completion codecs retain exact correlation" {
    const binding = [_]u8{0x21} ** 32;
    const model_id = modelIdV1(binding);
    var body: [response_body_max_bytes]u8 = undefined;
    const models_json =
        try encodeModelListV1(&model_id, binding, &body);
    const models = try decodeModelListV1(
        std.testing.allocator,
        models_json,
    );
    try std.testing.expectEqual(binding, models.model_binding_sha256);

    const handle = [_]u8{0x31} ** 32;
    const request_root = [_]u8{0x32} ** 32;
    const response_root = [_]u8{0x33} ** 32;
    const terminal_root = [_]u8{0x34} ** 32;
    const output_root = [_]u8{0x35} ** 32;
    const tokens = [_]u32{ 'o', 'k' };
    const completion_json = try encodeCompletionV1(.{
        .model_id = &model_id,
        .content_utf8 = "ok",
        .output_tokens = &tokens,
        .prompt_tokens = 3,
        .handle_sha256 = handle,
        .request_sha256 = request_root,
        .response_sha256 = response_root,
        .terminal_evidence_sha256 = terminal_root,
        .output_sha256 = output_root,
    }, &body);
    const completion = try decodeCompletionV1(
        std.testing.allocator,
        completion_json,
    );
    try std.testing.expectEqualStrings("ok", completion.contentSlice());
    try std.testing.expectEqual(request_root, completion.request_sha256);
    try std.testing.expectEqual(response_root, completion.response_sha256);
    try std.testing.expectEqualSlices(
        u32,
        &tokens,
        completion.outputSlice(),
    );

    const overflow_choice = ChoiceJsonV1{
        .index = 0,
        .message = .{
            .role = "assistant",
            .content = "ok",
        },
        .finish_reason = "length",
    };
    const overflow_choices = [_]ChoiceJsonV1{
        overflow_choice,
    };
    const request_hex = std.fmt.bytesToHex(
        request_root,
        .lower,
    );
    const response_hex = std.fmt.bytesToHex(
        response_root,
        .lower,
    );
    const terminal_hex = std.fmt.bytesToHex(
        terminal_root,
        .lower,
    );
    const output_hex = std.fmt.bytesToHex(
        output_root,
        .lower,
    );
    const overflow_json = try encodeJson(.{
        .id = completion.id[0..],
        .object = "chat.completion",
        .created = @as(u64, 0),
        .model = model_id[0..],
        .choices = overflow_choices[0..],
        .usage = .{
            .prompt_tokens = std.math.maxInt(u32),
            .completion_tokens = @as(u32, 2),
            .total_tokens = @as(u32, 0),
        },
        .glacier = .{
            .schema = schema_v1,
            .request_sha256 = request_hex[0..],
            .response_sha256 = response_hex[0..],
            .terminal_evidence_sha256 = terminal_hex[0..],
            .output_sha256 = output_hex[0..],
            .output_tokens = tokens[0..],
        },
    }, &body);
    try std.testing.expectError(
        Error.InvalidResponse,
        decodeCompletionV1(
            std.testing.allocator,
            overflow_json,
        ),
    );
}
