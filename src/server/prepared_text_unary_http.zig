//! Thin synchronous adapter from bounded HTTP/1.1 JSON to `ServiceV1`.
//!
//! This module owns no execution records. It decodes a complete request,
//! delegates admission and driving to `ServiceV1`, and renders only sealed
//! terminal output.

const std = @import("std");
const protocol = @import("../prepared_text_unary_http_v1.zig");
const unary = @import("../prepared_text_unary_service.zig");

pub const header_max_bytes = protocol.header_max_bytes;

const response_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = protocol.json_content_type },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
};

pub const RuntimeV1 = struct {
    service: *unary.ServiceV1,
    model_binding_sha256: protocol.Digest,
    model_id: [protocol.model_id_bytes]u8,
    request_mutex: std.Thread.Mutex = .{},
    accepting_completions: bool = true,
};

pub const WorkspaceV1 = struct {
    body: [protocol.request_body_max_bytes]u8,
    body_reader: [4096]u8,
    parser: [protocol.parser_workspace_bytes]u8,
    response: [protocol.response_body_max_bytes]u8,
    idempotency_key: [protocol.idempotency_key_max_bytes]u8,
    tenant_key: [20]u8,
    deadline_tick: [20]u8,
    output: [protocol.output_max_tokens]u8,
};

const OwnedHeaderFactsV1 = struct {
    idempotency_key_bytes: usize,
    tenant_key_bytes: usize,
    deadline_tick_bytes: usize,
    has_deadline: bool,

    fn facts(
        self: OwnedHeaderFactsV1,
        workspace: *const WorkspaceV1,
    ) protocol.HeaderFactsV1 {
        return .{
            .idempotency_key = workspace.idempotency_key[0..self.idempotency_key_bytes],
            .tenant_key = workspace.tenant_key[0..self.tenant_key_bytes],
            .deadline_tick = if (self.has_deadline)
                workspace.deadline_tick[0..self.deadline_tick_bytes]
            else
                null,
        };
    }
};

const HeaderError = error{
    InvalidHeader,
    MissingContentLength,
    UnsupportedMediaType,
    RequestTooLarge,
};

const TerminalError = error{
    RequestCancelled,
    ExecutionFailed,
    NonUtf8Output,
};

pub fn initV1(
    service: *unary.ServiceV1,
    binding_sha256: protocol.Digest,
) protocol.Error!RuntimeV1 {
    if (!std.mem.eql(
        u8,
        &service.binding.binding_sha256,
        &binding_sha256,
    )) {
        return protocol.Error.InvalidRequest;
    }
    const model_id = protocol.modelIdV1(binding_sha256);
    _ = protocol.requestSha256V1(.{
        .model_id = &model_id,
        .tenant_key = 1,
        .idempotency_key = "runtime-init",
        .prompt_utf8 = "x",
        .max_new_tokens = 1,
    }) catch return protocol.Error.InvalidRequest;
    return .{
        .service = service,
        .model_binding_sha256 = binding_sha256,
        .model_id = model_id,
    };
}

/// Closes only HTTP completion admission. A request already admitted to the
/// unary service finishes under the same mutex before this call returns.
pub fn beginDrainV1(runtime: *RuntimeV1) bool {
    runtime.request_mutex.lock();
    defer runtime.request_mutex.unlock();
    const was_accepting = runtime.accepting_completions;
    runtime.accepting_completions = false;
    return was_accepting;
}

pub fn acceptingCompletionsV1(runtime: *RuntimeV1) bool {
    runtime.request_mutex.lock();
    defer runtime.request_mutex.unlock();
    return runtime.accepting_completions;
}

pub fn serveRequestV1(
    runtime: *RuntimeV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
) !void {
    if (request.head.version != .@"HTTP/1.1") {
        return respondApiError(
            request,
            workspace,
            .http_version_not_supported,
            null,
        );
    }

    if (std.mem.eql(
        u8,
        request.head.target,
        protocol.models_path_v1,
    )) {
        if (request.head.method != .GET) {
            return respondApiError(
                request,
                workspace,
                .method_not_allowed,
                null,
            );
        }
        return serveModelsV1(runtime, request, workspace);
    }

    if (std.mem.eql(
        u8,
        request.head.target,
        protocol.completions_path_v1,
    )) {
        if (request.head.method != .POST) {
            return respondApiError(
                request,
                workspace,
                .method_not_allowed,
                null,
            );
        }
        return serveCompletionV1(runtime, request, workspace);
    }

    return respondApiError(
        request,
        workspace,
        .route_not_found,
        null,
    );
}

fn serveModelsV1(
    runtime: *RuntimeV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
) !void {
    validateModelListHeaders(request) catch {
        request.head.expect = null;
        return respondApiError(
            request,
            workspace,
            .invalid_request,
            null,
        );
    };
    const body = protocol.encodeModelListV1(
        &runtime.model_id,
        runtime.model_binding_sha256,
        &workspace.response,
    ) catch {
        return respondApiError(
            request,
            workspace,
            .internal_error,
            null,
        );
    };
    try request.respond(body, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &response_headers,
    });
}

fn serveCompletionV1(
    runtime: *RuntimeV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
) !void {
    const content_length_u64 = request.head.content_length orelse {
        request.head.expect = null;
        return respondApiError(
            request,
            workspace,
            .missing_content_length,
            null,
        );
    };
    if (content_length_u64 == 0 or
        content_length_u64 > protocol.request_body_max_bytes)
    {
        request.head.expect = null;
        return respondApiError(
            request,
            workspace,
            .request_too_large,
            null,
        );
    }

    const owned_headers = collectCompletionHeaders(
        request,
        workspace,
        content_length_u64,
    ) catch |err| {
        request.head.expect = null;
        return respondApiError(
            request,
            workspace,
            switch (err) {
                error.MissingContentLength => .missing_content_length,
                error.UnsupportedMediaType => .unsupported_media_type,
                error.RequestTooLarge => .request_too_large,
                error.InvalidHeader => .invalid_request,
            },
            null,
        );
    };

    const content_length: usize = @intCast(content_length_u64);
    const body_reader =
        request.readerExpectNone(&workspace.body_reader);
    body_reader.readSliceAll(
        workspace.body[0..content_length],
    ) catch {
        return respondApiError(
            request,
            workspace,
            .invalid_request,
            null,
        );
    };

    var parser = std.heap.FixedBufferAllocator.init(
        &workspace.parser,
    );
    var decoded = protocol.decodeRequestV1(
        parser.allocator(),
        workspace.body[0..content_length],
        owned_headers.facts(workspace),
        &runtime.model_id,
    ) catch |err| {
        return respondApiError(
            request,
            workspace,
            mapProtocolError(err),
            null,
        );
    };
    defer decoded.deinit();

    const request_sha256 =
        protocol.requestSha256V1(decoded.request) catch {
            return respondApiError(
                request,
                workspace,
                .invalid_request,
                null,
            );
        };
    const idempotency_key_sha256 =
        protocol.idempotencyKeySha256V1(
            decoded.request.idempotency_key,
        ) catch {
            return respondApiError(
                request,
                workspace,
                .invalid_request,
                null,
            );
        };

    runtime.request_mutex.lock();
    defer runtime.request_mutex.unlock();

    if (!runtime.accepting_completions) {
        return respondApiError(
            request,
            workspace,
            .service_closed,
            request_sha256,
        );
    }

    const admission = runtime.service.admitV1(.{
        .tenant_key = decoded.request.tenant_key,
        .idempotency_key_sha256 = idempotency_key_sha256,
        .prompt_utf8 = decoded.request.prompt_utf8,
        .max_new_tokens = decoded.request.max_new_tokens,
        .deadline_tick = decoded.request.deadline_tick,
    }) catch |err| {
        return respondApiError(
            request,
            workspace,
            mapServiceError(err),
            request_sha256,
        );
    };

    const handle = switch (admission) {
        .accepted => |receipt| receipt.handle,
        .existing => |existing| switch (existing.state) {
            .active, .completed => existing.handle,
            .recovery_required => {
                return respondApiError(
                    request,
                    workspace,
                    .recovery_required,
                    request_sha256,
                );
            },
            .cancelled => {
                return respondApiError(
                    request,
                    workspace,
                    .request_cancelled,
                    request_sha256,
                );
            },
            .failed => {
                return respondApiError(
                    request,
                    workspace,
                    .execution_failed,
                    request_sha256,
                );
            },
        },
        .rejected => |rejection| {
            return respondApiError(
                request,
                workspace,
                switch (rejection) {
                    .service_capacity => .service_capacity,
                    .scheduler => .scheduler_rejected,
                },
                request_sha256,
            );
        },
        .conflict => {
            return respondApiError(
                request,
                workspace,
                .idempotency_conflict,
                request_sha256,
            );
        },
        .recovery_required => {
            return respondApiError(
                request,
                workspace,
                .recovery_required,
                request_sha256,
            );
        },
    };

    const response = awaitResponseV1(
        runtime.service,
        handle,
    ) catch |err| {
        return respondApiError(
            request,
            workspace,
            mapAwaitError(err),
            request_sha256,
        );
    };

    const output_count: usize = response.output_count;
    if (output_count == 0 or
        output_count > protocol.output_max_tokens)
    {
        return respondApiError(
            request,
            workspace,
            .state_drift,
            request_sha256,
        );
    }
    for (
        response.output_tokens[0..output_count],
        workspace.output[0..output_count],
    ) |token, *byte| {
        byte.* = std.math.cast(u8, token) orelse {
            return respondApiError(
                request,
                workspace,
                .non_utf8_model_output,
                request_sha256,
            );
        };
    }
    const content = workspace.output[0..output_count];
    if (!std.unicode.utf8ValidateSlice(content)) {
        return respondApiError(
            request,
            workspace,
            .non_utf8_model_output,
            request_sha256,
        );
    }

    const body = protocol.encodeCompletionV1(.{
        .model_id = &runtime.model_id,
        .content_utf8 = content,
        .output_tokens = response.output_tokens[0..output_count],
        .prompt_tokens = @intCast(
            response.admission.prompt_receipt.token_count,
        ),
        .handle_sha256 = response.handle.handle_sha256,
        .request_sha256 = request_sha256,
        .response_sha256 = response.response_sha256,
        .terminal_evidence_sha256 = response.terminal.evidence_sha256,
        .output_sha256 = response.terminal.result.output_sha256,
    }, &workspace.response) catch |err| {
        return respondApiError(
            request,
            workspace,
            if (err == protocol.Error.NonUtf8Output)
                .non_utf8_model_output
            else
                .internal_error,
            request_sha256,
        );
    };
    try request.respond(body, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &response_headers,
    });
}

fn awaitResponseV1(
    service: *unary.ServiceV1,
    handle: unary.HandleV1,
) (unary.Error || TerminalError)!unary.ResponseV1 {
    var drive_calls: usize = 0;
    while (drive_calls <= unary.maximum_output_tokens) : (drive_calls += 1) {
        const status = try service.statusV1(handle);
        switch (status) {
            .completed => return try service.responseV1(handle),
            .cancelled => return TerminalError.RequestCancelled,
            .failed => return TerminalError.ExecutionFailed,
            .active => {},
        }
        if (drive_calls == unary.maximum_output_tokens)
            return unary.Error.RuntimeUnavailable;
        const drive = try service.driveNextV1();
        switch (drive) {
            .idle => return unary.Error.RuntimeUnavailable,
            .progressed, .completed => {},
            .request_failed => |failed_handle| {
                if (std.meta.eql(failed_handle, handle))
                    return TerminalError.ExecutionFailed;
            },
            .recovery_required => return unary.Error.RecoveryRequired,
        }
    }
    unreachable;
}

fn validateModelListHeaders(
    request: *const std.http.Server.Request,
) HeaderError!void {
    if (request.head.transfer_encoding != .none or
        request.head.transfer_compression != .identity or
        request.head.expect != null or
        request.head.content_length != null)
    {
        return HeaderError.InvalidHeader;
    }
    var host_count: u8 = 0;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            if (host_count != 0)
                return HeaderError.InvalidHeader;
            host_count = 1;
            if (header.value.len == 0)
                return HeaderError.InvalidHeader;
        } else if (forbiddenFramingHeader(header.name)) {
            return HeaderError.InvalidHeader;
        }
    }
    if (host_count != 1) return HeaderError.InvalidHeader;
}

fn collectCompletionHeaders(
    request: *const std.http.Server.Request,
    workspace: *WorkspaceV1,
    expected_content_length: u64,
) HeaderError!OwnedHeaderFactsV1 {
    if (request.head.transfer_encoding != .none or
        request.head.transfer_compression != .identity or
        request.head.expect != null)
    {
        return HeaderError.InvalidHeader;
    }

    var host_count: u8 = 0;
    var content_type_count: u8 = 0;
    var content_length_count: u8 = 0;
    var idempotency_count: u8 = 0;
    var tenant_count: u8 = 0;
    var deadline_count: u8 = 0;
    var result: OwnedHeaderFactsV1 = .{
        .idempotency_key_bytes = 0,
        .tenant_key_bytes = 0,
        .deadline_tick_bytes = 0,
        .has_deadline = false,
    };

    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            if (host_count != 0)
                return HeaderError.InvalidHeader;
            host_count = 1;
            if (header.value.len == 0)
                return HeaderError.InvalidHeader;
        } else if (std.ascii.eqlIgnoreCase(
            header.name,
            "content-type",
        )) {
            if (content_type_count != 0)
                return HeaderError.InvalidHeader;
            content_type_count = 1;
            if (!std.mem.eql(
                u8,
                header.value,
                protocol.json_content_type,
            )) {
                return HeaderError.UnsupportedMediaType;
            }
        } else if (std.ascii.eqlIgnoreCase(
            header.name,
            "content-length",
        )) {
            if (content_length_count != 0)
                return HeaderError.InvalidHeader;
            content_length_count = 1;
            if (!canonicalContentLength(
                header.value,
                expected_content_length,
            )) {
                return HeaderError.InvalidHeader;
            }
        } else if (std.ascii.eqlIgnoreCase(
            header.name,
            protocol.idempotency_header,
        )) {
            if (idempotency_count != 0)
                return HeaderError.InvalidHeader;
            idempotency_count = 1;
            result.idempotency_key_bytes = try copyHeader(
                &workspace.idempotency_key,
                header.value,
            );
        } else if (std.ascii.eqlIgnoreCase(
            header.name,
            protocol.tenant_header,
        )) {
            if (tenant_count != 0)
                return HeaderError.InvalidHeader;
            tenant_count = 1;
            result.tenant_key_bytes = try copyHeader(
                &workspace.tenant_key,
                header.value,
            );
        } else if (std.ascii.eqlIgnoreCase(
            header.name,
            protocol.deadline_header,
        )) {
            if (deadline_count != 0)
                return HeaderError.InvalidHeader;
            deadline_count = 1;
            result.deadline_tick_bytes = try copyHeader(
                &workspace.deadline_tick,
                header.value,
            );
            result.has_deadline = true;
        } else if (forbiddenFramingHeader(header.name)) {
            return HeaderError.InvalidHeader;
        }
    }
    if (host_count != 1 or
        content_type_count != 1 or
        content_length_count != 1 or
        idempotency_count != 1 or
        tenant_count != 1 or
        deadline_count > 1)
    {
        return HeaderError.InvalidHeader;
    }
    return result;
}

fn copyHeader(
    destination: []u8,
    value: []const u8,
) HeaderError!usize {
    if (value.len == 0 or value.len > destination.len)
        return HeaderError.RequestTooLarge;
    @memcpy(destination[0..value.len], value);
    return value.len;
}

fn canonicalContentLength(
    value: []const u8,
    expected: u64,
) bool {
    if (value.len == 0 or
        (value.len > 1 and value[0] == '0'))
    {
        return false;
    }
    for (value) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    const parsed = std.fmt.parseInt(u64, value, 10) catch
        return false;
    return parsed == expected;
}

fn forbiddenFramingHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "content-encoding") or
        std.ascii.eqlIgnoreCase(name, "expect") or
        std.ascii.eqlIgnoreCase(name, "upgrade") or
        std.ascii.eqlIgnoreCase(name, "trailer");
}

fn respondApiError(
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
    code: protocol.ErrorCodeV1,
    request_sha256: ?protocol.Digest,
) !void {
    request.head.expect = null;
    const body = try protocol.encodeErrorV1(.{
        .code = code,
        .retry = protocol.retryDispositionV1(code),
        .request_sha256 = request_sha256,
    }, &workspace.response);
    try request.respond(body, .{
        .status = protocol.httpStatusV1(code),
        .keep_alive = false,
        .extra_headers = &response_headers,
    });
}

fn mapProtocolError(
    err: protocol.Error,
) protocol.ErrorCodeV1 {
    return switch (err) {
        protocol.Error.RequestTooLarge => .request_too_large,
        protocol.Error.ModelNotFound => .model_not_found,
        protocol.Error.UnsupportedProfile => .unsupported_profile,
        protocol.Error.OutOfMemory => .out_of_memory,
        protocol.Error.BufferTooSmall => .internal_error,
        protocol.Error.InvalidRequest,
        protocol.Error.InvalidHeader,
        protocol.Error.InvalidIdempotencyKey,
        protocol.Error.InvalidTenantKey,
        protocol.Error.InvalidDeadline,
        protocol.Error.InvalidUtf8,
        => .invalid_request,
        protocol.Error.NonUtf8Output => .non_utf8_model_output,
        protocol.Error.InvalidResponse => .internal_error,
    };
}

fn mapServiceError(
    err: unary.Error,
) protocol.ErrorCodeV1 {
    return switch (err) {
        unary.Error.InvalidRequest => .invalid_request,
        unary.Error.RequestTooLarge => .request_too_large,
        unary.Error.OutOfMemory => .out_of_memory,
        unary.Error.SequenceExhausted => .sequence_exhausted,
        unary.Error.ServiceClosed => .service_closed,
        unary.Error.RuntimeUnavailable => .runtime_unavailable,
        unary.Error.RecoveryRequired => .recovery_required,
        unary.Error.FailStopRequired => .fail_stop_required,
        unary.Error.StateDrift,
        unary.Error.InvalidState,
        unary.Error.InvalidConfiguration,
        unary.Error.InvalidModelBinding,
        unary.Error.StaleHandle,
        unary.Error.ActiveRequests,
        => .state_drift,
        unary.Error.ResponseNotReady => .runtime_unavailable,
        unary.Error.NoResponse => .request_cancelled,
    };
}

fn mapAwaitError(
    err: (unary.Error || TerminalError),
) protocol.ErrorCodeV1 {
    return switch (err) {
        TerminalError.RequestCancelled => .request_cancelled,
        TerminalError.ExecutionFailed => .execution_failed,
        TerminalError.NonUtf8Output => .non_utf8_model_output,
        unary.Error.InvalidRequest => .invalid_request,
        unary.Error.RequestTooLarge => .request_too_large,
        unary.Error.OutOfMemory => .out_of_memory,
        unary.Error.SequenceExhausted => .sequence_exhausted,
        unary.Error.ServiceClosed => .service_closed,
        unary.Error.FailStopRequired => .fail_stop_required,
        unary.Error.StateDrift,
        unary.Error.InvalidState,
        unary.Error.InvalidConfiguration,
        unary.Error.InvalidModelBinding,
        unary.Error.StaleHandle,
        unary.Error.ActiveRequests,
        => .state_drift,
        unary.Error.ResponseNotReady,
        unary.Error.RuntimeUnavailable,
        => .runtime_unavailable,
        unary.Error.NoResponse => .request_cancelled,
        unary.Error.RecoveryRequired => .recovery_required,
    };
}
