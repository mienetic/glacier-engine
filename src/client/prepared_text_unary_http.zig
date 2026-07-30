//! Retained bounded client for prepared-text unary HTTP/1.1.
//!
//! The client deliberately supports only loopback HTTP, one request per
//! connection, the two R1 routes, and identity transfer. Public results own
//! all protocol data; no result points into the reusable transport workspace.

const std = @import("std");
const protocol = @import("../prepared_text_unary_http_v1.zig");

pub const RequestV1 = protocol.RequestV1;
pub const ModelListV1 = protocol.ModelListV1;
pub const CompletionV1 = protocol.CompletionV1;
pub const ApiErrorV1 = protocol.ApiErrorV1;

const ipv4_loopback = "127.0.0.1";
const ipv6_loopback = "::1";
const uri_max_bytes = 128;
const transfer_buffer_bytes = 4096;

pub const Error = protocol.Error || error{
    InvalidConfiguration,
    NonLoopbackEndpoint,
    TransportUnavailable,
    TransportFailure,
    RedirectRejected,
    ResponseHeaderTooLarge,
    InvalidHttpResponse,
    InvalidHttpVersion,
    MissingContentLength,
    ResponseTooLarge,
    InvalidContentType,
    UnsupportedResponseEncoding,
    PersistentResponse,
    UnexpectedStatus,
    CorrelationMismatch,
    ModelMismatch,
    ContentMismatch,
    TokenCountMismatch,
};

/// Owned loopback authority. Host names and non-loopback addresses are not
/// accepted, so a caller cannot accidentally send prepared text off-host.
pub const EndpointV1 = struct {
    host_storage: [ipv4_loopback.len]u8 =
        [_]u8{0} ** ipv4_loopback.len,
    host_bytes: u8,
    port: u16,

    pub fn init(host_name: []const u8, port: u16) Error!EndpointV1 {
        if (port == 0) return Error.InvalidConfiguration;
        if (!std.mem.eql(u8, host_name, ipv4_loopback) and
            !std.mem.eql(u8, host_name, ipv6_loopback))
        {
            return Error.NonLoopbackEndpoint;
        }

        var result: EndpointV1 = .{
            .host_bytes = @intCast(host_name.len),
            .port = port,
        };
        @memcpy(result.host_storage[0..host_name.len], host_name);
        try result.validate();
        return result;
    }

    pub fn host(self: *const EndpointV1) Error![]const u8 {
        try self.validate();
        return self.host_storage[0..self.host_bytes];
    }

    fn isIpv6(self: *const EndpointV1) Error!bool {
        return std.mem.eql(
            u8,
            try self.host(),
            ipv6_loopback,
        );
    }

    fn validate(self: *const EndpointV1) Error!void {
        if (self.port == 0 or
            self.host_bytes > self.host_storage.len)
        {
            return Error.InvalidConfiguration;
        }
        const stored =
            self.host_storage[0..self.host_bytes];
        if (!std.mem.eql(u8, stored, ipv4_loopback) and
            !std.mem.eql(u8, stored, ipv6_loopback))
        {
            return Error.NonLoopbackEndpoint;
        }
    }
};

pub const ModelsResultV1 = union(enum) {
    ok: ModelListV1,
    api_error: ApiErrorV1,
};

pub const CompletionResultV1 = union(enum) {
    ok: CompletionV1,
    api_error: ApiErrorV1,
};

const ReceivedV1 = struct {
    status: std.http.Status,
    body: []const u8,
};

/// Retains the real `std.http.Client` while bounding all application-owned
/// request, response, parsing, URI, and transfer workspaces.
///
/// Calls are serialized because the workspaces are intentionally reused.
pub const ClientV1 = struct {
    http_client: std.http.Client,
    endpoint: EndpointV1,
    request_mutex: std.Thread.Mutex = .{},
    request_body: [protocol.request_body_max_bytes]u8 = undefined,
    response_body: [protocol.response_body_max_bytes]u8 = undefined,
    parser_workspace: [protocol.parser_workspace_bytes]u8 = undefined,
    transfer_buffer: [transfer_buffer_bytes]u8 = undefined,
    uri_buffer: [uri_max_bytes]u8 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        endpoint: EndpointV1,
    ) Error!ClientV1 {
        try endpoint.validate();
        var http_client: std.http.Client = .{
            .allocator = allocator,
        };
        http_client.read_buffer_size = protocol.header_max_bytes;
        http_client.write_buffer_size = protocol.header_max_bytes;
        return .{
            .http_client = http_client,
            .endpoint = endpoint,
        };
    }

    pub fn initLoopback(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
    ) Error!ClientV1 {
        return try init(
            allocator,
            try EndpointV1.init(host, port),
        );
    }

    pub fn deinit(self: *ClientV1) void {
        self.http_client.deinit();
        self.* = undefined;
    }

    /// Performs exactly one `GET /v1/models` request.
    pub fn listModelsV1(self: *ClientV1) Error!ModelsResultV1 {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();

        const uri = try self.uriFor(protocol.models_path_v1);
        var request = try self.openRequest(
            .GET,
            uri,
            false,
            &.{},
        );
        defer request.deinit();

        request.sendBodiless() catch
            return Error.TransportFailure;
        const received = try self.receiveResponse(&request);
        if (received.status == .ok) {
            var parser = std.heap.FixedBufferAllocator.init(
                &self.parser_workspace,
            );
            const models = try protocol.decodeModelListV1(
                parser.allocator(),
                received.body,
            );
            return .{ .ok = models };
        }

        const api_error = try self.decodeApiError(
            received.status,
            received.body,
            null,
        );
        return .{ .api_error = api_error };
    }

    /// Performs exactly one `POST /v1/chat/completions` request.
    pub fn completeV1(
        self: *ClientV1,
        input: RequestV1,
    ) Error!CompletionResultV1 {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();

        const request_sha256 = try protocol.requestSha256V1(input);
        const encoded = try protocol.encodeRequestV1(
            input,
            &self.request_body,
        );
        const body = self.request_body[0..encoded.len];

        var tenant_storage: [20]u8 = undefined;
        const tenant = std.fmt.bufPrint(
            &tenant_storage,
            "{d}",
            .{input.tenant_key},
        ) catch return Error.InvalidConfiguration;
        var deadline_storage: [20]u8 = undefined;
        const deadline = if (input.deadline_tick == 0)
            null
        else
            std.fmt.bufPrint(
                &deadline_storage,
                "{d}",
                .{input.deadline_tick},
            ) catch return Error.InvalidConfiguration;

        var headers: [3]std.http.Header = undefined;
        var header_count: usize = 0;
        headers[header_count] = .{
            .name = protocol.idempotency_header,
            .value = input.idempotency_key,
        };
        header_count += 1;
        headers[header_count] = .{
            .name = protocol.tenant_header,
            .value = tenant,
        };
        header_count += 1;
        if (deadline) |value| {
            headers[header_count] = .{
                .name = protocol.deadline_header,
                .value = value,
            };
            header_count += 1;
        }

        const uri = try self.uriFor(protocol.completions_path_v1);
        var request = try self.openRequest(
            .POST,
            uri,
            true,
            headers[0..header_count],
        );
        defer request.deinit();

        request.sendBodyComplete(body) catch
            return Error.TransportFailure;
        const received = try self.receiveResponse(&request);
        if (received.status == .ok) {
            var parser = std.heap.FixedBufferAllocator.init(
                &self.parser_workspace,
            );
            const completion = try protocol.decodeCompletionV1(
                parser.allocator(),
                received.body,
            );
            try validateCompletion(
                input,
                request_sha256,
                completion,
            );
            return .{ .ok = completion };
        }

        const api_error = try self.decodeApiError(
            received.status,
            received.body,
            request_sha256,
        );
        return .{ .api_error = api_error };
    }

    fn uriFor(
        self: *ClientV1,
        path: []const u8,
    ) Error!std.Uri {
        try self.endpoint.validate();
        const host_name = try self.endpoint.host();
        const uri_text = if (try self.endpoint.isIpv6())
            std.fmt.bufPrint(
                &self.uri_buffer,
                "http://[{s}]:{d}{s}",
                .{ host_name, self.endpoint.port, path },
            ) catch return Error.InvalidConfiguration
        else
            std.fmt.bufPrint(
                &self.uri_buffer,
                "http://{s}:{d}{s}",
                .{ host_name, self.endpoint.port, path },
            ) catch return Error.InvalidConfiguration;
        return std.Uri.parse(uri_text) catch
            return Error.InvalidConfiguration;
    }

    fn openRequest(
        self: *ClientV1,
        method: std.http.Method,
        uri: std.Uri,
        include_content_type: bool,
        extra_headers: []const std.http.Header,
    ) Error!std.http.Client.Request {
        var request = self.http_client.request(method, uri, .{
            .version = .@"HTTP/1.1",
            .handle_continue = true,
            .keep_alive = false,
            .redirect_behavior = .not_allowed,
            .headers = .{
                .authorization = .omit,
                .user_agent = .omit,
                .connection = .{ .override = "close" },
                .accept_encoding = .{ .override = "identity" },
                .content_type = if (include_content_type)
                    .{ .override = protocol.json_content_type }
                else
                    .omit,
            },
            .extra_headers = extra_headers,
        }) catch return Error.TransportUnavailable;

        for (&request.accept_encoding) |*enabled| {
            enabled.* = false;
        }
        request.accept_encoding[
            @intFromEnum(std.http.ContentEncoding.identity)
        ] = true;
        return request;
    }

    fn receiveResponse(
        self: *ClientV1,
        request: *std.http.Client.Request,
    ) Error!ReceivedV1 {
        var response = request.receiveHead(&.{}) catch |err| {
            return switch (err) {
                error.TooManyHttpRedirects => Error.RedirectRejected,
                error.HttpHeadersOversize => Error.ResponseHeaderTooLarge,
                error.HttpContentEncodingUnsupported => Error.UnsupportedResponseEncoding,
                error.ReadFailed, error.WriteFailed => Error.TransportFailure,
                else => Error.InvalidHttpResponse,
            };
        };
        const content_length = try validateResponseHead(
            response.head,
        );
        const status = response.head.status;
        const body_reader = response.reader(&self.transfer_buffer);
        body_reader.readSliceAll(
            self.response_body[0..content_length],
        ) catch |err| {
            return switch (err) {
                error.ReadFailed => Error.TransportFailure,
                else => Error.InvalidHttpResponse,
            };
        };
        const discarded = body_reader.discardRemaining() catch
            return Error.TransportFailure;
        if (discarded != 0) return Error.InvalidHttpResponse;
        return .{
            .status = status,
            .body = self.response_body[0..content_length],
        };
    }

    fn decodeApiError(
        self: *ClientV1,
        status: std.http.Status,
        body: []const u8,
        expected_request_sha256: ?protocol.Digest,
    ) Error!ApiErrorV1 {
        var parser = std.heap.FixedBufferAllocator.init(
            &self.parser_workspace,
        );
        const api_error = try protocol.decodeErrorV1(
            parser.allocator(),
            body,
        );
        if (protocol.httpStatusV1(api_error.code) != status)
            return Error.UnexpectedStatus;

        if (expected_request_sha256) |expected| {
            if (api_error.request_sha256) |actual| {
                if (!std.mem.eql(u8, &actual, &expected))
                    return Error.CorrelationMismatch;
            } else if (errorRequiresRequestRoot(api_error.code)) {
                return Error.CorrelationMismatch;
            }
        } else if (api_error.request_sha256 != null) {
            return Error.CorrelationMismatch;
        }
        return api_error;
    }
};

fn validateResponseHead(
    head: std.http.Client.Response.Head,
) Error!usize {
    if (head.bytes.len > protocol.header_max_bytes)
        return Error.ResponseHeaderTooLarge;
    if (head.version != .@"HTTP/1.1")
        return Error.InvalidHttpVersion;
    if (head.transfer_encoding != .none or
        head.content_encoding != .identity)
    {
        return Error.UnsupportedResponseEncoding;
    }
    if (head.keep_alive) return Error.PersistentResponse;
    if (head.location != null) return Error.RedirectRejected;

    const parsed_length = head.content_length orelse
        return Error.MissingContentLength;
    if (parsed_length == 0) return Error.InvalidHttpResponse;
    if (parsed_length > protocol.response_body_max_bytes)
        return Error.ResponseTooLarge;

    var content_length_count: u8 = 0;
    var content_type_count: u8 = 0;
    var connection_count: u8 = 0;
    var content_encoding_count: u8 = 0;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(
            header.name,
            "content-length",
        )) {
            content_length_count += 1;
            if (content_length_count != 1 or
                !canonicalContentLength(
                    header.value,
                    parsed_length,
                ))
            {
                return Error.InvalidHttpResponse;
            }
        } else if (std.ascii.eqlIgnoreCase(
            header.name,
            "content-type",
        )) {
            content_type_count += 1;
            if (content_type_count != 1 or
                !std.mem.eql(
                    u8,
                    header.value,
                    protocol.json_content_type,
                ))
            {
                return Error.InvalidContentType;
            }
        } else if (std.ascii.eqlIgnoreCase(
            header.name,
            "connection",
        )) {
            connection_count += 1;
            if (connection_count != 1 or
                !std.ascii.eqlIgnoreCase(
                    header.value,
                    "close",
                ))
            {
                return Error.PersistentResponse;
            }
        } else if (std.ascii.eqlIgnoreCase(
            header.name,
            "content-encoding",
        )) {
            content_encoding_count += 1;
            if (content_encoding_count != 1 or
                !std.ascii.eqlIgnoreCase(
                    header.value,
                    "identity",
                ))
            {
                return Error.UnsupportedResponseEncoding;
            }
        } else if (forbiddenResponseHeader(header.name)) {
            return Error.UnsupportedResponseEncoding;
        }
    }

    if (content_length_count != 1)
        return Error.MissingContentLength;
    if (content_type_count != 1)
        return Error.InvalidContentType;
    if (connection_count != 1)
        return Error.PersistentResponse;
    return @intCast(parsed_length);
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

fn forbiddenResponseHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "trailer") or
        std.ascii.eqlIgnoreCase(name, "upgrade");
}

fn errorRequiresRequestRoot(
    code: protocol.ErrorCodeV1,
) bool {
    return switch (code) {
        .idempotency_conflict,
        .service_capacity,
        .scheduler_rejected,
        .request_cancelled,
        .execution_failed,
        .non_utf8_model_output,
        .recovery_required,
        .service_closed,
        .runtime_unavailable,
        .fail_stop_required,
        .state_drift,
        .sequence_exhausted,
        .internal_error,
        => true,
        else => false,
    };
}

fn validateCompletion(
    input: RequestV1,
    expected_request_sha256: protocol.Digest,
    completion: CompletionV1,
) Error!void {
    if (!std.mem.eql(
        u8,
        input.model_id,
        completion.model_id[0..],
    )) {
        return Error.ModelMismatch;
    }
    if (!std.mem.eql(
        u8,
        &expected_request_sha256,
        &completion.request_sha256,
    )) {
        return Error.CorrelationMismatch;
    }

    const content = completion.contentSlice();
    const output = completion.outputSlice();
    if (content.len != completion.content_bytes or
        content.len != output.len)
    {
        return Error.ContentMismatch;
    }
    if (output.len != input.max_new_tokens or
        completion.output_count != input.max_new_tokens or
        completion.prompt_tokens != input.prompt_utf8.len)
    {
        return Error.TokenCountMismatch;
    }
    for (output, content) |token, byte| {
        const token_byte = std.math.cast(u8, token) orelse
            return Error.ContentMismatch;
        if (token_byte != byte) return Error.ContentMismatch;
    }
}
