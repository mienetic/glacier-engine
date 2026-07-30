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
    /// Serializes admission, model execution, and exact active-work
    /// retirement. Response callbacks and socket writes run after release.
    request_mutex: std.Thread.Mutex = .{},
    /// Lock order is control -> unary service. Request driving never holds
    /// this mutex, so drain can fence and cancel the exact retained handle.
    control_mutex: std.Thread.Mutex = .{},
    next_work_sequence: u64 = 0,
    active_work: ?ActiveWorkV1 = null,
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

pub const WorkIdentityV1 = struct {
    sequence: u64,
    handle_sha256: protocol.Digest,
};

/// Opaque, transport-owned routing identity for one published work lease.
///
/// The HTTP runtime only retains and returns this value. It deliberately
/// contains no native handle, so a managed transport can route a drain receipt
/// without making process-local socket representation part of this contract.
pub const TransportOwnerTokenV1 = struct {
    process_generation: u64,
    connection_sequence: u64,
    slot_index: u8,
    slot_generation: u64,
};

pub const WorkDispositionV1 = enum {
    proceed,
    draining,
    full_request_timeout,
};

pub const WorkCheckpointDispositionV1 = enum {
    proceed,
    peer_reset,
    full_request_timeout,
};

pub const WorkCancellationCauseV1 = enum {
    drain,
    peer_reset,
    full_request_timeout,
    transport_failure,
    preexisting,
};

pub const WorkCancellationReceiptV1 = struct {
    requested_cause: WorkCancellationCauseV1,
    winner: ?WorkCancellationCauseV1,
    outcome: DrainCancellationOutcomeV1,
    cancellation_was_new: bool = false,
};

/// Optional transport-owned boundary after unary admission has published an
/// exact active-work lease and before the first status/drive operation.
pub const RequestWorkControlV1 = struct {
    context: *anyopaque,
    admitted_fn: *const fn (
        *anyopaque,
        WorkIdentityV1,
    ) anyerror!WorkDispositionV1,
    retired_fn: *const fn (*anyopaque, WorkIdentityV1) void,
    /// Copied into the active-work publication while `control_mutex` is held
    /// and returned unchanged in any matching drain receipt.
    transport_owner: ?TransportOwnerTokenV1 = null,
    checkpoint_fn: ?*const fn (
        *anyopaque,
        WorkIdentityV1,
    ) anyerror!WorkCheckpointDispositionV1 = null,
    cancellation_fn: ?*const fn (
        *anyopaque,
        WorkIdentityV1,
        WorkCancellationReceiptV1,
    ) void = null,

    fn admitted(
        self: RequestWorkControlV1,
        identity: WorkIdentityV1,
    ) !WorkDispositionV1 {
        return self.admitted_fn(self.context, identity);
    }

    fn retired(
        self: RequestWorkControlV1,
        identity: WorkIdentityV1,
    ) void {
        self.retired_fn(self.context, identity);
    }

    fn checkpoint(
        self: RequestWorkControlV1,
        identity: WorkIdentityV1,
    ) !WorkCheckpointDispositionV1 {
        const callback = self.checkpoint_fn orelse return .proceed;
        return callback(self.context, identity);
    }

    fn cancellation(
        self: RequestWorkControlV1,
        identity: WorkIdentityV1,
        receipt: WorkCancellationReceiptV1,
    ) void {
        const callback = self.cancellation_fn orelse return;
        callback(self.context, identity, receipt);
    }
};

pub const DrainCancellationOutcomeV1 = enum {
    none,
    cancelled,
    already_cancelled,
    already_terminal,
    start_rolled_back,
    recovery_required,
};

pub const DrainReceiptV1 = struct {
    admission_was_open: bool,
    active_work: ?WorkIdentityV1 = null,
    transport_owner: ?TransportOwnerTokenV1 = null,
    cancellation: DrainCancellationOutcomeV1 = .none,
    cancellation_winner: ?WorkCancellationCauseV1 = null,
    cancellation_was_new: bool = false,
};

const ActiveWorkV1 = struct {
    sequence: u64,
    handle: unary.HandleV1,
    transport_owner: ?TransportOwnerTokenV1 = null,
    stop_decision: ?WorkCancellationReceiptV1 = null,

    fn identity(self: ActiveWorkV1) WorkIdentityV1 {
        return .{
            .sequence = self.sequence,
            .handle_sha256 = self.handle.handle_sha256,
        };
    }
};

const PublishedWorkV1 = struct {
    identity: WorkIdentityV1,
    handle: unary.HandleV1,
};

const WorkAdmissionV1 = union(enum) {
    published: PublishedWorkV1,
    api_error: protocol.ErrorCodeV1,
};

const CompletionExecutionV1 = union(enum) {
    response_body: []const u8,
    api_error: protocol.ErrorCodeV1,
};

pub const ResponseWriteDispositionV1 = enum {
    proceed,
    cancelled,
};

pub const ResponseWriteOutcomeV1 = enum {
    write_completed,
    write_failed,
    cancelled_before_write,
    cancelled_during_write,
};

pub const RequestResponseControlV1 = struct {
    context: *anyopaque,
    ready_fn: *const fn (*anyopaque) anyerror!void,
    writing_fn: *const fn (
        *anyopaque,
    ) anyerror!ResponseWriteDispositionV1,
    retired_fn: *const fn (*anyopaque, ResponseWriteOutcomeV1) void,
    /// Optional managed-transport evidence after a real kernel send accepts
    /// bytes. The synchronous callback may establish a deterministic barrier.
    progress_fn: ?*const fn (*anyopaque, usize) anyerror!void = null,
    /// Optional managed-transport evidence after a real send reports that the
    /// socket is not currently writable.
    blocked_fn: ?*const fn (*anyopaque) anyerror!void = null,

    fn ready(self: RequestResponseControlV1) !void {
        return self.ready_fn(self.context);
    }

    fn writing(
        self: RequestResponseControlV1,
    ) !ResponseWriteDispositionV1 {
        return self.writing_fn(self.context);
    }

    fn retired(
        self: RequestResponseControlV1,
        outcome: ResponseWriteOutcomeV1,
    ) void {
        self.retired_fn(self.context, outcome);
    }
};

pub const RequestControlsV1 = struct {
    receive: ?RequestReceiveControlV1 = null,
    work: ?RequestWorkControlV1 = null,
    response: ?RequestResponseControlV1 = null,
};

const ResponseWriteGuardV1 = struct {
    control: ?RequestResponseControlV1,
    published: bool = false,
    outcome: ResponseWriteOutcomeV1 = .write_failed,

    fn retire(self: *ResponseWriteGuardV1) void {
        if (!self.published) return;
        if (self.control) |control| control.retired(self.outcome);
    }
};

const AwaitResponseDecisionV1 = union(enum) {
    response: unary.ResponseV1,
    peer_reset: WorkCancellationReceiptV1,
    full_request_timeout: WorkCancellationReceiptV1,
};

const ActiveWorkGuardV1 = struct {
    runtime: *RuntimeV1,
    identity: WorkIdentityV1,
    handle: unary.HandleV1,
    control: ?RequestWorkControlV1,
    terminal: bool = false,

    fn retire(self: *ActiveWorkGuardV1) void {
        if (!self.terminal) return;
        if (!retireActiveWorkV1(
            self.runtime,
            self.identity,
            self.handle,
        )) return;
        if (self.control) |control|
            control.retired(self.identity);
    }
};

/// Optional transport-owned boundary for one complete request receive.
///
/// `complete_fn` runs only after every request byte required by the selected
/// route has been received. `stop_fn` atomically retires a pending receive
/// deadline when the adapter rejects or loses the request before that
/// boundary. It returns true when retirement won; false means timeout already
/// won and the adapter must not write a response.
pub const RequestReceiveControlV1 = struct {
    context: *anyopaque,
    complete_fn: *const fn (*anyopaque) anyerror!void,
    stop_fn: *const fn (*anyopaque) anyerror!bool,

    fn complete(self: RequestReceiveControlV1) !void {
        return self.complete_fn(self.context);
    }

    fn stop(self: RequestReceiveControlV1) !bool {
        return self.stop_fn(self.context);
    }
};

const RequestReceiveGuardV1 = struct {
    control: ?RequestReceiveControlV1,
    stopped: bool = false,
    timeout_won: bool = false,

    fn complete(self: *RequestReceiveGuardV1) !void {
        if (self.stopped) return;
        if (self.control) |control| {
            control.complete() catch |err| {
                _ = self.stop() catch {};
                return err;
            };
        }
        self.stopped = true;
    }

    fn stop(self: *RequestReceiveGuardV1) !bool {
        if (self.stopped) return !self.timeout_won;
        const retired = if (self.control) |control|
            try control.stop()
        else
            true;
        self.stopped = true;
        self.timeout_won = !retired;
        return retired;
    }
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
    TransportControlFailed,
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

/// Closes completion admission before generation-fenced cancellation of the
/// exact active unary handle. Cancellation may wait for one in-flight service
/// drive quantum, but it never waits for the whole HTTP response lifecycle.
pub fn beginDrainV1(
    runtime: *RuntimeV1,
) unary.Error!DrainReceiptV1 {
    return beginStopV1(
        runtime,
        .drain,
        cancelHandleLockedV1,
    );
}

/// Closes completion admission after a transport-runtime infrastructure
/// failure and generation-fences cancellation of the exact active unary
/// handle. The distinct cause prevents failure convergence from being
/// reported as an operator-requested drain.
pub fn beginTransportFailureV1(
    runtime: *RuntimeV1,
) unary.Error!DrainReceiptV1 {
    return beginTransportFailureWithCancellationV1(
        runtime,
        cancelHandleLockedV1,
    );
}

const CancelHandleForStopFnV1 = *const fn (
    *RuntimeV1,
    unary.HandleV1,
    WorkCancellationCauseV1,
) unary.Error!WorkCancellationReceiptV1;

fn beginTransportFailureWithCancellationV1(
    runtime: *RuntimeV1,
    cancel_handle: CancelHandleForStopFnV1,
) unary.Error!DrainReceiptV1 {
    return beginStopV1(
        runtime,
        .transport_failure,
        cancel_handle,
    );
}

fn beginStopV1(
    runtime: *RuntimeV1,
    requested_cause: WorkCancellationCauseV1,
    cancel_handle: CancelHandleForStopFnV1,
) unary.Error!DrainReceiptV1 {
    std.debug.assert(
        requested_cause == .drain or
            requested_cause == .transport_failure,
    );
    runtime.control_mutex.lock();
    defer runtime.control_mutex.unlock();
    const was_accepting = runtime.accepting_completions;
    runtime.accepting_completions = false;
    const active = runtime.active_work orelse return .{
        .admission_was_open = was_accepting,
    };
    const identity = active.identity();
    if (active.stop_decision) |decision| {
        return .{
            .admission_was_open = was_accepting,
            .active_work = identity,
            .transport_owner = active.transport_owner,
            .cancellation = decision.outcome,
            .cancellation_winner = decision.winner,
        };
    }

    const cancellation = try cancel_handle(
        runtime,
        active.handle,
        requested_cause,
    );
    runtime.active_work.?.stop_decision = cancellation;
    return .{
        .admission_was_open = was_accepting,
        .active_work = identity,
        .transport_owner = active.transport_owner,
        .cancellation = cancellation.outcome,
        .cancellation_winner = cancellation.winner,
        .cancellation_was_new = cancellation.cancellation_was_new,
    };
}

/// Cancels only the currently published work matching the exact transport
/// identity. The first retained stop decision remains authoritative across
/// timeout, drain, reset, and terminal races.
pub fn cancelActiveWorkForFullRequestTimeoutV1(
    runtime: *RuntimeV1,
    identity: WorkIdentityV1,
) unary.Error!WorkCancellationReceiptV1 {
    runtime.control_mutex.lock();
    defer runtime.control_mutex.unlock();
    const active = runtime.active_work orelse
        return unary.Error.StaleHandle;
    if (!std.meta.eql(active.identity(), identity))
        return unary.Error.StaleHandle;
    if (active.stop_decision) |decision| {
        return .{
            .requested_cause = .full_request_timeout,
            .winner = decision.winner,
            .outcome = decision.outcome,
        };
    }
    const cancellation = try cancelHandleLockedV1(
        runtime,
        active.handle,
        .full_request_timeout,
    );
    runtime.active_work.?.stop_decision = cancellation;
    return cancellation;
}

pub fn acceptingCompletionsV1(runtime: *RuntimeV1) bool {
    runtime.control_mutex.lock();
    defer runtime.control_mutex.unlock();
    return runtime.accepting_completions;
}

pub fn serveRequestV1(
    runtime: *RuntimeV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
) !void {
    return serveRequestWithControlsV1(
        runtime,
        request,
        workspace,
        null,
        null,
    );
}

pub fn serveRequestWithReceiveControlV1(
    runtime: *RuntimeV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
    receive_control: ?RequestReceiveControlV1,
) !void {
    return serveRequestWithControlsV1(
        runtime,
        request,
        workspace,
        receive_control,
        null,
    );
}

pub fn serveRequestWithControlsV1(
    runtime: *RuntimeV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
    receive_control: ?RequestReceiveControlV1,
    work_control: ?RequestWorkControlV1,
) !void {
    return serveRequestWithLifecycleControlsV1(
        runtime,
        request,
        workspace,
        .{
            .receive = receive_control,
            .work = work_control,
        },
    );
}

pub fn serveRequestWithLifecycleControlsV1(
    runtime: *RuntimeV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
    controls: RequestControlsV1,
) !void {
    var receive_guard: RequestReceiveGuardV1 = .{
        .control = controls.receive,
    };
    defer _ = receive_guard.stop() catch {};

    if (request.head.version != .@"HTTP/1.1") {
        return respondApiErrorBeforeReceiveRetirement(
            &receive_guard,
            request,
            workspace,
            .http_version_not_supported,
            null,
            controls.response,
        );
    }

    if (std.mem.eql(
        u8,
        request.head.target,
        protocol.models_path_v1,
    )) {
        if (request.head.method != .GET) {
            return respondApiErrorBeforeReceiveRetirement(
                &receive_guard,
                request,
                workspace,
                .method_not_allowed,
                null,
                controls.response,
            );
        }
        return serveModelsV1(
            runtime,
            request,
            workspace,
            &receive_guard,
            controls.response,
        );
    }

    if (std.mem.eql(
        u8,
        request.head.target,
        protocol.completions_path_v1,
    )) {
        if (request.head.method != .POST) {
            return respondApiErrorBeforeReceiveRetirement(
                &receive_guard,
                request,
                workspace,
                .method_not_allowed,
                null,
                controls.response,
            );
        }
        return serveCompletionV1(
            runtime,
            request,
            workspace,
            &receive_guard,
            controls.work,
            controls.response,
        );
    }

    return respondApiErrorBeforeReceiveRetirement(
        &receive_guard,
        request,
        workspace,
        .route_not_found,
        null,
        controls.response,
    );
}

fn respondApiErrorBeforeReceiveRetirement(
    receive_guard: *RequestReceiveGuardV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
    code: protocol.ErrorCodeV1,
    request_sha256: ?protocol.Digest,
    response_control: ?RequestResponseControlV1,
) !void {
    if (!(try receive_guard.stop()))
        return error.ConnectionReceiveTimedOut;
    return respondApiError(
        request,
        workspace,
        code,
        request_sha256,
        response_control,
    );
}

fn serveModelsV1(
    runtime: *RuntimeV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
    receive_guard: *RequestReceiveGuardV1,
    response_control: ?RequestResponseControlV1,
) !void {
    validateModelListHeaders(request) catch {
        request.head.expect = null;
        return respondApiErrorBeforeReceiveRetirement(
            receive_guard,
            request,
            workspace,
            .invalid_request,
            null,
            response_control,
        );
    };
    try receive_guard.complete();
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
            response_control,
        );
    };
    try respondV1(request, body, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &response_headers,
    }, response_control);
}

fn serveCompletionV1(
    runtime: *RuntimeV1,
    request: *std.http.Server.Request,
    workspace: *WorkspaceV1,
    receive_guard: *RequestReceiveGuardV1,
    work_control: ?RequestWorkControlV1,
    response_control: ?RequestResponseControlV1,
) !void {
    const content_length_u64 = request.head.content_length orelse {
        request.head.expect = null;
        return respondApiErrorBeforeReceiveRetirement(
            receive_guard,
            request,
            workspace,
            .missing_content_length,
            null,
            response_control,
        );
    };
    if (content_length_u64 == 0 or
        content_length_u64 > protocol.request_body_max_bytes)
    {
        request.head.expect = null;
        return respondApiErrorBeforeReceiveRetirement(
            receive_guard,
            request,
            workspace,
            .request_too_large,
            null,
            response_control,
        );
    }

    const owned_headers = collectCompletionHeaders(
        request,
        workspace,
        content_length_u64,
    ) catch |err| {
        request.head.expect = null;
        return respondApiErrorBeforeReceiveRetirement(
            receive_guard,
            request,
            workspace,
            switch (err) {
                error.MissingContentLength => .missing_content_length,
                error.UnsupportedMediaType => .unsupported_media_type,
                error.RequestTooLarge => .request_too_large,
                error.InvalidHeader => .invalid_request,
            },
            null,
            response_control,
        );
    };

    const content_length: usize = @intCast(content_length_u64);
    const body_reader =
        request.readerExpectNone(&workspace.body_reader);
    body_reader.readSliceAll(
        workspace.body[0..content_length],
    ) catch {
        if (!(try receive_guard.stop()))
            return error.ConnectionReceiveTimedOut;
        // Managed drain interrupts only the receive side. Do not turn that
        // transport cancellation into a client-visible malformed-body reply.
        if (!acceptingCompletionsV1(runtime))
            return error.ConnectionDraining;
        return respondApiError(
            request,
            workspace,
            .invalid_request,
            null,
            response_control,
        );
    };
    try receive_guard.complete();

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
            response_control,
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
                response_control,
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
                response_control,
            );
        };

    const execution = blk: {
        runtime.request_mutex.lock();
        defer runtime.request_mutex.unlock();
        break :blk try executeCompletionLockedV1(
            runtime,
            workspace,
            .{
                .tenant_key = decoded.request.tenant_key,
                .idempotency_key_sha256 = idempotency_key_sha256,
                .prompt_utf8 = decoded.request.prompt_utf8,
                .max_new_tokens = decoded.request.max_new_tokens,
                .deadline_tick = decoded.request.deadline_tick,
            },
            request_sha256,
            work_control,
        );
    };

    switch (execution) {
        .api_error => |code| try respondApiError(
            request,
            workspace,
            code,
            request_sha256,
            response_control,
        ),
        .response_body => |body| try respondV1(request, body, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &response_headers,
        }, response_control),
    }
}

/// Runs only the serial admission/model-execution/active-work-retirement
/// section. The caller holds `request_mutex`. Returning from this helper runs
/// `ActiveWorkGuardV1.retire` before that mutex is released, so no successor
/// work lease can be published before the predecessor's exact retirement.
/// Socket writes and response-control callbacks are intentionally absent.
fn executeCompletionLockedV1(
    runtime: *RuntimeV1,
    workspace: *WorkspaceV1,
    service_request: unary.RequestV1,
    request_sha256: protocol.Digest,
    work_control: ?RequestWorkControlV1,
) !CompletionExecutionV1 {
    const transport_owner = if (work_control) |control|
        control.transport_owner
    else
        null;
    const work_admission = admitActiveWorkV1(
        runtime,
        service_request,
        transport_owner,
    ) catch |err| {
        return .{ .api_error = mapServiceError(err) };
    };

    const published = switch (work_admission) {
        .published => |value| value,
        .api_error => |code| return .{ .api_error = code },
    };
    return executePublishedCompletionLockedV1(
        runtime,
        workspace,
        published,
        request_sha256,
        work_control,
    );
}

/// Completes one already-published lease while the caller retains
/// `request_mutex`. This split keeps the terminal execution/retirement
/// boundary directly testable without a socket.
fn executePublishedCompletionLockedV1(
    runtime: *RuntimeV1,
    workspace: *WorkspaceV1,
    published: PublishedWorkV1,
    request_sha256: protocol.Digest,
    work_control: ?RequestWorkControlV1,
) !CompletionExecutionV1 {
    var work_guard: ActiveWorkGuardV1 = .{
        .runtime = runtime,
        .identity = published.identity,
        .handle = published.handle,
        .control = work_control,
    };
    defer work_guard.retire();

    if (work_control) |control| {
        const disposition = control.admitted(
            published.identity,
        ) catch |callback_error| {
            const cancellation = cancelPublishedWorkV1(
                runtime,
                published,
                .transport_failure,
            ) catch null;
            if (cancellation) |receipt| {
                control.cancellation(
                    published.identity,
                    receipt,
                );
                work_guard.terminal =
                    cancellationEndsLeaseV1(receipt.outcome);
            }
            return callback_error;
        };
        switch (disposition) {
            .proceed => {},
            .draining => {
                const cancellation = cancelPublishedWorkV1(
                    runtime,
                    published,
                    .drain,
                ) catch |err| {
                    return .{
                        .api_error = mapServiceError(err),
                    };
                };
                if (cancellationHidesResponseV1(
                    cancellation.outcome,
                )) {
                    work_guard.terminal = true;
                    return .{
                        .api_error = .request_cancelled,
                    };
                }
            },
            .full_request_timeout => {
                const cancellation =
                    try cancelPublishedWorkAndNotifyV1(
                        runtime,
                        published,
                        control,
                        .full_request_timeout,
                    );
                work_guard.terminal =
                    cancellationEndsLeaseV1(
                        cancellation.outcome,
                    );
                return error.ConnectionFullRequestTimedOut;
            },
        }
    }

    const awaited = awaitResponseV1(
        runtime,
        published,
        work_control,
    ) catch |err| {
        var response_code = mapAwaitError(err);
        work_guard.terminal = switch (err) {
            TerminalError.RequestCancelled,
            TerminalError.ExecutionFailed,
            => true,
            else => blk: {
                const cancellation = if (work_control) |control|
                    cancelPublishedWorkAndNotifyV1(
                        runtime,
                        published,
                        control,
                        .transport_failure,
                    ) catch break :blk false
                else
                    cancelPublishedWorkV1(
                        runtime,
                        published,
                        .transport_failure,
                    ) catch break :blk false;
                if (cancellationHidesResponseV1(
                    cancellation.outcome,
                )) {
                    response_code = .request_cancelled;
                }
                break :blk cancellationEndsLeaseV1(
                    cancellation.outcome,
                );
            },
        };
        return .{ .api_error = response_code };
    };
    const response = switch (awaited) {
        .response => |value| value,
        .peer_reset => |receipt| {
            work_guard.terminal =
                cancellationEndsLeaseV1(receipt.outcome);
            return error.ConnectionPeerReset;
        },
        .full_request_timeout => |receipt| {
            work_guard.terminal =
                cancellationEndsLeaseV1(receipt.outcome);
            return error.ConnectionFullRequestTimedOut;
        },
    };
    work_guard.terminal = true;

    const output_count: usize = response.output_count;
    if (output_count == 0 or
        output_count > protocol.output_max_tokens)
    {
        return .{ .api_error = .state_drift };
    }
    for (
        response.output_tokens[0..output_count],
        workspace.output[0..output_count],
    ) |token, *byte| {
        byte.* = std.math.cast(u8, token) orelse {
            return .{ .api_error = .non_utf8_model_output };
        };
    }
    const content = workspace.output[0..output_count];
    if (!std.unicode.utf8ValidateSlice(content)) {
        return .{ .api_error = .non_utf8_model_output };
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
        return .{
            .api_error = if (err ==
                protocol.Error.NonUtf8Output)
                .non_utf8_model_output
            else
                .internal_error,
        };
    };
    return .{ .response_body = body };
}

/// Admission and active-work publication are one control-plane transaction.
/// The lock order is control -> unary service. No network or host callback
/// runs while either lock is held.
fn admitActiveWorkV1(
    runtime: *RuntimeV1,
    service_request: unary.RequestV1,
    transport_owner: ?TransportOwnerTokenV1,
) unary.Error!WorkAdmissionV1 {
    runtime.control_mutex.lock();
    defer runtime.control_mutex.unlock();

    if (!runtime.accepting_completions)
        return .{ .api_error = .service_closed };
    if (runtime.active_work != null)
        return .{ .api_error = .runtime_unavailable };

    const work_sequence = std.math.add(
        u64,
        runtime.next_work_sequence,
        1,
    ) catch {
        runtime.accepting_completions = false;
        return unary.Error.SequenceExhausted;
    };
    const admission = try runtime.service.admitV1(
        service_request,
    );
    const handle: unary.HandleV1 = switch (admission) {
        .accepted => |receipt| receipt.handle,
        .existing => |existing| switch (existing.state) {
            .active, .completed => existing.handle,
            .recovery_required => return .{
                .api_error = .recovery_required,
            },
            .cancelled => return .{
                .api_error = .request_cancelled,
            },
            .failed => return .{
                .api_error = .execution_failed,
            },
        },
        .rejected => |rejection| return .{
            .api_error = switch (rejection) {
                .service_capacity => .service_capacity,
                .scheduler => .scheduler_rejected,
            },
        },
        .conflict => return .{
            .api_error = .idempotency_conflict,
        },
        .recovery_required => return .{
            .api_error = .recovery_required,
        },
    };

    runtime.next_work_sequence = work_sequence;
    runtime.active_work = .{
        .sequence = work_sequence,
        .handle = handle,
        .transport_owner = transport_owner,
    };
    return .{ .published = .{
        .identity = .{
            .sequence = work_sequence,
            .handle_sha256 = handle.handle_sha256,
        },
        .handle = handle,
    } };
}

fn awaitResponseV1(
    runtime: *RuntimeV1,
    published: PublishedWorkV1,
    work_control: ?RequestWorkControlV1,
) (unary.Error || TerminalError)!AwaitResponseDecisionV1 {
    var drive_calls: usize = 0;
    while (drive_calls <= unary.maximum_output_tokens) : (drive_calls += 1) {
        if (work_control) |control| {
            if (try observeWorkCheckpointV1(
                runtime,
                published,
                control,
            )) |decision| return decision;
        }

        const status =
            try runtime.service.statusV1(published.handle);
        switch (status) {
            .completed => return .{ .response = try runtime.service.responseV1(published.handle) },
            .cancelled => {
                // A full-request timer may cancel the service after the first
                // checkpoint and before this status read. Re-check the
                // transport owner so that race closes the connection instead
                // of rendering a client-visible generic cancellation.
                if (work_control) |control| {
                    if (try observeWorkCheckpointV1(
                        runtime,
                        published,
                        control,
                    )) |decision| return decision;
                }
                return TerminalError.RequestCancelled;
            },
            .failed => return TerminalError.ExecutionFailed,
            .active => {},
        }
        if (drive_calls == unary.maximum_output_tokens)
            return unary.Error.RuntimeUnavailable;
        const drive = try runtime.service.driveNextV1();
        switch (drive) {
            .idle => return unary.Error.RuntimeUnavailable,
            .progressed, .completed => {},
            .request_failed => |failed_handle| {
                if (std.meta.eql(failed_handle, published.handle))
                    return TerminalError.ExecutionFailed;
            },
            .recovery_required => return unary.Error.RecoveryRequired,
        }
    }
    unreachable;
}

fn observeWorkCheckpointV1(
    runtime: *RuntimeV1,
    published: PublishedWorkV1,
    control: RequestWorkControlV1,
) (unary.Error || TerminalError)!?AwaitResponseDecisionV1 {
    const checkpoint = control.checkpoint(
        published.identity,
    ) catch return TerminalError.TransportControlFailed;
    return switch (checkpoint) {
        .proceed => null,
        .peer_reset => .{ .peer_reset = try cancelPublishedWorkAndNotifyV1(
            runtime,
            published,
            control,
            .peer_reset,
        ) },
        .full_request_timeout => .{ .full_request_timeout = try cancelPublishedWorkAndNotifyV1(
            runtime,
            published,
            control,
            .full_request_timeout,
        ) },
    };
}

fn cancelPublishedWorkAndNotifyV1(
    runtime: *RuntimeV1,
    published: PublishedWorkV1,
    control: RequestWorkControlV1,
    cause: WorkCancellationCauseV1,
) unary.Error!WorkCancellationReceiptV1 {
    const cancellation = try cancelPublishedWorkV1(
        runtime,
        published,
        cause,
    );
    control.cancellation(
        published.identity,
        cancellation,
    );
    return cancellation;
}

/// Requires `runtime.control_mutex`. This is the only helper that calls
/// `ServiceV1.cancelV1`, preserving the control -> service lock order.
fn cancelHandleLockedV1(
    runtime: *RuntimeV1,
    handle: unary.HandleV1,
    cause: WorkCancellationCauseV1,
) unary.Error!WorkCancellationReceiptV1 {
    const decision = try runtime.service.cancelV1(handle);
    return switch (decision) {
        .cancelled => .{
            .requested_cause = cause,
            .winner = cause,
            .outcome = .cancelled,
            .cancellation_was_new = true,
        },
        .already_cancelled => .{
            .requested_cause = cause,
            .winner = .preexisting,
            .outcome = .already_cancelled,
        },
        .already_terminal => .{
            .requested_cause = cause,
            .winner = null,
            .outcome = .already_terminal,
        },
        .start_rolled_back => .{
            .requested_cause = cause,
            .winner = cause,
            .outcome = .start_rolled_back,
            .cancellation_was_new = true,
        },
        .recovery_required => .{
            .requested_cause = cause,
            .winner = null,
            .outcome = .recovery_required,
        },
    };
}

fn cancelPublishedWorkV1(
    runtime: *RuntimeV1,
    published: PublishedWorkV1,
    cause: WorkCancellationCauseV1,
) unary.Error!WorkCancellationReceiptV1 {
    runtime.control_mutex.lock();
    defer runtime.control_mutex.unlock();
    const active = runtime.active_work orelse
        return unary.Error.StaleHandle;
    if (!activeWorkMatchesV1(
        active,
        published.identity,
        published.handle,
    )) {
        return unary.Error.StaleHandle;
    }
    if (active.stop_decision) |decision| {
        return .{
            .requested_cause = cause,
            .winner = decision.winner,
            .outcome = decision.outcome,
        };
    }
    const cancellation = try cancelHandleLockedV1(
        runtime,
        published.handle,
        cause,
    );
    runtime.active_work.?.stop_decision = cancellation;
    return cancellation;
}

fn retireActiveWorkV1(
    runtime: *RuntimeV1,
    identity: WorkIdentityV1,
    handle: unary.HandleV1,
) bool {
    runtime.control_mutex.lock();
    defer runtime.control_mutex.unlock();
    const active = runtime.active_work orelse return false;
    if (!activeWorkMatchesV1(active, identity, handle))
        return false;
    runtime.active_work = null;
    return true;
}

fn activeWorkMatchesV1(
    active: ActiveWorkV1,
    identity: WorkIdentityV1,
    handle: unary.HandleV1,
) bool {
    return active.sequence == identity.sequence and
        std.mem.eql(
            u8,
            &active.handle.handle_sha256,
            &identity.handle_sha256,
        ) and
        std.meta.eql(active.handle, handle);
}

fn cancellationEndsLeaseV1(
    outcome: DrainCancellationOutcomeV1,
) bool {
    return switch (outcome) {
        .cancelled,
        .already_cancelled,
        .already_terminal,
        .start_rolled_back,
        => true,
        .none, .recovery_required => false,
    };
}

fn cancellationHidesResponseV1(
    outcome: DrainCancellationOutcomeV1,
) bool {
    return switch (outcome) {
        .cancelled,
        .already_cancelled,
        .start_rolled_back,
        => true,
        .none,
        .already_terminal,
        .recovery_required,
        => false,
    };
}

test "active work retirement requires the exact runtime and service fences" {
    const handle: unary.HandleV1 = .{
        .service_epoch = 41,
        .record_index = 3,
        .record_generation = 17,
        .intent_sha256 = [_]u8{0x31} ** 32,
        .handle_sha256 = [_]u8{0x52} ** 32,
    };
    const identity: WorkIdentityV1 = .{
        .sequence = 9,
        .handle_sha256 = handle.handle_sha256,
    };
    var runtime: RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
        .next_work_sequence = identity.sequence,
        .active_work = .{
            .sequence = identity.sequence,
            .handle = handle,
        },
    };

    var stale_identity = identity;
    stale_identity.sequence += 1;
    try std.testing.expect(!retireActiveWorkV1(
        &runtime,
        stale_identity,
        handle,
    ));
    stale_identity = identity;
    stale_identity.handle_sha256[0] ^= 0xff;
    try std.testing.expect(!retireActiveWorkV1(
        &runtime,
        stale_identity,
        handle,
    ));

    var stale_handle = handle;
    stale_handle.record_generation += 1;
    try std.testing.expect(!retireActiveWorkV1(
        &runtime,
        identity,
        stale_handle,
    ));
    try std.testing.expect(runtime.active_work != null);
    try std.testing.expect(retireActiveWorkV1(
        &runtime,
        identity,
        handle,
    ));
    try std.testing.expect(runtime.active_work == null);
}

test "drain receipt preserves the opaque active work transport owner" {
    const handle: unary.HandleV1 = .{
        .service_epoch = 43,
        .record_index = 2,
        .record_generation = 19,
        .intent_sha256 = [_]u8{0x35} ** 32,
        .handle_sha256 = [_]u8{0x56} ** 32,
    };
    const owner: TransportOwnerTokenV1 = .{
        .process_generation = 47,
        .connection_sequence = 53,
        .slot_index = 3,
        .slot_generation = 59,
    };
    var runtime: RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
        .next_work_sequence = 61,
        .active_work = .{
            .sequence = 61,
            .handle = handle,
            .transport_owner = owner,
            .stop_decision = .{
                .requested_cause = .full_request_timeout,
                .winner = .full_request_timeout,
                .outcome = .cancelled,
                .cancellation_was_new = true,
            },
        },
    };

    const first = try beginDrainV1(&runtime);
    try std.testing.expect(first.admission_was_open);
    try std.testing.expectEqualDeep(
        runtime.active_work.?.identity(),
        first.active_work.?,
    );
    try std.testing.expectEqualDeep(
        owner,
        first.transport_owner.?,
    );
    try std.testing.expectEqual(
        WorkCancellationCauseV1.full_request_timeout,
        first.cancellation_winner.?,
    );
    try std.testing.expectEqual(
        DrainCancellationOutcomeV1.cancelled,
        first.cancellation,
    );
    try std.testing.expect(!first.cancellation_was_new);

    const repeated = try beginDrainV1(&runtime);
    try std.testing.expect(!repeated.admission_was_open);
    try std.testing.expectEqualDeep(
        first.active_work.?,
        repeated.active_work.?,
    );
    try std.testing.expectEqualDeep(
        first.transport_owner.?,
        repeated.transport_owner.?,
    );
    try std.testing.expectEqual(
        first.cancellation_winner,
        repeated.cancellation_winner,
    );
}

test "transport failure receipt preserves its distinct sticky winner" {
    const FreshCancellationV1 = struct {
        fn cancel(
            runtime: *RuntimeV1,
            handle: unary.HandleV1,
            requested_cause: WorkCancellationCauseV1,
        ) unary.Error!WorkCancellationReceiptV1 {
            _ = runtime;
            _ = handle;
            return .{
                .requested_cause = requested_cause,
                .winner = requested_cause,
                .outcome = .cancelled,
                .cancellation_was_new = true,
            };
        }
    };
    const handle: unary.HandleV1 = .{
        .service_epoch = 47,
        .record_index = 3,
        .record_generation = 23,
        .intent_sha256 = [_]u8{0x37} ** 32,
        .handle_sha256 = [_]u8{0x58} ** 32,
    };
    const owner: TransportOwnerTokenV1 = .{
        .process_generation = 61,
        .connection_sequence = 67,
        .slot_index = 5,
        .slot_generation = 71,
    };
    var runtime: RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
        .next_work_sequence = 73,
        .active_work = .{
            .sequence = 73,
            .handle = handle,
            .transport_owner = owner,
        },
    };

    const failure = try beginTransportFailureWithCancellationV1(
        &runtime,
        FreshCancellationV1.cancel,
    );
    try std.testing.expect(failure.admission_was_open);
    try std.testing.expectEqualDeep(
        runtime.active_work.?.identity(),
        failure.active_work.?,
    );
    try std.testing.expectEqualDeep(
        owner,
        failure.transport_owner.?,
    );
    try std.testing.expectEqual(
        WorkCancellationCauseV1.transport_failure,
        failure.cancellation_winner.?,
    );
    try std.testing.expectEqual(
        DrainCancellationOutcomeV1.cancelled,
        failure.cancellation,
    );
    try std.testing.expect(failure.cancellation_was_new);
    try std.testing.expectEqual(
        WorkCancellationCauseV1.transport_failure,
        runtime.active_work.?.stop_decision.?.requested_cause,
    );

    const later_drain = try beginDrainV1(&runtime);
    try std.testing.expect(!later_drain.admission_was_open);
    try std.testing.expectEqual(
        WorkCancellationCauseV1.transport_failure,
        later_drain.cancellation_winner.?,
    );
    try std.testing.expect(!later_drain.cancellation_was_new);
}

const FullRequestTimeoutTestControlV1 = struct {
    proceed_checkpoints: usize = 0,
    checkpoint_calls: usize = 0,
    cancellation_calls: usize = 0,
    cancellation_identity: ?WorkIdentityV1 = null,
    cancellation_receipt: ?WorkCancellationReceiptV1 = null,

    fn admittedOpaque(
        context: *anyopaque,
        identity: WorkIdentityV1,
    ) anyerror!WorkDispositionV1 {
        _ = context;
        _ = identity;
        return .full_request_timeout;
    }

    fn retiredOpaque(
        context: *anyopaque,
        identity: WorkIdentityV1,
    ) void {
        _ = context;
        _ = identity;
    }

    fn checkpointOpaque(
        context: *anyopaque,
        identity: WorkIdentityV1,
    ) anyerror!WorkCheckpointDispositionV1 {
        const self: *FullRequestTimeoutTestControlV1 =
            @ptrCast(@alignCast(context));
        _ = identity;
        self.checkpoint_calls += 1;
        if (self.checkpoint_calls <= self.proceed_checkpoints)
            return .proceed;
        return .full_request_timeout;
    }

    fn cancellationOpaque(
        context: *anyopaque,
        identity: WorkIdentityV1,
        receipt: WorkCancellationReceiptV1,
    ) void {
        const self: *FullRequestTimeoutTestControlV1 =
            @ptrCast(@alignCast(context));
        self.cancellation_calls += 1;
        self.cancellation_identity = identity;
        self.cancellation_receipt = receipt;
    }

    fn control(
        self: *FullRequestTimeoutTestControlV1,
    ) RequestWorkControlV1 {
        return .{
            .context = self,
            .admitted_fn = admittedOpaque,
            .retired_fn = retiredOpaque,
            .checkpoint_fn = checkpointOpaque,
            .cancellation_fn = cancellationOpaque,
        };
    }
};

fn makeFullRequestTimeoutTestHandleV1(
    service_epoch: u64,
    record_index: u32,
    record_generation: u64,
    intent_sha256: unary.Digest,
) unary.HandleV1 {
    var handle: unary.HandleV1 = .{
        .service_epoch = service_epoch,
        .record_index = record_index,
        .record_generation = record_generation,
        .intent_sha256 = intent_sha256,
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-prepared-text-unary-handle-v1\x00");
    var u64_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &u64_bytes, service_epoch, .little);
    hash.update(&u64_bytes);
    var u32_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &u32_bytes, record_index, .little);
    hash.update(&u32_bytes);
    std.mem.writeInt(
        u64,
        &u64_bytes,
        record_generation,
        .little,
    );
    hash.update(&u64_bytes);
    hash.update(&intent_sha256);
    hash.final(&handle.handle_sha256);
    return handle;
}

const response_gate_test_timeout_ns =
    5 * std.time.ns_per_s;

fn waitForResponseGateTestEventV1(
    event: *std.Thread.ResetEvent,
) !void {
    event.timedWait(response_gate_test_timeout_ns) catch
        return error.ResponseGateTestTimedOut;
}

const WorkRetirementTestControlV1 = struct {
    retired_reached: std.Thread.ResetEvent = .{},
    retired_identity: ?WorkIdentityV1 = null,
    retired: bool = false,

    fn admittedOpaque(
        context: *anyopaque,
        identity: WorkIdentityV1,
    ) anyerror!WorkDispositionV1 {
        _ = context;
        _ = identity;
        return .proceed;
    }

    fn retiredOpaque(
        context: *anyopaque,
        identity: WorkIdentityV1,
    ) void {
        const self: *WorkRetirementTestControlV1 =
            @ptrCast(@alignCast(context));
        self.retired_identity = identity;
        self.retired = true;
        self.retired_reached.set();
    }

    fn control(
        self: *WorkRetirementTestControlV1,
        owner: TransportOwnerTokenV1,
    ) RequestWorkControlV1 {
        return .{
            .context = self,
            .admitted_fn = admittedOpaque,
            .retired_fn = retiredOpaque,
            .transport_owner = owner,
        };
    }
};

const ResponseGateTestControlV1 = struct {
    work_retirement: *const WorkRetirementTestControlV1,
    ready_reached: std.Thread.ResetEvent = .{},
    ready_release: std.Thread.ResetEvent = .{},
    writing_reached: std.Thread.ResetEvent = .{},
    retired_reached: std.Thread.ResetEvent = .{},
    outcome: ?ResponseWriteOutcomeV1 = null,

    fn readyOpaque(context: *anyopaque) anyerror!void {
        const self: *ResponseGateTestControlV1 =
            @ptrCast(@alignCast(context));
        if (!self.work_retirement.retired)
            return error.WorkNotRetiredBeforeResponse;
        self.ready_reached.set();
        try waitForResponseGateTestEventV1(
            &self.ready_release,
        );
    }

    fn writingOpaque(
        context: *anyopaque,
    ) anyerror!ResponseWriteDispositionV1 {
        const self: *ResponseGateTestControlV1 =
            @ptrCast(@alignCast(context));
        self.writing_reached.set();
        return .proceed;
    }

    fn retiredOpaque(
        context: *anyopaque,
        outcome: ResponseWriteOutcomeV1,
    ) void {
        const self: *ResponseGateTestControlV1 =
            @ptrCast(@alignCast(context));
        self.outcome = outcome;
        self.retired_reached.set();
    }

    fn control(
        self: *ResponseGateTestControlV1,
    ) RequestResponseControlV1 {
        return .{
            .context = self,
            .ready_fn = readyOpaque,
            .writing_fn = writingOpaque,
            .retired_fn = retiredOpaque,
        };
    }
};

const FirstResponseGateThreadV1 = struct {
    runtime: *RuntimeV1,
    workspace: *WorkspaceV1,
    published: PublishedWorkV1,
    request_sha256: protocol.Digest,
    work_control: RequestWorkControlV1,
    response_control: RequestResponseControlV1,
    thread_error: ?anyerror = null,

    fn run(self: *FirstResponseGateThreadV1) void {
        self.runChecked() catch |err| {
            self.thread_error = err;
        };
    }

    fn runChecked(self: *FirstResponseGateThreadV1) !void {
        self.runtime.request_mutex.lock();
        var request_locked = true;
        defer if (request_locked)
            self.runtime.request_mutex.unlock();

        const execution =
            try executePublishedCompletionLockedV1(
                self.runtime,
                self.workspace,
                self.published,
                self.request_sha256,
                self.work_control,
            );
        switch (execution) {
            .response_body => {},
            .api_error => return error.UnexpectedApiError,
        }
        if (self.runtime.active_work != null)
            return error.ActiveWorkNotRetired;

        self.runtime.request_mutex.unlock();
        request_locked = false;
        try self.response_control.ready();
        if (try self.response_control.writing() != .proceed)
            return error.UnexpectedResponseCancellation;
        self.response_control.retired(.write_completed);
    }
};

const SuccessorExecutionGateThreadV1 = struct {
    runtime: *RuntimeV1,
    workspace: *WorkspaceV1,
    published: PublishedWorkV1,
    request_sha256: protocol.Digest,
    owner: TransportOwnerTokenV1,
    response_ready: *std.Thread.ResetEvent,
    execution_finished: std.Thread.ResetEvent = .{},
    thread_error: ?anyerror = null,

    fn run(self: *SuccessorExecutionGateThreadV1) void {
        self.runChecked() catch |err| {
            self.thread_error = err;
        };
    }

    fn runChecked(
        self: *SuccessorExecutionGateThreadV1,
    ) !void {
        try waitForResponseGateTestEventV1(
            self.response_ready,
        );
        self.runtime.request_mutex.lock();
        var request_locked = true;
        defer if (request_locked)
            self.runtime.request_mutex.unlock();

        self.runtime.control_mutex.lock();
        if (self.runtime.active_work != null) {
            self.runtime.control_mutex.unlock();
            return error.PredecessorWorkStillActive;
        }
        self.runtime.active_work = .{
            .sequence = self.published.identity.sequence,
            .handle = self.published.handle,
            .transport_owner = self.owner,
        };
        self.runtime.control_mutex.unlock();

        const execution =
            try executePublishedCompletionLockedV1(
                self.runtime,
                self.workspace,
                self.published,
                self.request_sha256,
                null,
            );
        switch (execution) {
            .response_body => {},
            .api_error => return error.UnexpectedApiError,
        }
        if (self.runtime.active_work != null)
            return error.SuccessorWorkNotRetired;
        self.runtime.request_mutex.unlock();
        request_locked = false;
        self.execution_finished.set();
    }
};

test "terminal work retires before a blocked response admits successor execution" {
    const service_epoch: u64 = 97;
    const first_intent_sha256 = [_]u8{0xb1} ** 32;
    const successor_intent_sha256 = [_]u8{0xb2} ** 32;
    const first_handle = makeFullRequestTimeoutTestHandleV1(
        service_epoch,
        0,
        1,
        first_intent_sha256,
    );
    const successor_handle =
        makeFullRequestTimeoutTestHandleV1(
            service_epoch,
            1,
            2,
            successor_intent_sha256,
        );
    var first_intent: unary.IntentV1 = .{};
    first_intent.intent_sha256 = first_intent_sha256;
    var successor_intent: unary.IntentV1 = .{};
    successor_intent.intent_sha256 =
        successor_intent_sha256;
    var first_response =
        std.mem.zeroes(unary.ResponseV1);
    first_response.handle = first_handle;
    first_response.admission.prompt_receipt.token_count = 1;
    first_response.output_count = 1;
    first_response.output_tokens[0] = 'a';
    first_response.response_sha256 = [_]u8{0xe1} ** 32;
    first_response.terminal.evidence_sha256 =
        [_]u8{0xe2} ** 32;
    first_response.terminal.result.output_sha256 =
        [_]u8{0xe3} ** 32;
    var successor_response =
        std.mem.zeroes(unary.ResponseV1);
    successor_response.handle = successor_handle;
    successor_response.admission.prompt_receipt.token_count = 1;
    successor_response.output_count = 1;
    successor_response.output_tokens[0] = 'b';
    successor_response.response_sha256 =
        [_]u8{0xe4} ** 32;
    successor_response.terminal.evidence_sha256 =
        [_]u8{0xe5} ** 32;
    successor_response.terminal.result.output_sha256 =
        [_]u8{0xe6} ** 32;
    var active_slots = [_]unary.ActiveSlotV1{.{}};
    var records = [_]unary.RecordSlotV1{
        .{
            .generation = first_handle.record_generation,
            .state = .completed,
            .intent = first_intent,
            .handle = first_handle,
            .response = first_response,
        },
        .{
            .generation = successor_handle.record_generation,
            .state = .completed,
            .intent = successor_intent,
            .handle = successor_handle,
            .response = successor_response,
        },
    };
    var service: unary.ServiceV1 = .{
        .state = .closed,
        .config = .{ .service_epoch = service_epoch },
        .active_slots = &active_slots,
        .records = &records,
    };
    service.self_address = @intFromPtr(&service);
    service.active_storage_address =
        @intFromPtr(active_slots[0..].ptr);
    service.record_storage_address =
        @intFromPtr(records[0..].ptr);

    const first_identity: WorkIdentityV1 = .{
        .sequence = 1,
        .handle_sha256 = first_handle.handle_sha256,
    };
    const successor_identity: WorkIdentityV1 = .{
        .sequence = 2,
        .handle_sha256 = successor_handle.handle_sha256,
    };
    const first_owner: TransportOwnerTokenV1 = .{
        .process_generation = 101,
        .connection_sequence = 103,
        .slot_index = 0,
        .slot_generation = 107,
    };
    const successor_owner: TransportOwnerTokenV1 = .{
        .process_generation = 101,
        .connection_sequence = 109,
        .slot_index = 1,
        .slot_generation = 113,
    };
    const model_binding_sha256 = [_]u8{0xc1} ** 32;
    var runtime: RuntimeV1 = .{
        .service = &service,
        .model_binding_sha256 = model_binding_sha256,
        .model_id = protocol.modelIdV1(
            model_binding_sha256,
        ),
        .next_work_sequence = first_identity.sequence,
        .active_work = .{
            .sequence = first_identity.sequence,
            .handle = first_handle,
            .transport_owner = first_owner,
        },
    };
    var retirement_control: WorkRetirementTestControlV1 = .{};
    const first_work_control =
        retirement_control.control(first_owner);
    var response_control: ResponseGateTestControlV1 = .{
        .work_retirement = &retirement_control,
    };
    var first_workspace: WorkspaceV1 = undefined;
    var successor_workspace: WorkspaceV1 = undefined;
    var first_thread_context: FirstResponseGateThreadV1 = .{
        .runtime = &runtime,
        .workspace = &first_workspace,
        .published = .{
            .identity = first_identity,
            .handle = first_handle,
        },
        .request_sha256 = [_]u8{0xd1} ** 32,
        .work_control = first_work_control,
        .response_control = response_control.control(),
    };
    var successor_thread_context: SuccessorExecutionGateThreadV1 = .{
        .runtime = &runtime,
        .workspace = &successor_workspace,
        .published = .{
            .identity = successor_identity,
            .handle = successor_handle,
        },
        .request_sha256 = [_]u8{0xd2} ** 32,
        .owner = successor_owner,
        .response_ready = &response_control.ready_reached,
    };

    const first_thread = try std.Thread.spawn(
        .{},
        FirstResponseGateThreadV1.run,
        .{&first_thread_context},
    );
    var first_joined = false;
    var successor_started = false;
    errdefer if (!successor_started) {
        response_control.ready_release.set();
        first_thread.join();
    };
    const successor_thread = try std.Thread.spawn(
        .{},
        SuccessorExecutionGateThreadV1.run,
        .{&successor_thread_context},
    );
    successor_started = true;
    var successor_joined = false;
    defer {
        response_control.ready_release.set();
        if (!successor_joined) successor_thread.join();
        if (!first_joined) first_thread.join();
    }

    try waitForResponseGateTestEventV1(
        &retirement_control.retired_reached,
    );
    try waitForResponseGateTestEventV1(
        &response_control.ready_reached,
    );
    try waitForResponseGateTestEventV1(
        &successor_thread_context.execution_finished,
    );
    try std.testing.expectEqualDeep(
        first_identity,
        retirement_control.retired_identity.?,
    );
    successor_thread.join();
    successor_joined = true;
    try std.testing.expect(
        successor_thread_context.thread_error == null,
    );
    try std.testing.expect(runtime.active_work == null);

    response_control.ready_release.set();
    try waitForResponseGateTestEventV1(
        &response_control.writing_reached,
    );
    try waitForResponseGateTestEventV1(
        &response_control.retired_reached,
    );
    first_thread.join();
    first_joined = true;
    try std.testing.expect(
        first_thread_context.thread_error == null,
    );
    try std.testing.expectEqual(
        ResponseWriteOutcomeV1.write_completed,
        response_control.outcome.?,
    );
}

test "full request timeout cancellation is exact sticky and observable" {
    const handle: unary.HandleV1 = .{
        .service_epoch = 73,
        .record_index = 5,
        .record_generation = 29,
        .intent_sha256 = [_]u8{0x63} ** 32,
        .handle_sha256 = [_]u8{0x84} ** 32,
    };
    const identity: WorkIdentityV1 = .{
        .sequence = 11,
        .handle_sha256 = handle.handle_sha256,
    };
    var runtime: RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
        .next_work_sequence = identity.sequence,
        .active_work = .{
            .sequence = identity.sequence,
            .handle = handle,
        },
    };

    var foreign_sequence = identity;
    foreign_sequence.sequence += 1;
    try std.testing.expectError(
        unary.Error.StaleHandle,
        cancelActiveWorkForFullRequestTimeoutV1(
            &runtime,
            foreign_sequence,
        ),
    );
    var foreign_digest = identity;
    foreign_digest.handle_sha256[0] ^= 0xff;
    try std.testing.expectError(
        unary.Error.StaleHandle,
        cancelActiveWorkForFullRequestTimeoutV1(
            &runtime,
            foreign_digest,
        ),
    );
    try std.testing.expect(
        runtime.active_work.?.stop_decision == null,
    );

    runtime.active_work.?.stop_decision = .{
        .requested_cause = .drain,
        .winner = .drain,
        .outcome = .cancelled,
        .cancellation_was_new = true,
    };
    const sticky =
        try cancelActiveWorkForFullRequestTimeoutV1(
            &runtime,
            identity,
        );
    try std.testing.expectEqual(
        WorkCancellationCauseV1.full_request_timeout,
        sticky.requested_cause,
    );
    try std.testing.expectEqual(
        WorkCancellationCauseV1.drain,
        sticky.winner.?,
    );
    try std.testing.expectEqual(
        DrainCancellationOutcomeV1.cancelled,
        sticky.outcome,
    );
    try std.testing.expect(!sticky.cancellation_was_new);
    try std.testing.expectEqual(
        WorkCancellationCauseV1.drain,
        runtime.active_work.?.stop_decision.?.requested_cause,
    );
    try std.testing.expect(
        runtime.active_work.?.stop_decision.?.cancellation_was_new,
    );

    runtime.active_work.?.stop_decision = .{
        .requested_cause = .full_request_timeout,
        .winner = .full_request_timeout,
        .outcome = .cancelled,
        .cancellation_was_new = true,
    };
    var test_control: FullRequestTimeoutTestControlV1 = .{};
    const published: PublishedWorkV1 = .{
        .identity = identity,
        .handle = handle,
    };
    const observed = (try observeWorkCheckpointV1(
        &runtime,
        published,
        test_control.control(),
    )) orelse return error.TestUnexpectedResult;
    const receipt = switch (observed) {
        .full_request_timeout => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), test_control.checkpoint_calls);
    try std.testing.expectEqual(@as(usize, 1), test_control.cancellation_calls);
    try std.testing.expectEqualDeep(
        identity,
        test_control.cancellation_identity.?,
    );
    try std.testing.expectEqualDeep(
        receipt,
        test_control.cancellation_receipt.?,
    );
    try std.testing.expectEqual(
        WorkCancellationCauseV1.full_request_timeout,
        receipt.requested_cause,
    );
    try std.testing.expectEqual(
        WorkCancellationCauseV1.full_request_timeout,
        receipt.winner.?,
    );
    try std.testing.expectEqual(
        DrainCancellationOutcomeV1.cancelled,
        receipt.outcome,
    );
    try std.testing.expect(!receipt.cancellation_was_new);
}

test "cancelled status rechecks full request timeout checkpoint" {
    const service_epoch: u64 = 89;
    const intent_sha256 = [_]u8{0xa5} ** 32;
    const handle = makeFullRequestTimeoutTestHandleV1(
        service_epoch,
        0,
        1,
        intent_sha256,
    );
    try std.testing.expect(unary.handleValidV1(handle));

    var active_slots = [_]unary.ActiveSlotV1{.{}};
    var intent: unary.IntentV1 = .{};
    intent.intent_sha256 = intent_sha256;
    var records = [_]unary.RecordSlotV1{.{
        .generation = handle.record_generation,
        .state = .cancelled,
        .intent = intent,
        .handle = handle,
        .cancellation = std.mem.zeroes(unary.CancellationV1),
    }};
    var service: unary.ServiceV1 = .{
        .state = .closed,
        .config = .{ .service_epoch = service_epoch },
        .active_slots = &active_slots,
        .records = &records,
    };
    service.self_address = @intFromPtr(&service);
    service.active_storage_address =
        @intFromPtr(active_slots[0..].ptr);
    service.record_storage_address =
        @intFromPtr(records[0..].ptr);

    const identity: WorkIdentityV1 = .{
        .sequence = 13,
        .handle_sha256 = handle.handle_sha256,
    };
    var runtime: RuntimeV1 = .{
        .service = &service,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
        .next_work_sequence = identity.sequence,
        .active_work = .{
            .sequence = identity.sequence,
            .handle = handle,
            .stop_decision = .{
                .requested_cause = .full_request_timeout,
                .winner = .full_request_timeout,
                .outcome = .cancelled,
                .cancellation_was_new = true,
            },
        },
    };
    var test_control: FullRequestTimeoutTestControlV1 = .{
        .proceed_checkpoints = 1,
    };
    const decision = try awaitResponseV1(
        &runtime,
        .{
            .identity = identity,
            .handle = handle,
        },
        test_control.control(),
    );
    const receipt = switch (decision) {
        .full_request_timeout => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), test_control.checkpoint_calls);
    try std.testing.expectEqual(@as(usize, 1), test_control.cancellation_calls);
    try std.testing.expectEqualDeep(
        identity,
        test_control.cancellation_identity.?,
    );
    try std.testing.expectEqualDeep(
        receipt,
        test_control.cancellation_receipt.?,
    );
    try std.testing.expectEqual(
        WorkCancellationCauseV1.full_request_timeout,
        receipt.requested_cause,
    );
    try std.testing.expectEqual(
        WorkCancellationCauseV1.full_request_timeout,
        receipt.winner.?,
    );
    try std.testing.expectEqual(
        DrainCancellationOutcomeV1.cancelled,
        receipt.outcome,
    );
    try std.testing.expect(!receipt.cancellation_was_new);
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
    response_control: ?RequestResponseControlV1,
) !void {
    request.head.expect = null;
    const body = try protocol.encodeErrorV1(.{
        .code = code,
        .retry = protocol.retryDispositionV1(code),
        .request_sha256 = request_sha256,
    }, &workspace.response);
    try respondV1(request, body, .{
        .status = protocol.httpStatusV1(code),
        .keep_alive = false,
        .extra_headers = &response_headers,
    }, response_control);
}

fn respondV1(
    request: *std.http.Server.Request,
    body: []const u8,
    options: std.http.Server.Request.RespondOptions,
    response_control: ?RequestResponseControlV1,
) !void {
    var guard: ResponseWriteGuardV1 = .{
        .control = response_control,
    };
    defer guard.retire();
    if (response_control) |control| {
        // Retirement is armed before the callback because a transport
        // decorator may fail after the managed lifecycle has published the
        // response-ready phase.
        guard.published = true;
        try control.ready();
        if (try control.writing() == .cancelled) {
            guard.outcome = .cancelled_before_write;
            return error.ConnectionResponseCancelledBeforeWrite;
        }
    }
    request.respond(body, options) catch |err| {
        guard.outcome = .write_failed;
        return err;
    };
    guard.outcome = .write_completed;
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
        TerminalError.TransportControlFailed => .internal_error,
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
