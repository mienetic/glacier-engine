const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const unary = engine.prepared_text_unary_service;
const protocol = engine.prepared_text_unary_http_v1;
const http_server = engine.prepared_text_unary_http_server;
const http_client = engine.prepared_text_unary_http_client;
const server_api = engine.server_api;
const native_report = engine.native_workload_report;

const fixture_license =
    "Glacier unary server process synthetic fixture\n";
const fixture_config =
    \\{"hidden_size":32,"intermediate_size":64,"num_hidden_layers":1,
    \\"vocab_size":256,"num_attention_heads":4,"num_key_value_heads":4,
    \\"rms_norm_eps":0.00001,"rope_theta":500000,
    \\"tie_word_embeddings":false}
    \\
;

const worker_mode = "worker";
const native_load_mode = "--native-load";
const loopback_host = "127.0.0.1";
const drain_command = "drain\n";
const drain_head_command = "drain-head\n";
const drain_body_command = "drain-body\n";
const drain_work_command = "drain-work\n";
const drain_terminal_work_command = "drain-terminal-work\n";
const peer_reset_arm_command = "peer-reset-arm\n";
const peer_reset_release_command = "peer-reset-release\n";
const peer_reset_drain_command = "peer-reset-drain\n";
const drain_response_ready_command = "drain-response-ready\n";
const complete_response_ready_command = "complete-response-ready\n";
const drain_response_writing_command =
    "drain-response-writing\n";
const complete_response_writing_command =
    "complete-response-writing\n";
const concurrent_release_command = "concurrent-release\n";
const concurrent_fault_command = "concurrent-stale-owner-failure\n";
const native_load_drain_command = "native-load-drain\n";
const prompt = "http-probe-6";
const generation_a: u64 = 0x4753_5052_0000_0101;
const generation_partial_head: u64 = 0x4753_5052_0000_0102;
const generation_partial_body: u64 = 0x4753_5052_0000_0103;
const generation_timeout_head: u64 = 0x4753_5052_0000_0104;
const generation_timeout_body: u64 = 0x4753_5052_0000_0105;
const generation_drain_work: u64 = 0x4753_5052_0000_0106;
const generation_drain_terminal_work: u64 =
    0x4753_5052_0000_0107;
const generation_peer_reset_work: u64 =
    0x4753_5052_0000_0108;
const generation_drain_response_ready: u64 =
    0x4753_5052_0000_0109;
const generation_complete_response_ready: u64 =
    0x4753_5052_0000_010a;
const generation_drain_response_writing: u64 =
    0x4753_5052_0000_010b;
const generation_complete_response_writing: u64 =
    0x4753_5052_0000_010c;
const generation_full_request_timeout_request_admitted: u64 =
    0x4753_5052_0000_010d;
const generation_full_request_timeout_response_ready: u64 =
    0x4753_5052_0000_010e;
const generation_full_request_timeout_response_writing: u64 =
    0x4753_5052_0000_010f;
const generation_b: u64 = 0x4753_5052_0000_0110;
const generation_concurrent_queued_receive_timeout: u64 =
    0x4753_5052_0000_0111;
const generation_concurrent_queued_full_request_timeout: u64 =
    0x4753_5052_0000_0112;
const generation_concurrent_drain: u64 =
    0x4753_5052_0000_0113;
const generation_concurrent_stale_owner_failure: u64 =
    0x4753_5052_0000_0114;
const generation_application_rejection: u64 =
    0x4753_5052_0000_0115;
const generation_native_load: u64 =
    0x4753_5052_0000_0116;
const frame_max_bytes = 1024;
const concurrent_event_capacity = 512;
const native_load_flow_count: usize = 8;
const native_load_warmup_count: usize = 8;
const native_load_measured_count: usize = 64;
const native_load_record_count: usize =
    native_load_warmup_count + native_load_measured_count;
const native_load_wave_count: usize =
    native_load_record_count / native_load_flow_count;
const native_load_worker_count: u8 = 2;
const native_load_pending_capacity: u8 = 8;
const native_load_sidecar_bytes: usize = 296;
const native_load_closure_u64_count: usize = 28;
const native_load_closure_bytes: usize =
    native_load_closure_u64_count * @sizeOf(u64);
const native_load_outer_header_bytes: usize = 40;
const native_load_outer_digest_bytes: usize = 64;
const native_load_inner_bytes: usize =
    native_report.minimum_encoded_bytes +
    native_load_record_count * native_report.record_wire_bytes;
const native_load_outer_bytes: usize =
    native_load_outer_header_bytes +
    native_load_record_count * native_load_sidecar_bytes +
    native_load_closure_bytes +
    native_load_inner_bytes +
    native_load_outer_digest_bytes;
const native_load_outer_magic =
    [_]u8{ 'G', 'F', '1', 'L', 'O', 'A', 'D', '1' };
const native_load_outer_abi: u64 =
    0x4746_314c_0000_0001;
const native_load_outer_body_domain =
    "glacier-f1-native-unary-load-body-v1\x00";
const native_load_outer_footer_domain =
    "glacier-f1-native-unary-load-footer-v1\x00";
const worker_timeout_ns = 15 * std.time.ns_per_s;
const watchdog_poll_ns = 10 * std.time.ns_per_ms;
const retained_receive_timeout_ns =
    std.time.ns_per_s;
const retained_full_request_timeout_ns =
    std.time.ns_per_s;
const retained_peer_reset_poll_timeout_ns =
    server_api.maximum_peer_reset_poll_timeout_ns;
const retained_receive_timeout_minimum_observation_ns =
    retained_receive_timeout_ns - 200 * std.time.ns_per_ms;
const retained_receive_timeout_maximum_observation_ns =
    retained_receive_timeout_ns + 400 * std.time.ns_per_ms;
const timeout_head_trickle_interval_ns = 200 * std.time.ns_per_ms;
const timeout_head_trickle_count = 3;
const control_poll_limit: usize = 500;

const WorkerProfile = enum {
    standard,
    drain_with_deadline,
    timeout_head,
    timeout_body,
    drain_work,
    drain_terminal_work,
    peer_reset_work,
    drain_response_ready,
    complete_response_ready,
    drain_response_writing,
    complete_response_writing,
    full_request_timeout_request_admitted,
    full_request_timeout_response_ready,
    full_request_timeout_response_writing,
    concurrent_queued_receive_timeout,
    concurrent_queued_full_request_timeout,
    concurrent_drain,
    concurrent_stale_owner_failure,
    application_rejection,
    native_load,

    fn wire(self: WorkerProfile) []const u8 {
        return switch (self) {
            .standard => "standard",
            .drain_with_deadline => "drain-with-deadline",
            .timeout_head => "timeout-head",
            .timeout_body => "timeout-body",
            .drain_work => "drain-work",
            .drain_terminal_work => "drain-terminal-work",
            .peer_reset_work => "peer-reset-work",
            .drain_response_ready => "drain-response-ready",
            .complete_response_ready => "complete-response-ready",
            .drain_response_writing => "drain-response-writing",
            .complete_response_writing => "complete-response-writing",
            .full_request_timeout_request_admitted => "full-request-timeout-request-admitted",
            .full_request_timeout_response_ready => "full-request-timeout-response-ready",
            .full_request_timeout_response_writing => "full-request-timeout-response-writing",
            .concurrent_queued_receive_timeout => "concurrent-queued-receive-timeout",
            .concurrent_queued_full_request_timeout => "concurrent-queued-full-request-timeout",
            .concurrent_drain => "concurrent-drain",
            .concurrent_stale_owner_failure => "concurrent-stale-owner-failure",
            .application_rejection => "application-rejection",
            .native_load => "native-load",
        };
    }

    fn parse(value: []const u8) !WorkerProfile {
        inline for (std.meta.tags(WorkerProfile)) |profile| {
            if (std.mem.eql(u8, value, profile.wire()))
                return profile;
        }
        return error.InvalidWorkerProfile;
    }

    fn timeoutPhase(
        self: WorkerProfile,
    ) ?server_api.ManagedConnectionPhaseV1 {
        return switch (self) {
            .standard,
            .drain_with_deadline,
            .drain_work,
            .drain_terminal_work,
            .peer_reset_work,
            .drain_response_ready,
            .complete_response_ready,
            .drain_response_writing,
            .complete_response_writing,
            .full_request_timeout_request_admitted,
            .full_request_timeout_response_ready,
            .full_request_timeout_response_writing,
            .concurrent_queued_receive_timeout,
            .concurrent_queued_full_request_timeout,
            .concurrent_drain,
            .concurrent_stale_owner_failure,
            .application_rejection,
            .native_load,
            => null,
            .timeout_head => .receiving_head,
            .timeout_body => .request_head_received,
        };
    }

    fn receiveTimeoutNs(self: WorkerProfile) u64 {
        return switch (self) {
            .standard => 0,
            .drain_with_deadline => server_api.maximum_receive_timeout_ns,
            .timeout_head, .timeout_body => retained_receive_timeout_ns,
            .drain_work,
            .drain_terminal_work,
            .peer_reset_work,
            .drain_response_ready,
            .complete_response_ready,
            .drain_response_writing,
            .complete_response_writing,
            .full_request_timeout_request_admitted,
            .full_request_timeout_response_ready,
            .full_request_timeout_response_writing,
            .concurrent_queued_full_request_timeout,
            .concurrent_drain,
            .concurrent_stale_owner_failure,
            .application_rejection,
            .native_load,
            => 0,
            .concurrent_queued_receive_timeout => retained_receive_timeout_ns,
        };
    }

    fn fullRequestTimeoutPhase(
        self: WorkerProfile,
    ) ?server_api.ManagedConnectionPhaseV1 {
        return switch (self) {
            .full_request_timeout_request_admitted => .request_admitted,
            .full_request_timeout_response_ready => .response_ready,
            .full_request_timeout_response_writing => .response_writing,
            else => null,
        };
    }

    fn fullRequestTimeoutNs(self: WorkerProfile) u64 {
        if (self == .concurrent_queued_full_request_timeout)
            return retained_full_request_timeout_ns;
        if (self.isFullRequestTimeout())
            return retained_full_request_timeout_ns;
        if (self == .complete_response_writing)
            return server_api.maximum_full_request_timeout_ns;
        return 0;
    }

    fn isFullRequestTimeout(self: WorkerProfile) bool {
        return self.fullRequestTimeoutPhase() != null;
    }

    fn peerResetPollTimeoutNs(self: WorkerProfile) u64 {
        return if (self == .peer_reset_work)
            retained_peer_reset_poll_timeout_ns
        else
            0;
    }

    fn usesWorkBarrier(self: WorkerProfile) bool {
        return self == .drain_work or
            self == .drain_terminal_work or
            self == .peer_reset_work or
            self == .full_request_timeout_request_admitted;
    }

    fn usesResponseBarrier(self: WorkerProfile) bool {
        return self == .drain_response_ready or
            self == .complete_response_ready or
            self == .full_request_timeout_response_ready or
            self.usesResponseProgressBarrier();
    }

    fn usesResponseProgressBarrier(self: WorkerProfile) bool {
        return self == .drain_response_writing or
            self == .complete_response_writing or
            self == .full_request_timeout_response_writing;
    }

    fn responseWriteQuantumBytes(self: WorkerProfile) u16 {
        return if (self.usesResponseProgressBarrier())
            1
        else
            server_api.maximum_response_write_quantum_bytes;
    }

    fn isPhaseE(self: WorkerProfile) bool {
        return self == .peer_reset_work or
            self.usesResponseBarrier() or
            self.isFullRequestTimeout();
    }

    fn isConcurrent(self: WorkerProfile) bool {
        return switch (self) {
            .concurrent_queued_receive_timeout,
            .concurrent_queued_full_request_timeout,
            .concurrent_drain,
            .concurrent_stale_owner_failure,
            .native_load,
            => true,
            .application_rejection => false,
            else => false,
        };
    }
};

pub fn main() !void {
    if (comptime engine.bounded_file_input.availableV1() and
        std.process.can_spawn)
    {
        return supportedMain();
    }
}

fn supportedMain() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 1) {
        return runSupervisor(allocator);
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], native_load_mode))
    {
        return runNativeLoadSupervisor(
            allocator,
            args[2],
            args[3],
            args[4],
        );
    }
    if (args.len != 7 or
        !std.mem.eql(u8, args[1], worker_mode))
    {
        return error.InvalidUsage;
    }
    const generation = try parseCanonicalInt(u64, args[5]);
    const profile = try WorkerProfile.parse(args[6]);
    runWorker(
        allocator,
        args[2],
        args[3],
        args[4],
        generation,
        profile,
    ) catch std.process.exit(2);
}

const Fixture = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    source_path: []u8,
    portable_path: []u8,
    prepared_path: []u8,
    package_path: []u8,
    config_path: []u8,
    license_path: []u8,
    bundle: engine.model_package_manifest.AdmissionBundleV2,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const source_path = try pathInTmp(
            allocator,
            &tmp,
            "server-process.safetensors",
        );
        errdefer allocator.free(source_path);
        const portable_path = try pathInTmp(
            allocator,
            &tmp,
            "server-process.glacier",
        );
        errdefer allocator.free(portable_path);
        const prepared_path = try pathInTmp(
            allocator,
            &tmp,
            "server-process.glrt",
        );
        errdefer allocator.free(prepared_path);
        const package_path = try pathInTmp(
            allocator,
            &tmp,
            "server-process.glpkg",
        );
        errdefer allocator.free(package_path);
        const config_path = try pathInTmp(
            allocator,
            &tmp,
            "server-process-config.json",
        );
        errdefer allocator.free(config_path);
        const license_path = try pathInTmp(
            allocator,
            &tmp,
            "server-process-license.txt",
        );
        errdefer allocator.free(license_path);

        try engine.fixture_gen.writeSafetensors(
            source_path,
            .{
                .dim = 32,
                .hidden_dim = 64,
                .num_layers = 1,
                .vocab_size = 256,
            },
        );
        try writeFile(config_path, fixture_config);
        try writeFile(license_path, fixture_license);
        const produced =
            try engine.model_package_producer.produceSafetensorsV1(
                allocator,
                source_path,
                portable_path,
                prepared_path,
                package_path,
                license_path,
                .{
                    .experimental_profile = .ordinary_package_v1,
                    .config_path = config_path,
                    .conversion = .{
                        .architecture = engine.model_package_producer
                            .conversion_architecture_v1,
                        .quantize_int4 = true,
                        .quant_group_size = 16,
                    },
                },
            );

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .source_path = source_path,
            .portable_path = portable_path,
            .prepared_path = prepared_path,
            .package_path = package_path,
            .config_path = config_path,
            .license_path = license_path,
            .bundle = .{
                .package = produced.package,
                .representation = produced.representation,
            },
        };
    }

    fn deinit(self: *Fixture) void {
        self.allocator.free(self.license_path);
        self.allocator.free(self.config_path);
        self.allocator.free(self.package_path);
        self.allocator.free(self.prepared_path);
        self.allocator.free(self.portable_path);
        self.allocator.free(self.source_path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn pathInTmp(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    basename: []const u8,
) ![]u8 {
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, basename });
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const file = try std.fs.cwd().createFile(
        path,
        .{ .truncate = true },
    );
    defer file.close();
    try file.writeAll(contents);
}

fn ServiceHarness(
    comptime active_capacity: usize,
    comptime record_capacity: usize,
) type {
    return struct {
        bank_slots: [active_capacity]engine.resource_bank.Slot =
            [_]engine.resource_bank.Slot{.{}} ** active_capacity,
        lane_slots: [active_capacity]engine.lane_weave_qos.Slot =
            [_]engine.lane_weave_qos.Slot{.{}} ** active_capacity,
        projection: [active_capacity]engine.lane_weave_qos.ProjectionSlot =
            [_]engine.lane_weave_qos.ProjectionSlot{.{}} **
            active_capacity,
        active: [active_capacity]unary.ActiveSlotV1 =
            [_]unary.ActiveSlotV1{.{}} ** active_capacity,
        records: [record_capacity]unary.RecordSlotV1 =
            [_]unary.RecordSlotV1{.{}} ** record_capacity,
        bank: engine.resource_bank.Bank = undefined,
        scheduler: engine.lane_weave_qos.Scheduler = undefined,
        service: unary.ServiceV1 = .{},

        fn init(
            self: *@This(),
            allocator: std.mem.Allocator,
            binding: unary.ModelBindingV1,
            service_epoch: u64,
        ) !void {
            self.bank = try engine.resource_bank.Bank.init(
                &self.bank_slots,
                .{},
                service_epoch ^ 0x4241_4e4b,
            );
            self.scheduler =
                try engine.lane_weave_qos.Scheduler.init(
                    &self.bank,
                    .{
                        .slots = &self.lane_slots,
                        .projection = &self.projection,
                    },
                    .{
                        .scheduler_epoch = service_epoch ^ 0x5343_4844,
                        .coordinator_id = service_epoch ^ 0x434f_4f52,
                        .challenge = engine.core.model_contract.sha256(
                            "unary server process scheduler challenge",
                        ),
                        .max_weight = 1,
                    },
                );
            try self.service.init(
                allocator,
                binding,
                &self.scheduler,
                &self.bank,
                &self.active,
                &self.records,
                .{ .service_epoch = service_epoch },
            );
        }
    };
}

const ServeContext = struct {
    listener: *std.net.Server,
    runtime: *http_server.RuntimeV1,
    lifecycle: *server_api.ManagedLifecycleV1,
    config: server_api.ServerConfig,
    work_observer: ?http_server.RequestWorkControlV1 = null,
    response_observer: ?http_server.RequestResponseControlV1 = null,
    thread_error: ?anyerror = null,

    fn run(self: *ServeContext) void {
        server_api.serveManagedListenerWithObserversV1(
            self.listener,
            self.config,
            self.runtime,
            self.lifecycle,
            self.work_observer,
            self.response_observer,
        ) catch |err| {
            self.thread_error = err;
        };
    }
};

const ConcurrentServeContext = struct {
    listener: *std.net.Server,
    runtime: *http_server.RuntimeV1,
    lifecycle: *server_api.ManagedConcurrentLifecycleV1,
    config: server_api.ServerConfig,
    event_observer: ?server_api.ManagedConcurrentObserverV1 = null,
    work_observer: ?http_server.RequestWorkControlV1 = null,
    thread_error: ?anyerror = null,

    fn run(self: *ConcurrentServeContext) void {
        server_api.serveManagedConcurrentListenerWithControlsV1(
            self.listener,
            self.config,
            self.runtime,
            self.lifecycle,
            .{
                .event_observer = self.event_observer,
                .work_control = self.work_observer,
            },
        ) catch |err| {
            self.thread_error = err;
        };
    }
};

const ConcurrentEventLog = struct {
    mutex: std.Thread.Mutex = .{},
    changed: std.Thread.Condition = .{},
    events: [concurrent_event_capacity]server_api.ManagedConcurrentEventV1 =
        undefined,
    event_count: usize = 0,
    overflowed: bool = false,

    fn observer(
        self: *ConcurrentEventLog,
    ) server_api.ManagedConcurrentObserverV1 {
        return .{
            .context = self,
            .event_fn = eventOpaque,
        };
    }

    fn eventOpaque(
        context: *anyopaque,
        event: server_api.ManagedConcurrentEventV1,
    ) void {
        const self: *ConcurrentEventLog =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        if (self.event_count == self.events.len) {
            self.overflowed = true;
        } else {
            self.events[self.event_count] = event;
            self.event_count += 1;
        }
        self.changed.broadcast();
        self.mutex.unlock();
    }

    fn waitForKind(
        self: *ConcurrentEventLog,
        kind: server_api.ManagedConcurrentEventKindV1,
        occurrence: usize,
    ) !server_api.ManagedConcurrentEventV1 {
        if (occurrence == 0)
            return error.InvalidConcurrentEventOccurrence;
        var timer = try std.time.Timer.start();
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.overflowed)
                return error.ConcurrentEventLogOverflow;
            var seen: usize = 0;
            for (self.events[0..self.event_count]) |event| {
                if (event.kind != kind) continue;
                seen += 1;
                if (seen == occurrence) return event;
            }
            const elapsed_ns = timer.read();
            if (elapsed_ns >= worker_timeout_ns)
                return error.ConcurrentEventTimedOut;
            self.changed.timedWait(
                &self.mutex,
                worker_timeout_ns - elapsed_ns,
            ) catch return error.ConcurrentEventTimedOut;
        }
    }

    fn countKind(
        self: *ConcurrentEventLog,
        kind: server_api.ManagedConcurrentEventKindV1,
    ) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.overflowed)
            return error.ConcurrentEventLogOverflow;
        var count: usize = 0;
        for (self.events[0..self.event_count]) |event| {
            if (event.kind == kind) count += 1;
        }
        return count;
    }

    fn totalCount(self: *ConcurrentEventLog) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.overflowed)
            return error.ConcurrentEventLogOverflow;
        return self.event_count;
    }

    fn validateOrdinals(self: *ConcurrentEventLog) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.overflowed)
            return error.ConcurrentEventLogOverflow;
        var seen = [_]bool{false} ** concurrent_event_capacity;
        for (self.events[0..self.event_count]) |event| {
            if (event.ordinal == 0 or
                event.ordinal > self.event_count)
            {
                return error.InvalidConcurrentEventOrdinal;
            }
            const index: usize =
                @intCast(event.ordinal - 1);
            if (seen[index])
                return error.DuplicateConcurrentEventOrdinal;
            seen[index] = true;
        }
        for (seen[0..self.event_count]) |present| {
            if (!present)
                return error.MissingConcurrentEventOrdinal;
        }
    }

    fn waitForRetiredCount(
        self: *ConcurrentEventLog,
        expected: usize,
    ) !void {
        var timer = try std.time.Timer.start();
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.overflowed)
                return error.ConcurrentEventLogOverflow;
            var retired: usize = 0;
            for (self.events[0..self.event_count]) |event| {
                if (event.kind == .retired) retired += 1;
            }
            if (retired >= expected) return;
            const elapsed_ns = timer.read();
            if (elapsed_ns >= worker_timeout_ns)
                return error.ConcurrentEventTimedOut;
            self.changed.timedWait(
                &self.mutex,
                worker_timeout_ns - elapsed_ns,
            ) catch return error.ConcurrentEventTimedOut;
        }
    }
};

fn nativeLoadMonotonicNs() !u64 {
    const tag = builtin.os.tag;
    if (comptime tag == .windows or tag == .wasi or
        tag == .uefi)
    {
        return error.NativeLoadClockUnavailable;
    }
    const clock_id = if (comptime tag == .macos or
        tag == .ios or tag == .tvos or tag == .watchos or
        tag == .visionos)
        std.posix.CLOCK.UPTIME_RAW
    else if (comptime tag == .linux)
        std.posix.CLOCK.MONOTONIC_RAW
    else
        std.posix.CLOCK.MONOTONIC;
    const timestamp = std.posix.clock_gettime(clock_id) catch
        return error.NativeLoadClockUnavailable;
    const seconds = std.math.cast(
        u64,
        timestamp.sec,
    ) orelse return error.NativeLoadClockInvalid;
    const nanoseconds = std.math.cast(
        u64,
        timestamp.nsec,
    ) orelse return error.NativeLoadClockInvalid;
    if (nanoseconds >= std.time.ns_per_s)
        return error.NativeLoadClockInvalid;
    return std.math.add(
        u64,
        std.math.mul(
            u64,
            seconds,
            std.time.ns_per_s,
        ) catch return error.NativeLoadClockOverflow,
        nanoseconds,
    ) catch return error.NativeLoadClockOverflow;
}

const NativeLoadWorkRecord = struct {
    publication: http_server.WorkPublicationV1,
    published_ns: u64,
    retired: bool = false,
};

const NativeLoadWorkLog = struct {
    mutex: std.Thread.Mutex = .{},
    records: [native_load_record_count]NativeLoadWorkRecord =
        undefined,
    count: usize = 0,
    invalid: bool = false,

    fn admittedOpaque(
        context: *anyopaque,
        identity: http_server.WorkIdentityV1,
    ) anyerror!http_server.WorkDispositionV1 {
        _ = context;
        _ = identity;
        return .proceed;
    }

    fn publishedOpaque(
        context: *anyopaque,
        publication: http_server.WorkPublicationV1,
    ) void {
        const self: *NativeLoadWorkLog =
            @ptrCast(@alignCast(context));
        const observed_ns = nativeLoadMonotonicNs() catch 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (observed_ns == 0 or
            publication.transport_owner == null or
            self.count == self.records.len)
        {
            self.invalid = true;
            return;
        }
        for (self.records[0..self.count]) |record| {
            if (std.mem.eql(
                u8,
                &record.publication.request_sha256,
                &publication.request_sha256,
            ) or std.meta.eql(
                record.publication.identity,
                publication.identity,
            )) {
                self.invalid = true;
                return;
            }
        }
        self.records[self.count] = .{
            .publication = publication,
            .published_ns = observed_ns,
        };
        self.count += 1;
    }

    fn retiredOpaque(
        context: *anyopaque,
        identity: http_server.WorkIdentityV1,
    ) void {
        const self: *NativeLoadWorkLog =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        var matched = false;
        for (self.records[0..self.count]) |*record| {
            if (!std.meta.eql(
                record.publication.identity,
                identity,
            )) continue;
            if (matched or record.retired) {
                self.invalid = true;
                return;
            }
            record.retired = true;
            matched = true;
        }
        if (!matched) self.invalid = true;
    }

    fn control(
        self: *NativeLoadWorkLog,
    ) http_server.RequestWorkControlV1 {
        return .{
            .context = self,
            .admitted_fn = admittedOpaque,
            .retired_fn = retiredOpaque,
            .published_fn = publishedOpaque,
        };
    }

    fn validateComplete(self: *NativeLoadWorkLog) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.invalid or self.count != self.records.len)
            return error.InvalidNativeLoadWorkLog;
        for (self.records[0..self.count]) |record| {
            if (!record.retired)
                return error.InvalidNativeLoadWorkRetirement;
        }
    }
};

const NativeLoadServerRecord = struct {
    request_sha256: protocol.Digest,
    handle_sha256: protocol.Digest,
    work_sequence: u64,
    process_generation: u64,
    connection_sequence: u64,
    slot_generation: u64,
    slot_index: u8,
    worker_index: u8,
    enqueue_ordinal: u64,
    dispatch_ordinal: u64,
    retired_ordinal: u64,
    enqueue_ns: u64,
    dispatch_ns: u64,
    published_ns: u64,
    retired_ns: u64,
};

fn sameNativeLoadLease(
    lease: server_api.ManagedConnectionLeaseV1,
    owner: http_server.TransportOwnerTokenV1,
) bool {
    return lease.process_generation ==
        owner.process_generation and
        lease.connection_sequence ==
            owner.connection_sequence and
        lease.slot_index == owner.slot_index and
        lease.slot_generation == owner.slot_generation;
}

fn collectNativeLoadServerRecords(
    work_log: *NativeLoadWorkLog,
    event_log: *ConcurrentEventLog,
    destination: *[native_load_record_count]NativeLoadServerRecord,
) !void {
    try work_log.validateComplete();
    work_log.mutex.lock();
    defer work_log.mutex.unlock();
    event_log.mutex.lock();
    defer event_log.mutex.unlock();
    if (event_log.overflowed)
        return error.ConcurrentEventLogOverflow;

    for (work_log.records[0..work_log.count], 0..) |
        work,
        output_index,
    | {
        const owner = work.publication.transport_owner orelse
            return error.MissingNativeLoadTransportOwner;
        var enqueue: ?server_api.ManagedConcurrentEventV1 =
            null;
        var dispatch: ?server_api.ManagedConcurrentEventV1 =
            null;
        var retired: ?server_api.ManagedConcurrentEventV1 =
            null;
        var enqueue_ns: u64 = 0;
        var dispatch_ns: u64 = 0;
        var retired_ns: u64 = 0;
        for (
            event_log.events[0..event_log.event_count],
        ) |event| {
            const lease = event.lease orelse continue;
            if (!sameNativeLoadLease(lease, owner)) continue;
            switch (event.kind) {
                .enqueued => {
                    if (enqueue != null)
                        return error.DuplicateNativeLoadEnqueue;
                    enqueue = event;
                    enqueue_ns =
                        event.linearized_monotonic_ns;
                },
                .dispatched => {
                    if (dispatch != null)
                        return error.DuplicateNativeLoadDispatch;
                    dispatch = event;
                    dispatch_ns =
                        event.linearized_monotonic_ns;
                },
                .retired => {
                    if (retired != null)
                        return error.DuplicateNativeLoadRetirement;
                    retired = event;
                    retired_ns =
                        event.linearized_monotonic_ns;
                },
                else => {},
            }
        }
        const enqueued = enqueue orelse
            return error.MissingNativeLoadEnqueue;
        const dispatched = dispatch orelse
            return error.MissingNativeLoadDispatch;
        const settled = retired orelse
            return error.MissingNativeLoadRetirement;
        const worker_index = dispatched.worker_index orelse
            return error.MissingNativeLoadWorker;
        if (settled.worker_index != worker_index or
            enqueue_ns == 0 or dispatch_ns == 0 or
            work.published_ns == 0 or retired_ns == 0 or
            enqueue_ns > dispatch_ns or
            dispatch_ns > work.published_ns or
            work.published_ns > retired_ns or
            enqueued.ordinal >= dispatched.ordinal or
            dispatched.ordinal >= settled.ordinal)
        {
            return error.InvalidNativeLoadServerTimeline;
        }
        destination[output_index] = .{
            .request_sha256 = work.publication.request_sha256,
            .handle_sha256 = work.publication.identity.handle_sha256,
            .work_sequence = work.publication.identity.sequence,
            .process_generation = owner.process_generation,
            .connection_sequence = owner.connection_sequence,
            .slot_generation = owner.slot_generation,
            .slot_index = owner.slot_index,
            .worker_index = worker_index,
            .enqueue_ordinal = enqueued.ordinal,
            .dispatch_ordinal = dispatched.ordinal,
            .retired_ordinal = settled.ordinal,
            .enqueue_ns = enqueue_ns,
            .dispatch_ns = dispatch_ns,
            .published_ns = work.published_ns,
            .retired_ns = retired_ns,
        };
    }
}

const ConcurrentDrainRequest = struct {
    lifecycle: *server_api.ManagedConcurrentLifecycleV1,
    runtime: *http_server.RuntimeV1,
    listen_address: std.net.Address,
    start: *std.Thread.ResetEvent,
    ready: std.Thread.ResetEvent = .{},
    entered: std.Thread.ResetEvent = .{},
    done: std.Thread.ResetEvent = .{},
    thread_error: ?anyerror = null,

    fn run(self: *ConcurrentDrainRequest) void {
        self.ready.set();
        self.start.wait();
        self.entered.set();
        server_api.requestManagedConcurrentDrainAndWakeV1(
            self.lifecycle,
            self.runtime,
            self.listen_address,
        ) catch |err| {
            self.thread_error = err;
        };
        self.done.set();
    }
};

const WorkAdmissionBarrierV1 = struct {
    reached: std.Thread.ResetEvent = .{},
    release: std.Thread.ResetEvent = .{},
    passthrough_after_first: bool = false,
    identity: ?http_server.WorkIdentityV1 = null,
    retired: bool = false,
    retired_count: usize = 0,
    retire_identity_mismatch: bool = false,
    cancellation: ?http_server.WorkCancellationReceiptV1 = null,
    cancellation_identity_mismatch: bool = false,
    checkpoint_failed: bool = false,
    checkpoint_result_reached: std.Thread.ResetEvent = .{},
    retired_reached: std.Thread.ResetEvent = .{},
    rejections: [2]http_server.RequestAdmissionRejectionV1 =
        undefined,
    rejection_count: usize = 0,
    rejection_overflowed: bool = false,

    fn admittedOpaque(
        context: *anyopaque,
        identity: http_server.WorkIdentityV1,
    ) anyerror!http_server.WorkDispositionV1 {
        const self: *WorkAdmissionBarrierV1 =
            @ptrCast(@alignCast(context));
        if (self.identity != null) {
            if (self.passthrough_after_first)
                return .proceed;
            return error.DuplicateWorkAdmission;
        }
        self.identity = identity;
        self.reached.set();
        self.release.wait();
        return .proceed;
    }

    fn retiredOpaque(
        context: *anyopaque,
        identity: http_server.WorkIdentityV1,
    ) void {
        const self: *WorkAdmissionBarrierV1 =
            @ptrCast(@alignCast(context));
        const admitted_identity = self.identity orelse {
            self.retire_identity_mismatch = true;
            return;
        };
        if (!std.meta.eql(admitted_identity, identity)) {
            if (self.passthrough_after_first) return;
            self.retire_identity_mismatch = true;
            return;
        }
        self.retired_count += 1;
        self.retired = true;
        self.retired_reached.set();
    }

    fn rejectedOpaque(
        context: *anyopaque,
        rejection: http_server.RequestAdmissionRejectionV1,
    ) void {
        const self: *WorkAdmissionBarrierV1 =
            @ptrCast(@alignCast(context));
        if (self.rejection_count == self.rejections.len) {
            self.rejection_overflowed = true;
            return;
        }
        self.rejections[self.rejection_count] = rejection;
        self.rejection_count += 1;
    }

    fn cancellationOpaque(
        context: *anyopaque,
        identity: http_server.WorkIdentityV1,
        receipt: http_server.WorkCancellationReceiptV1,
    ) void {
        const self: *WorkAdmissionBarrierV1 =
            @ptrCast(@alignCast(context));
        const admitted_identity = self.identity orelse {
            self.cancellation_identity_mismatch = true;
            self.checkpoint_result_reached.set();
            return;
        };
        if (!std.meta.eql(admitted_identity, identity)) {
            if (self.passthrough_after_first) return;
            self.cancellation_identity_mismatch = true;
            self.checkpoint_result_reached.set();
            return;
        }
        if (self.cancellation != null) {
            self.cancellation_identity_mismatch = true;
            self.checkpoint_result_reached.set();
            return;
        }
        self.cancellation = receipt;
        self.checkpoint_result_reached.set();
    }

    fn unobservedPeerResetOpaque(
        context: *anyopaque,
        identity: http_server.WorkIdentityV1,
    ) anyerror!http_server.WorkCheckpointDispositionV1 {
        const self: *WorkAdmissionBarrierV1 =
            @ptrCast(@alignCast(context));
        const admitted_identity = self.identity orelse
            return error.MissingWorkAdmission;
        if (!std.meta.eql(admitted_identity, identity))
            return error.WorkIdentityMismatch;
        self.checkpoint_failed = true;
        self.checkpoint_result_reached.set();
        return error.PeerResetPollTimedOut;
    }

    fn control(
        self: *WorkAdmissionBarrierV1,
        require_peer_reset: bool,
    ) http_server.RequestWorkControlV1 {
        return .{
            .context = self,
            .admitted_fn = admittedOpaque,
            .retired_fn = retiredOpaque,
            .checkpoint_fn = if (require_peer_reset)
                unobservedPeerResetOpaque
            else
                null,
            .cancellation_fn = cancellationOpaque,
            .admission_rejected_fn = rejectedOpaque,
        };
    }
};

const ResponseReadyBarrierV1 = struct {
    reached: std.Thread.ResetEvent = .{},
    release: std.Thread.ResetEvent = .{},
    progress_reached: std.Thread.ResetEvent = .{},
    progress_release: std.Thread.ResetEvent = .{},
    retired_reached: std.Thread.ResetEvent = .{},
    ready_calls: u8 = 0,
    writing_calls: u8 = 0,
    progress_calls: u64 = 0,
    progress_bytes: u64 = 0,
    outcome: ?http_server.ResponseWriteOutcomeV1 = null,
    passthrough_response: bool = false,

    fn readyOpaque(context: *anyopaque) anyerror!void {
        const self: *ResponseReadyBarrierV1 =
            @ptrCast(@alignCast(context));
        if (self.outcome != null) {
            self.passthrough_response = true;
            return;
        }
        if (self.ready_calls != 0)
            return error.DuplicateResponseReady;
        self.ready_calls = 1;
        self.reached.set();
        self.release.wait();
    }

    fn writingOpaque(
        context: *anyopaque,
    ) anyerror!http_server.ResponseWriteDispositionV1 {
        const self: *ResponseReadyBarrierV1 =
            @ptrCast(@alignCast(context));
        if (self.passthrough_response)
            return .proceed;
        if (self.writing_calls != 0)
            return error.DuplicateResponseWriting;
        self.writing_calls = 1;
        return .proceed;
    }

    fn progressOpaque(
        context: *anyopaque,
        bytes_sent: usize,
    ) anyerror!void {
        const self: *ResponseReadyBarrierV1 =
            @ptrCast(@alignCast(context));
        if (self.passthrough_response) return;
        if (bytes_sent != 1)
            return error.InvalidResponseWriteProgress;
        self.progress_calls = try std.math.add(
            u64,
            self.progress_calls,
            1,
        );
        self.progress_bytes = try std.math.add(
            u64,
            self.progress_bytes,
            @intCast(bytes_sent),
        );
        if (self.progress_calls == 1) {
            self.progress_reached.set();
            self.progress_release.wait();
        }
    }

    fn retiredOpaque(
        context: *anyopaque,
        outcome: http_server.ResponseWriteOutcomeV1,
    ) void {
        const self: *ResponseReadyBarrierV1 =
            @ptrCast(@alignCast(context));
        if (self.passthrough_response) {
            self.passthrough_response = false;
            return;
        }
        if (self.outcome != null) {
            self.outcome = .write_failed;
        } else {
            self.outcome = outcome;
        }
        self.retired_reached.set();
    }

    fn control(
        self: *ResponseReadyBarrierV1,
        observe_progress: bool,
    ) http_server.RequestResponseControlV1 {
        return .{
            .context = self,
            .ready_fn = readyOpaque,
            .writing_fn = writingOpaque,
            .retired_fn = retiredOpaque,
            .progress_fn = if (observe_progress)
                progressOpaque
            else
                null,
        };
    }
};

fn runWorker(
    allocator: std.mem.Allocator,
    prepared_path: []const u8,
    package_path: []const u8,
    license_path: []const u8,
    generation: u64,
    profile: WorkerProfile,
) !void {
    const package_bytes = try engine.bounded_file_input.readAllocV1(
        allocator,
        package_path,
        engine.model_package_manifest.admission_bundle_bytes,
    );
    defer allocator.free(package_bytes);
    if (package_bytes.len !=
        engine.model_package_manifest.admission_bundle_bytes)
    {
        return error.InvalidPackageLength;
    }
    const bundle =
        try engine.model_package_manifest.decodeAdmissionBundleV2(
            package_bytes,
        );
    _ = try engine.model_package_producer.validateSupportedPackageV1(
        bundle.package,
    );

    const license_bytes = try engine.bounded_file_input.readAllocV1(
        allocator,
        license_path,
        engine.model_package_producer.maximum_license_bytes,
    );
    defer allocator.free(license_bytes);
    const license_byte_count = std.math.cast(
        u64,
        license_bytes.len,
    ) orelse return error.InvalidLicense;
    const license_sha256 =
        engine.core.model_contract.sha256(license_bytes);
    if (bundle.package.license_bytes != license_byte_count or
        !std.mem.eql(
            u8,
            &bundle.package.license_sha256,
            &license_sha256,
        ))
    {
        return error.PackageLicenseMismatch;
    }

    const model_file =
        try engine.bounded_file_input.openRegularV1(prepared_path);
    var model =
        try engine.loader.loadPreparedOwnedFileWithOptionsV1(
            allocator,
            model_file,
            .{
                .expected_source_fingerprint = bundle.package.model_content_sha256,
                .mlp_layout = .separate_required,
            },
        );
    defer model.deinit();
    const binding = try unary.bindModelV1(
        &model,
        bundle,
        license_byte_count,
        license_sha256,
    );
    if (profile == .application_rejection) {
        return runApplicationRejectionWorker(
            allocator,
            binding,
            generation,
        );
    }
    if (profile == .native_load) {
        return runNativeLoadWorker(
            allocator,
            binding,
            generation,
        );
    }
    if (profile.isConcurrent()) {
        return runConcurrentWorker(
            allocator,
            binding,
            generation,
            profile,
        );
    }

    var lifecycle =
        try server_api.ManagedLifecycleV1.initV1(generation);
    var harness: ServiceHarness(1, 4) = .{};
    try harness.init(
        allocator,
        binding,
        generation,
    );
    var runtime = try http_server.initV1(
        &harness.service,
        binding.binding_sha256,
    );

    const bind_address =
        try std.net.Address.parseIp(loopback_host, 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const listen_address = listener.listen_address;

    try lifecycle.markReadyV1();
    var work_barrier: WorkAdmissionBarrierV1 = .{};
    var response_barrier: ResponseReadyBarrierV1 = .{};
    var serve_context: ServeContext = .{
        .listener = &listener,
        .runtime = &runtime,
        .lifecycle = &lifecycle,
        .config = .{
            .receive_timeout_ns = profile.receiveTimeoutNs(),
            .full_request_timeout_ns = profile.fullRequestTimeoutNs(),
            .peer_reset_poll_timeout_ns = profile.peerResetPollTimeoutNs(),
            .response_write_quantum_bytes = profile.responseWriteQuantumBytes(),
        },
        .work_observer = if (profile.usesWorkBarrier())
            work_barrier.control(profile == .peer_reset_work)
        else
            null,
        .response_observer = if (profile.usesResponseBarrier())
            response_barrier.control(
                profile.usesResponseProgressBarrier(),
            )
        else
            null,
    };
    const serve_thread = try std.Thread.spawn(
        .{},
        ServeContext.run,
        .{&serve_context},
    );
    var joined = false;
    defer if (!joined) {
        if (profile.usesWorkBarrier())
            work_barrier.release.set();
        if (profile.usesResponseBarrier())
            response_barrier.release.set();
        if (profile.usesResponseProgressBarrier())
            response_barrier.progress_release.set();
        forceDrainAndWake(
            &lifecycle,
            &runtime,
            listen_address,
        );
        serve_thread.join();
    };

    try emitReady(
        generation,
        listen_address.getPort(),
        &runtime.model_id,
    );
    if (profile.timeoutPhase()) |phase| {
        const timed_out = try waitForReceiveTimeout(
            &lifecycle,
            phase,
        );
        if (!http_server.acceptingCompletionsV1(&runtime))
            return error.TimeoutClosedAdmission;
        const service_snapshot = try harness.service.snapshotV1();
        if (service_snapshot.active_requests != 0 or
            service_snapshot.terminal_records != 0 or
            service_snapshot.bank == null or
            !service_snapshot.bank.?.used.isZero())
        {
            return error.InvalidTimeoutServiceReceipt;
        }
        try emitTimedOut(
            timed_out.process_generation,
            timed_out.last_receive_timeout_signaled_phase,
        );
    }
    if (profile.isFullRequestTimeout()) {
        try observeFullRequestTimeoutWorker(
            &lifecycle,
            profile,
            &work_barrier,
            &response_barrier,
            generation,
        );
    }
    const stdin = std.fs.File.stdin();
    const drain_control: DrainControl = if (profile == .peer_reset_work) blk: {
        try expectControlLine(stdin, peer_reset_arm_command);
        work_barrier.reached.wait();
        try emitCheckpoint("WORK_ADMITTED", generation);
        try expectControlLine(stdin, peer_reset_release_command);
        work_barrier.release.set();
        work_barrier.checkpoint_result_reached.wait();
        if (work_barrier.checkpoint_failed)
            return error.PeerResetPollTimedOut;
        const cancellation = work_barrier.cancellation orelse
            return error.MissingPeerResetCancellation;
        if (work_barrier.cancellation_identity_mismatch or
            cancellation.requested_cause != .peer_reset or
            cancellation.winner != .peer_reset or
            cancellation.outcome != .cancelled or
            !cancellation.cancellation_was_new)
        {
            return error.InvalidPeerResetCancellation;
        }
        work_barrier.retired_reached.wait();
        try emitCheckpoint("PEER_RESET", generation);
        try expectControlLine(stdin, peer_reset_drain_command);
        break :blk .immediate;
    } else try readDrainControl(stdin);
    if (profile != .peer_reset_work and
        !profileMatchesControl(profile, drain_control))
    {
        return error.InvalidProfileControlPair;
    }
    if (drain_control.requestedPhase()) |phase| {
        try waitForActivePhase(&lifecycle, phase);
    }
    if (drain_control.usesWorkBarrier()) {
        work_barrier.reached.wait();
        if (drain_control == .terminal_work) {
            const drive = try harness.service.driveNextV1();
            switch (drive) {
                .completed => {},
                else => return error.WorkDidNotReachTerminal,
            }
        }
    }
    if (drain_control.usesResponseBarrier()) {
        response_barrier.reached.wait();
        if (drain_control.usesResponseProgressBarrier()) {
            response_barrier.release.set();
            response_barrier.progress_reached.wait();
            if (response_barrier.progress_calls != 1 or
                response_barrier.progress_bytes != 1)
            {
                return error.InvalidResponseProgressReceipt;
            }
        }
        if (drain_control == .response_completed) {
            response_barrier.release.set();
            response_barrier.retired_reached.wait();
            if (response_barrier.outcome != .write_completed or
                response_barrier.ready_calls != 1 or
                response_barrier.writing_calls != 1)
            {
                return error.InvalidCompletedResponseReceipt;
            }
        }
        if (drain_control == .response_writing_completed) {
            response_barrier.progress_release.set();
            response_barrier.retired_reached.wait();
            if (response_barrier.outcome != .write_completed or
                response_barrier.ready_calls != 1 or
                response_barrier.writing_calls != 1 or
                response_barrier.progress_calls <= 1 or
                response_barrier.progress_bytes !=
                    response_barrier.progress_calls)
            {
                return error.InvalidCompletedResponseProgressReceipt;
            }
        }
    }
    var drain_error: ?anyerror = null;
    server_api.requestDrainAndWakeV1(
        &lifecycle,
        &runtime,
        listen_address,
    ) catch |err| {
        drain_error = err;
    };
    if (drain_error == null and drain_control.repeatsDrain()) {
        server_api.requestDrainAndWakeV1(
            &lifecycle,
            &runtime,
            listen_address,
        ) catch |err| {
            drain_error = err;
        };
    }
    if (drain_control.usesWorkBarrier()) {
        work_barrier.release.set();
    }
    if (drain_control == .response_ready) {
        response_barrier.release.set();
        response_barrier.retired_reached.wait();
        if (response_barrier.outcome != .cancelled_before_write or
            response_barrier.ready_calls != 1 or
            response_barrier.writing_calls != 0)
        {
            return error.InvalidCancelledResponseReceipt;
        }
    }
    if (drain_control == .response_writing) {
        response_barrier.progress_release.set();
        response_barrier.retired_reached.wait();
        if (response_barrier.outcome != .cancelled_during_write or
            response_barrier.ready_calls != 1 or
            response_barrier.writing_calls != 1 or
            response_barrier.progress_calls != 1 or
            response_barrier.progress_bytes != 1)
        {
            return error.InvalidCancelledResponseProgressReceipt;
        }
    }
    if (drain_error) |err| return err;
    if (http_server.acceptingCompletionsV1(&runtime))
        return error.DrainAdmissionStillOpen;
    if (profile.isPhaseE()) {
        serve_thread.join();
        joined = true;
    } else {
        try waitForInactiveConnection(&lifecycle);
    }
    const draining = lifecycle.snapshotV1();
    try validateDrainSignalReceipt(
        draining,
        drain_control.requestedPhase(),
    );
    try validateDrainWorkReceipt(
        draining,
        drain_control.expectsWorkCancellation(),
    );
    try validatePhaseEReceipt(draining, profile);
    try emitDraining(
        draining,
        response_barrier.outcome,
    );

    if (!joined) {
        serve_thread.join();
        joined = true;
    }
    if (serve_context.thread_error) |err| return err;
    if (profile.usesWorkBarrier() and
        (!work_barrier.retired or
            work_barrier.retire_identity_mismatch))
    {
        return error.InvalidWorkRetirementReceipt;
    }

    const stopped = lifecycle.snapshotV1();
    if (stopped.state != .stopped or
        stopped.active_connections != 0 or
        stopped.active_connection_phase != .none)
    {
        return error.InvalidLifecycleReceipt;
    }
    try validateDrainSignalReceipt(
        stopped,
        drain_control.requestedPhase(),
    );
    try validateDrainWorkReceipt(
        stopped,
        drain_control.expectsWorkCancellation(),
    );
    try validatePhaseEReceipt(stopped, profile);
    const service_snapshot = try harness.service.snapshotV1();
    if (service_snapshot.active_requests != 0 or
        service_snapshot.bank == null or
        !service_snapshot.bank.?.used.isZero())
    {
        return error.InvalidServiceReceipt;
    }
    switch (profile) {
        .peer_reset_work => {
            if (service_snapshot.terminal_records != 1 or
                service_snapshot.cancelled_records != 1 or
                service_snapshot.completed_records != 0 or
                service_snapshot.failed_records != 0)
            {
                return error.InvalidPeerResetServiceReceipt;
            }
        },
        .full_request_timeout_request_admitted => {
            if (service_snapshot.terminal_records != 1 or
                service_snapshot.cancelled_records != 1 or
                service_snapshot.completed_records != 0 or
                service_snapshot.failed_records != 0)
            {
                return error.InvalidFullRequestTimeoutServiceReceipt;
            }
        },
        .drain_response_ready,
        .complete_response_ready,
        .drain_response_writing,
        .complete_response_writing,
        .full_request_timeout_response_ready,
        .full_request_timeout_response_writing,
        => {
            if (service_snapshot.terminal_records != 1 or
                service_snapshot.completed_records != 1 or
                service_snapshot.cancelled_records != 0 or
                service_snapshot.failed_records != 0)
            {
                return error.InvalidResponseServiceReceipt;
            }
        },
        else => {},
    }
    const close_receipt = try harness.service.closeV1();
    if (!close_receipt.bank_snapshot.used.isZero())
        return error.InvalidServiceReceipt;
    try emitClosed(
        stopped,
        service_snapshot.active_requests,
        close_receipt.terminal_records,
        response_barrier.outcome,
    );
}

fn runApplicationRejectionWorker(
    allocator: std.mem.Allocator,
    binding: unary.ModelBindingV1,
    generation: u64,
) !void {
    var lifecycle =
        try server_api.ManagedLifecycleV1.initV1(generation);
    var harness: ServiceHarness(1, 1) = .{};
    try harness.init(
        allocator,
        binding,
        generation,
    );
    var runtime = try http_server.initV1(
        &harness.service,
        binding.binding_sha256,
    );
    const bind_address =
        try std.net.Address.parseIp(loopback_host, 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const listen_address = listener.listen_address;

    try lifecycle.markReadyV1();
    var observer: WorkAdmissionBarrierV1 = .{};
    observer.release.set();
    var serve_context: ServeContext = .{
        .listener = &listener,
        .runtime = &runtime,
        .lifecycle = &lifecycle,
        .config = .{ .stop_after_requests = 4 },
        .work_observer = observer.control(false),
    };
    const serve_thread = try std.Thread.spawn(
        .{},
        ServeContext.run,
        .{&serve_context},
    );
    var joined = false;
    defer if (!joined) {
        forceDrainAndWake(
            &lifecycle,
            &runtime,
            listen_address,
        );
        serve_thread.join();
    };

    try emitReady(
        generation,
        listen_address.getPort(),
        &runtime.model_id,
    );
    serve_thread.join();
    joined = true;
    if (serve_context.thread_error) |err| return err;
    if (observer.rejection_overflowed or
        observer.rejection_count != 2 or
        observer.identity == null or
        !observer.retired or
        observer.retired_count != 1 or
        observer.retire_identity_mismatch or
        runtime.next_work_sequence != 1)
    {
        return error.InvalidApplicationRejectionObservation;
    }

    const scheduler_observation = observer.rejections[0];
    const scheduler_owner =
        scheduler_observation.transport_owner orelse
        return error.MissingApplicationRejectionOwner;
    const scheduler_cause =
        switch (scheduler_observation.cause) {
            .scheduler => |cause| cause,
            .service_capacity => return error.InvalidApplicationRejectionCause,
        };
    const expected_scheduler_sha256 =
        try protocol.requestSha256V1(.{
            .model_id = &runtime.model_id,
            .tenant_key = 73,
            .idempotency_key = "process-observer-scheduler",
            .prompt_utf8 = prompt,
            .max_new_tokens = 2,
            .deadline_tick = 1,
        });
    if (scheduler_owner.process_generation != generation or
        scheduler_owner.connection_sequence != 1 or
        scheduler_owner.slot_index != 0 or
        scheduler_owner.slot_generation != 1 or
        scheduler_cause.event_abi_version !=
            engine.lane_weave_qos.event_abi or
        scheduler_cause.scheduler_epoch !=
            generation ^ 0x5343_4844 or
        scheduler_cause.event_sequence != 0 or
        scheduler_cause.reason != .deadline_infeasible or
        !std.mem.eql(
            u8,
            &scheduler_observation.request_sha256,
            &expected_scheduler_sha256,
        ))
    {
        return error.InvalidSchedulerRejectionObservation;
    }
    const zero_digest = [_]u8{0} ** 32;
    if (std.mem.eql(
        u8,
        &zero_digest,
        &scheduler_cause.event_sha256,
    )) {
        return error.InvalidSchedulerRejectionObservation;
    }

    const capacity_observation = observer.rejections[1];
    const capacity_owner =
        capacity_observation.transport_owner orelse
        return error.MissingApplicationRejectionOwner;
    switch (capacity_observation.cause) {
        .service_capacity => {},
        .scheduler => return error.InvalidApplicationRejectionCause,
    }
    const expected_capacity_sha256 =
        try protocol.requestSha256V1(.{
            .model_id = &runtime.model_id,
            .tenant_key = 83,
            .idempotency_key = "process-observer-capacity",
            .prompt_utf8 = prompt,
            .max_new_tokens = 1,
        });
    if (capacity_owner.process_generation != generation or
        capacity_owner.connection_sequence != 3 or
        capacity_owner.slot_index != 0 or
        capacity_owner.slot_generation != 3 or
        !std.mem.eql(
            u8,
            &capacity_observation.request_sha256,
            &expected_capacity_sha256,
        ))
    {
        return error.InvalidCapacityRejectionObservation;
    }

    const stopped = lifecycle.snapshotV1();
    if (stopped.state != .stopped or
        stopped.accepted_connections != 4 or
        stopped.completed_connections != 4 or
        stopped.failed_connections != 0 or
        stopped.active_connections != 0)
    {
        return error.InvalidApplicationRejectionLifecycle;
    }
    const service_snapshot =
        try harness.service.snapshotV1();
    if (service_snapshot.active_requests != 0 or
        service_snapshot.terminal_records != 1 or
        service_snapshot.completed_records != 1 or
        service_snapshot.cancelled_records != 0 or
        service_snapshot.failed_records != 0 or
        service_snapshot.scheduler == null or
        service_snapshot.scheduler.?.active != 0 or
        !service_snapshot.scheduler.?.used.isZero() or
        service_snapshot.bank == null or
        !service_snapshot.bank.?.used.isZero())
    {
        return error.InvalidApplicationRejectionService;
    }
    const close_receipt = try harness.service.closeV1();
    if (close_receipt.terminal_records != 1 or
        !close_receipt.bank_snapshot.used.isZero())
    {
        return error.InvalidApplicationRejectionClose;
    }
    try emitCheckpoint(
        "APPLICATION_REJECTION",
        generation,
    );
    try emitClosed(
        stopped,
        service_snapshot.active_requests,
        close_receipt.terminal_records,
        null,
    );
}

fn runConcurrentWorker(
    allocator: std.mem.Allocator,
    binding: unary.ModelBindingV1,
    generation: u64,
    profile: WorkerProfile,
) !void {
    if (!profile.isConcurrent())
        return error.InvalidConcurrentWorkerProfile;

    var harness: ServiceHarness(1, 4) = .{};
    try harness.init(
        allocator,
        binding,
        generation,
    );
    var service_closed = false;
    defer if (!service_closed) {
        _ = harness.service.closeV1() catch {};
    };
    var runtime = try http_server.initV1(
        &harness.service,
        binding.binding_sha256,
    );
    var lifecycle =
        try server_api.ManagedConcurrentLifecycleV1.initV1(
            generation,
            .{
                .worker_count = 1,
                .pending_connection_capacity = 1,
            },
        );
    try lifecycle.markReadyV1();

    const bind_address =
        try std.net.Address.parseIp(loopback_host, 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const listen_address = listener.listen_address;

    var event_log: ConcurrentEventLog = .{};
    var work_barrier: WorkAdmissionBarrierV1 = .{
        .passthrough_after_first = profile == .concurrent_queued_receive_timeout or
            profile == .concurrent_queued_full_request_timeout,
    };
    var serve_context: ConcurrentServeContext = .{
        .listener = &listener,
        .runtime = &runtime,
        .lifecycle = &lifecycle,
        .config = .{
            .receive_timeout_ns = profile.receiveTimeoutNs(),
            .full_request_timeout_ns = profile.fullRequestTimeoutNs(),
        },
        .event_observer = event_log.observer(),
        .work_observer = if (profile == .concurrent_stale_owner_failure or
            profile == .concurrent_queued_receive_timeout or
            profile == .concurrent_queued_full_request_timeout)
            work_barrier.control(false)
        else
            null,
    };
    const serve_thread = try std.Thread.spawn(
        .{},
        ConcurrentServeContext.run,
        .{&serve_context},
    );
    var joined = false;
    defer if (!joined) {
        work_barrier.release.set();
        server_api.requestManagedConcurrentDrainAndWakeV1(
            &lifecycle,
            &runtime,
            listen_address,
        ) catch {};
        serve_thread.join();
    };

    try emitReady(
        generation,
        listen_address.getPort(),
        &runtime.model_id,
    );

    var expected_thread_error: ?anyerror = null;
    switch (profile) {
        .concurrent_queued_receive_timeout,
        .concurrent_queued_full_request_timeout,
        => try runConcurrentQueuedTimeoutWorker(
            profile,
            &lifecycle,
            &runtime,
            listen_address,
            &event_log,
            &work_barrier,
        ),
        .concurrent_drain => try runConcurrentDrainWorker(
            &lifecycle,
            &runtime,
            listen_address,
            &event_log,
        ),
        .concurrent_stale_owner_failure => {
            try runConcurrentStaleOwnerFailureWorker(
                &lifecycle,
                &runtime,
                listen_address,
                &event_log,
                &work_barrier,
            );
            expected_thread_error =
                error.ConnectionSlotGenerationMismatch;
        },
        else => unreachable,
    }

    work_barrier.release.set();
    serve_thread.join();
    joined = true;
    try validateConcurrentServeThreadError(
        serve_context.thread_error,
        expected_thread_error,
    );
    const stopped = lifecycle.snapshotV1();
    try validateConcurrentFinalSnapshot(
        profile,
        stopped,
        &event_log,
    );
    if (profile == .concurrent_stale_owner_failure or
        profile == .concurrent_queued_receive_timeout or
        profile == .concurrent_queued_full_request_timeout)
    {
        if (!work_barrier.retired or
            work_barrier.retire_identity_mismatch or
            work_barrier.cancellation_identity_mismatch)
        {
            return error.InvalidConcurrentWorkRetirement;
        }
        if (profile == .concurrent_queued_full_request_timeout) {
            const cancellation = work_barrier.cancellation orelse
                return error.MissingConcurrentTimeoutCancellation;
            if (cancellation.requested_cause !=
                .full_request_timeout or
                cancellation.winner != .full_request_timeout or
                cancellation.outcome != .cancelled or
                !cancellation.cancellation_was_new)
            {
                return error.InvalidConcurrentTimeoutCancellation;
            }
        } else if (work_barrier.cancellation != null) {
            return error.UnexpectedConcurrentCancellation;
        }
    }

    const service_snapshot = try harness.service.snapshotV1();
    const scheduler_snapshot = service_snapshot.scheduler orelse
        return error.MissingConcurrentSchedulerSnapshot;
    const bank_snapshot = service_snapshot.bank orelse
        return error.MissingConcurrentBankSnapshot;
    const scheduler_zero =
        scheduler_snapshot.active == 0 and
        scheduler_snapshot.finished == 0 and
        scheduler_snapshot.used.isZero() and
        !scheduler_snapshot.poisoned and
        !scheduler_snapshot.closed;
    const bank_zero =
        bank_snapshot.used.isZero() and
        bank_snapshot.active_reservations == 0 and
        bank_snapshot.committed_receipts == 0;
    if (service_snapshot.active_requests != 0 or
        service_snapshot.recovery_required != 0 or
        !scheduler_zero or
        !bank_zero)
    {
        return error.InvalidConcurrentServiceOwnership;
    }
    if (profile == .concurrent_stale_owner_failure) {
        if (service_snapshot.terminal_records != 1 or
            service_snapshot.completed_records != 0 or
            service_snapshot.cancelled_records != 1 or
            service_snapshot.failed_records != 0)
        {
            return error.InvalidConcurrentFailureServiceReceipt;
        }
    } else if (profile == .concurrent_queued_receive_timeout) {
        if (service_snapshot.terminal_records != 2 or
            service_snapshot.completed_records != 2 or
            service_snapshot.cancelled_records != 0 or
            service_snapshot.failed_records != 0)
        {
            return error.InvalidConcurrentSuccessorServiceReceipt;
        }
    } else if (profile ==
        .concurrent_queued_full_request_timeout)
    {
        if (service_snapshot.terminal_records != 2 or
            service_snapshot.completed_records != 1 or
            service_snapshot.cancelled_records != 1 or
            service_snapshot.failed_records != 0)
        {
            return error.InvalidConcurrentSuccessorServiceReceipt;
        }
    } else {
        if (service_snapshot.terminal_records != 0 or
            service_snapshot.completed_records != 0 or
            service_snapshot.cancelled_records != 0 or
            service_snapshot.failed_records != 0)
        {
            return error.UnexpectedConcurrentServiceRecord;
        }
    }

    const close_receipt = try harness.service.closeV1();
    service_closed = true;
    if (!close_receipt.bank_snapshot.used.isZero() or
        close_receipt.bank_snapshot.active_reservations != 0 or
        close_receipt.bank_snapshot.committed_receipts != 0)
    {
        return error.InvalidConcurrentCloseReceipt;
    }
    lifecycle.managed.mutex.lock();
    const serving_after_join = lifecycle.serving;
    lifecycle.managed.mutex.unlock();
    if (!joined or serving_after_join)
        return error.InvalidConcurrentServeRetirement;
    try emitConcurrentClosed(
        profile,
        stopped,
        try event_log.totalCount(),
        service_snapshot,
        scheduler_zero,
        bank_zero,
        joined,
        serving_after_join,
    );
}

fn emitNativeLoadWave(expected: usize) !void {
    var storage: [64]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &storage,
        "NATIVE-LOAD-WAVE {d}\n",
        .{expected},
    );
    try std.fs.File.stdout().writeAll(frame);
}

fn emitNativeLoadServerRecords(
    records: *const [native_load_record_count]NativeLoadServerRecord,
) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    for (records, 0..) |record, index| {
        const request_hex =
            std.fmt.bytesToHex(record.request_sha256, .lower);
        const handle_hex =
            std.fmt.bytesToHex(record.handle_sha256, .lower);
        const frame = try std.fmt.bufPrint(
            &storage,
            "NATIVE-LOAD-RECORD " ++
                "{d} {s} {s} {d} {d} {d} {d} {d} {d} " ++
                "{d} {d} {d} {d} {d} {d} {d}\n",
            .{
                index,
                &request_hex,
                &handle_hex,
                record.work_sequence,
                record.process_generation,
                record.connection_sequence,
                record.slot_index,
                record.slot_generation,
                record.worker_index,
                record.enqueue_ordinal,
                record.enqueue_ns,
                record.dispatch_ordinal,
                record.dispatch_ns,
                record.published_ns,
                record.retired_ordinal,
                record.retired_ns,
            },
        );
        try std.fs.File.stdout().writeAll(frame);
    }
}

fn emitNativeLoadClosure(
    values: *const [native_load_closure_u64_count]u64,
) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    var stream = std.io.fixedBufferStream(&storage);
    const writer = stream.writer();
    try writer.writeAll("NATIVE-LOAD-CLOSED");
    for (values) |value| {
        try writer.print(" {d}", .{value});
    }
    try writer.writeByte('\n');
    try std.fs.File.stdout().writeAll(
        stream.getWritten(),
    );
}

fn runNativeLoadWorker(
    allocator: std.mem.Allocator,
    binding: unary.ModelBindingV1,
    generation: u64,
) !void {
    if (generation != generation_native_load)
        return error.InvalidNativeLoadGeneration;
    if (comptime builtin.os.tag == .windows or
        builtin.os.tag == .wasi or builtin.os.tag == .uefi)
    {
        return error.NativeLoadUnsupported;
    }
    _ = try nativeLoadMonotonicNs();

    var harness: ServiceHarness(1, native_load_record_count) = .{};
    try harness.init(
        allocator,
        binding,
        generation,
    );
    var service_closed = false;
    defer if (!service_closed) {
        _ = harness.service.closeV1() catch {};
    };
    var runtime = try http_server.initV1(
        &harness.service,
        binding.binding_sha256,
    );
    var lifecycle =
        try server_api.ManagedConcurrentLifecycleV1.initV1(
            generation,
            .{
                .worker_count = native_load_worker_count,
                .pending_connection_capacity = native_load_pending_capacity,
            },
        );
    try lifecycle.markReadyV1();

    const bind_address =
        try std.net.Address.parseIp(loopback_host, 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const listen_address = listener.listen_address;
    var event_log: ConcurrentEventLog = .{};
    var work_log: NativeLoadWorkLog = .{};
    var serve_context: ConcurrentServeContext = .{
        .listener = &listener,
        .runtime = &runtime,
        .lifecycle = &lifecycle,
        .config = .{},
        .event_observer = event_log.observer(),
        .work_observer = work_log.control(),
    };
    const serve_thread = try std.Thread.spawn(
        .{},
        ConcurrentServeContext.run,
        .{&serve_context},
    );
    var joined = false;
    defer if (!joined) {
        server_api.requestManagedConcurrentDrainAndWakeV1(
            &lifecycle,
            &runtime,
            listen_address,
        ) catch {};
        serve_thread.join();
    };

    try emitReady(
        generation,
        listen_address.getPort(),
        &runtime.model_id,
    );
    const stdin = std.fs.File.stdin();
    for (1..native_load_wave_count + 1) |wave| {
        const expected = wave * native_load_flow_count;
        var command_storage: [64]u8 = undefined;
        const command = try std.fmt.bufPrint(
            &command_storage,
            "native-load-wave {d}\n",
            .{expected},
        );
        try expectControlLine(stdin, command);
        try event_log.waitForRetiredCount(expected);
        try emitNativeLoadWave(expected);
    }
    try expectControlLine(
        stdin,
        native_load_drain_command,
    );
    try server_api.requestManagedConcurrentDrainAndWakeV1(
        &lifecycle,
        &runtime,
        listen_address,
    );
    serve_thread.join();
    joined = true;
    if (serve_context.thread_error) |err| return err;

    const stopped = lifecycle.snapshotV1();
    const service_snapshot =
        try harness.service.snapshotV1();
    const scheduler_snapshot =
        service_snapshot.scheduler orelse
        return error.MissingNativeLoadSchedulerSnapshot;
    const bank_snapshot = service_snapshot.bank orelse
        return error.MissingNativeLoadBankSnapshot;
    const scheduler_zero =
        scheduler_snapshot.active == 0 and
        scheduler_snapshot.finished == 0 and
        scheduler_snapshot.used.isZero() and
        !scheduler_snapshot.poisoned and
        !scheduler_snapshot.closed;
    const bank_zero =
        bank_snapshot.used.isZero() and
        bank_snapshot.active_reservations == 0 and
        bank_snapshot.committed_receipts == 0;
    lifecycle.managed.mutex.lock();
    const serving_after_join = lifecycle.serving;
    lifecycle.managed.mutex.unlock();
    if (stopped.managed.state != .stopped or
        stopped.worker_count != native_load_worker_count or
        stopped.pending_connection_capacity !=
            native_load_pending_capacity or
        stopped.managed.accepted_connections !=
            native_load_record_count or
        stopped.managed.completed_connections !=
            native_load_record_count or
        stopped.managed.failed_connections != 0 or
        stopped.queue_enqueued_connections !=
            native_load_record_count or
        stopped.queue_dispatched_connections !=
            native_load_record_count or
        stopped.managed.active_connections != 0 or
        stopped.managed.queued_connections != 0 or
        stopped.running_connections != 0 or
        stopped.drain_cancelled_queued_connections != 0 or
        stopped.failure_cancelled_queued_connections != 0 or
        stopped.receive_timeout_queued_connections != 0 or
        stopped.full_request_timeout_queued_connections != 0 or
        stopped.listener_backpressure_activations !=
            stopped.listener_backpressure_resumptions or
        stopped.accept_paused or stopped.cleanup_failed or
        service_snapshot.active_requests != 0 or
        service_snapshot.terminal_records !=
            native_load_record_count or
        service_snapshot.completed_records !=
            native_load_record_count or
        service_snapshot.cancelled_records != 0 or
        service_snapshot.failed_records != 0 or
        service_snapshot.recovery_required != 0 or
        !scheduler_zero or !bank_zero or
        !joined or serving_after_join)
    {
        return error.InvalidNativeLoadClosure;
    }
    var server_records: [native_load_record_count]NativeLoadServerRecord =
        undefined;
    try collectNativeLoadServerRecords(
        &work_log,
        &event_log,
        &server_records,
    );
    try event_log.validateOrdinals();
    const event_count = try event_log.totalCount();
    if (event_count != stopped.event_ordinal)
        return error.InvalidNativeLoadEventCount;

    const close_receipt = try harness.service.closeV1();
    service_closed = true;
    if (!close_receipt.bank_snapshot.used.isZero() or
        close_receipt.bank_snapshot.active_reservations != 0 or
        close_receipt.bank_snapshot.committed_receipts != 0)
    {
        return error.InvalidNativeLoadCloseReceipt;
    }
    const closure = [native_load_closure_u64_count]u64{
        stopped.managed.accepted_connections,
        stopped.managed.completed_connections,
        stopped.managed.failed_connections,
        stopped.queue_enqueued_connections,
        stopped.queue_dispatched_connections,
        stopped.queue_high_watermark,
        stopped.running_high_watermark,
        stopped.listener_backpressure_activations,
        stopped.listener_backpressure_resumptions,
        stopped.drain_cancelled_queued_connections,
        stopped.failure_cancelled_queued_connections,
        stopped.receive_timeout_queued_connections,
        stopped.full_request_timeout_queued_connections,
        stopped.managed.active_connections,
        stopped.managed.queued_connections,
        stopped.running_connections,
        @intFromBool(stopped.cleanup_failed),
        service_snapshot.active_requests,
        service_snapshot.terminal_records,
        service_snapshot.completed_records,
        service_snapshot.cancelled_records,
        service_snapshot.failed_records,
        service_snapshot.recovery_required,
        @intFromBool(scheduler_zero),
        @intFromBool(bank_zero),
        @intFromBool(joined),
        @intFromBool(serving_after_join),
        event_count,
    };
    try emitNativeLoadServerRecords(&server_records);
    try emitNativeLoadClosure(&closure);
}

fn runConcurrentQueuedTimeoutWorker(
    profile: WorkerProfile,
    lifecycle: *server_api.ManagedConcurrentLifecycleV1,
    runtime: *http_server.RuntimeV1,
    listen_address: std.net.Address,
    event_log: *ConcurrentEventLog,
    work_barrier: *WorkAdmissionBarrierV1,
) !void {
    work_barrier.reached.wait();
    const active = try event_log.waitForKind(.dispatched, 1);
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_ACTIVE",
        active,
    );
    const queued = try event_log.waitForKind(.enqueued, 2);
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_QUEUED",
        queued,
    );
    _ = try event_log.waitForKind(.backpressure_paused, 1);

    const timeout_kind: server_api.ManagedConcurrentEventKindV1 =
        if (profile == .concurrent_queued_receive_timeout)
            .queued_receive_timeout
        else if (profile ==
        .concurrent_queued_full_request_timeout)
            .queued_full_request_timeout
        else
            return error.InvalidConcurrentTimeoutProfile;
    const timed_out = try event_log.waitForKind(
        timeout_kind,
        1,
    );
    if (timed_out.lease == null or
        queued.lease == null or
        !std.meta.eql(timed_out.lease.?, queued.lease.?))
    {
        return error.ConcurrentQueuedTimeoutLeaseMismatch;
    }
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_QUEUED_TIMEOUT",
        timed_out,
    );

    try expectControlLine(
        std.fs.File.stdin(),
        concurrent_release_command,
    );
    work_barrier.release.set();
    const first_retired =
        try event_log.waitForKind(.retired, 1);
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_FIRST_RETIRED",
        first_retired,
    );

    try expectControlLine(
        std.fs.File.stdin(),
        drain_command,
    );
    _ = try event_log.waitForKind(.retired, 2);
    try server_api.requestManagedConcurrentDrainAndWakeV1(
        lifecycle,
        runtime,
        listen_address,
    );
}

fn runConcurrentDrainWorker(
    lifecycle: *server_api.ManagedConcurrentLifecycleV1,
    runtime: *http_server.RuntimeV1,
    listen_address: std.net.Address,
    event_log: *ConcurrentEventLog,
) !void {
    const active = try event_log.waitForKind(.dispatched, 1);
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_ACTIVE",
        active,
    );
    const queued = try event_log.waitForKind(.enqueued, 2);
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_QUEUED",
        queued,
    );
    _ = try event_log.waitForKind(.backpressure_paused, 1);
    try expectControlLine(
        std.fs.File.stdin(),
        drain_command,
    );
    var start: std.Thread.ResetEvent = .{};
    var first: ConcurrentDrainRequest = .{
        .lifecycle = lifecycle,
        .runtime = runtime,
        .listen_address = listen_address,
        .start = &start,
    };
    var second: ConcurrentDrainRequest = .{
        .lifecycle = lifecycle,
        .runtime = runtime,
        .listen_address = listen_address,
        .start = &start,
    };
    const first_thread = try std.Thread.spawn(
        .{},
        ConcurrentDrainRequest.run,
        .{&first},
    );
    var first_joined = false;
    defer if (!first_joined) {
        start.set();
        first_thread.join();
    };
    const second_thread = try std.Thread.spawn(
        .{},
        ConcurrentDrainRequest.run,
        .{&second},
    );
    var second_joined = false;
    defer if (!second_joined) {
        start.set();
        second_thread.join();
    };
    first.ready.wait();
    second.ready.wait();
    lifecycle.managed.mutex.lock();
    start.set();
    first.entered.wait();
    second.entered.wait();
    lifecycle.managed.mutex.unlock();
    first.done.wait();
    second.done.wait();
    first_thread.join();
    first_joined = true;
    second_thread.join();
    second_joined = true;
    if (first.thread_error) |err| return err;
    if (second.thread_error) |err| return err;
    const queued_drain =
        try event_log.waitForKind(.queued_drain, 1);
    if (queued_drain.lease == null or
        queued.lease == null or
        !std.meta.eql(queued_drain.lease.?, queued.lease.?))
    {
        return error.ConcurrentQueuedDrainLeaseMismatch;
    }
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_QUEUED_DRAIN",
        queued_drain,
    );
    _ = try event_log.waitForKind(.retired, 1);
}

fn runConcurrentStaleOwnerFailureWorker(
    lifecycle: *server_api.ManagedConcurrentLifecycleV1,
    runtime: *http_server.RuntimeV1,
    listen_address: std.net.Address,
    event_log: *ConcurrentEventLog,
    work_barrier: *WorkAdmissionBarrierV1,
) !void {
    const predecessor =
        try event_log.waitForKind(.retired, 1);
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_PREDECESSOR_RETIRED",
        predecessor,
    );

    work_barrier.reached.wait();
    const active = try event_log.waitForKind(.dispatched, 2);
    const stale_lease = predecessor.lease orelse
        return error.MissingConcurrentPredecessorLease;
    const active_lease = active.lease orelse
        return error.MissingConcurrentActiveLease;
    if (stale_lease.slot_index != active_lease.slot_index or
        stale_lease.slot_generation >=
            active_lease.slot_generation)
    {
        return error.ConcurrentSlotWasNotReused;
    }
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_WORK_ADMITTED",
        active,
    );

    const queued = try event_log.waitForKind(.enqueued, 3);
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_QUEUED",
        queued,
    );
    _ = try event_log.waitForKind(.backpressure_paused, 1);
    try expectControlLine(
        std.fs.File.stdin(),
        concurrent_fault_command,
    );

    runtime.control_mutex.lock();
    if (runtime.active_work == null or
        runtime.active_work.?.transport_owner == null)
    {
        runtime.control_mutex.unlock();
        return error.MissingConcurrentActiveOwner;
    }
    runtime.active_work.?.transport_owner = .{
        .process_generation = stale_lease.process_generation,
        .connection_sequence = stale_lease.connection_sequence,
        .slot_index = stale_lease.slot_index,
        .slot_generation = stale_lease.slot_generation,
    };
    runtime.control_mutex.unlock();

    var rejected = false;
    server_api.requestManagedConcurrentDrainAndWakeV1(
        lifecycle,
        runtime,
        listen_address,
    ) catch |err| {
        if (err !=
            error.ConnectionSlotGenerationMismatch)
        {
            return err;
        }
        rejected = true;
    };
    if (!rejected)
        return error.StaleConcurrentOwnerWasAccepted;
    try emitCheckpoint(
        "CONCURRENT_STALE_OWNER_REJECTED",
        lifecycle.snapshotV1().managed.process_generation,
    );

    work_barrier.release.set();
    const queued_failure =
        try event_log.waitForKind(.queued_failure, 1);
    if (queued_failure.lease == null or
        queued.lease == null or
        !std.meta.eql(
            queued_failure.lease.?,
            queued.lease.?,
        ))
    {
        return error.ConcurrentQueuedFailureLeaseMismatch;
    }
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_QUEUED_FAILURE",
        queued_failure,
    );
    const running_failure =
        try event_log.waitForKind(.running_failure, 1);
    if (running_failure.lease == null or
        !std.meta.eql(
            running_failure.lease.?,
            active_lease,
        ))
    {
        return error.ConcurrentRunningFailureLeaseMismatch;
    }
    try emitConcurrentEventCheckpoint(
        "CONCURRENT_RUNNING_FAILURE",
        running_failure,
    );
    _ = try event_log.waitForKind(.retired, 2);
}

fn validateConcurrentFinalSnapshot(
    profile: WorkerProfile,
    snapshot: server_api.ManagedConcurrentSnapshotV1,
    event_log: *ConcurrentEventLog,
) !void {
    const expected_state: server_api.ManagedStateV1 =
        if (profile == .concurrent_stale_owner_failure)
            .failed
        else
            .stopped;
    if (snapshot.managed.state != expected_state or
        snapshot.managed.active_connections != 0 or
        snapshot.managed.queued_connections != 0 or
        snapshot.running_connections != 0 or
        snapshot.accept_paused or
        snapshot.cleanup_failed)
    {
        return error.InvalidConcurrentFinalLifecycle;
    }
    const phase_total =
        snapshot.phase_counts.queued +
        snapshot.phase_counts.receiving_head +
        snapshot.phase_counts.request_head_received +
        snapshot.phase_counts.request_received +
        snapshot.phase_counts.request_admitted +
        snapshot.phase_counts.response_ready +
        snapshot.phase_counts.response_writing +
        snapshot.phase_counts.response_written;
    if (snapshot.managed.active_connections !=
        snapshot.managed.queued_connections +
            snapshot.running_connections or
        phase_total != snapshot.managed.active_connections or
        snapshot.queue_enqueued_connections !=
            snapshot.managed.accepted_connections or
        snapshot.queue_high_watermark >
            snapshot.pending_connection_capacity or
        snapshot.running_high_watermark >
            snapshot.worker_count or
        snapshot.listener_backpressure_resumptions >
            snapshot.listener_backpressure_activations)
    {
        return error.InvalidConcurrentSnapshotConservation;
    }
    if (snapshot.managed.accepted_connections !=
        snapshot.managed.completed_connections +
            snapshot.managed.failed_connections +
            snapshot.managed.active_connections)
    {
        return error.InvalidConcurrentConnectionConservation;
    }
    if (snapshot.queue_enqueued_connections !=
        snapshot.queue_dispatched_connections +
            snapshot.drain_cancelled_queued_connections +
            snapshot.failure_cancelled_queued_connections +
            snapshot.receive_timeout_queued_connections +
            snapshot.full_request_timeout_queued_connections +
            snapshot.managed.queued_connections)
    {
        return error.InvalidConcurrentQueueConservation;
    }
    if (snapshot.event_ordinal !=
        @as(u64, @intCast(try event_log.totalCount())))
    {
        return error.InvalidConcurrentEventConservation;
    }
    try event_log.validateOrdinals();
    if (try event_log.countKind(.enqueued) !=
        snapshot.queue_enqueued_connections or
        try event_log.countKind(.dispatched) !=
            snapshot.queue_dispatched_connections or
        try event_log.countKind(.retired) !=
            snapshot.queue_dispatched_connections)
    {
        return error.InvalidConcurrentCoreEvents;
    }
    if (snapshot.listener_backpressure_activations !=
        @as(
            u64,
            @intCast(try event_log.countKind(.backpressure_paused)),
        ) or
        snapshot.listener_backpressure_resumptions !=
            @as(
                u64,
                @intCast(try event_log.countKind(.backpressure_resumed)),
            ))
    {
        return error.InvalidConcurrentBackpressureEvents;
    }
    const failure_primary =
        snapshot.managed.failure_signaled_connections +
        snapshot.managed.failure_cancelled_response_connections +
        snapshot.managed.failure_requested_response_write_connections;
    if (failure_primary >
        snapshot.queue_dispatched_connections)
    {
        return error.InvalidConcurrentFailureConservation;
    }

    switch (profile) {
        .concurrent_queued_receive_timeout => {
            if (try event_log.countKind(.queued_receive_timeout) != 1 or
                try event_log.countKind(.queued_full_request_timeout) != 0 or
                try event_log.countKind(.queued_drain) != 0 or
                try event_log.countKind(.queued_failure) != 0 or
                try event_log.countKind(.running_failure) != 0)
            {
                return error.InvalidConcurrentReceiveTimeoutEvents;
            }
            if (snapshot.managed.accepted_connections != 3 or
                snapshot.managed.completed_connections != 2 or
                snapshot.managed.failed_connections != 1 or
                snapshot.queue_enqueued_connections != 3 or
                snapshot.queue_dispatched_connections != 2 or
                snapshot.receive_timeout_queued_connections != 1 or
                snapshot.full_request_timeout_queued_connections != 0 or
                snapshot.managed.receive_timeout_signaled_connections != 1 or
                snapshot.managed.last_receive_timeout_signaled_phase !=
                    .queued or
                snapshot.managed.full_request_timeout_signaled_connections != 0 or
                snapshot.managed.drain_signaled_connections != 0 or
                snapshot.managed.failure_signaled_connections != 0 or
                snapshot.drain_cancelled_queued_connections != 0 or
                snapshot.failure_cancelled_queued_connections != 0 or
                snapshot.queue_high_watermark != 1 or
                snapshot.running_high_watermark != 1 or
                snapshot.listener_backpressure_activations == 0 or
                snapshot.listener_backpressure_resumptions !=
                    snapshot.listener_backpressure_activations)
            {
                return error.InvalidConcurrentReceiveTimeoutReceipt;
            }
        },
        .concurrent_queued_full_request_timeout => {
            if (try event_log.countKind(.queued_receive_timeout) != 0 or
                try event_log.countKind(.queued_full_request_timeout) != 1 or
                try event_log.countKind(.queued_drain) != 0 or
                try event_log.countKind(.queued_failure) != 0 or
                try event_log.countKind(.running_failure) != 0)
            {
                return error.InvalidConcurrentFullRequestTimeoutEvents;
            }
            if (snapshot.managed.accepted_connections != 3 or
                snapshot.managed.completed_connections != 1 or
                snapshot.managed.failed_connections != 2 or
                snapshot.queue_enqueued_connections != 3 or
                snapshot.queue_dispatched_connections != 2 or
                snapshot.receive_timeout_queued_connections != 0 or
                snapshot.full_request_timeout_queued_connections != 1 or
                snapshot.managed.full_request_timeout_signaled_connections != 2 or
                (snapshot.managed.last_full_request_timeout_signaled_phase !=
                    .queued and
                    snapshot.managed.last_full_request_timeout_signaled_phase !=
                        .request_admitted) or
                snapshot.managed.receive_timeout_signaled_connections != 0 or
                snapshot.managed.drain_signaled_connections != 0 or
                snapshot.managed.failure_signaled_connections != 0 or
                snapshot.drain_cancelled_queued_connections != 0 or
                snapshot.failure_cancelled_queued_connections != 0 or
                snapshot.queue_high_watermark != 1 or
                snapshot.running_high_watermark != 1 or
                snapshot.listener_backpressure_activations == 0 or
                snapshot.listener_backpressure_resumptions !=
                    snapshot.listener_backpressure_activations)
            {
                return error.InvalidConcurrentFullRequestTimeoutReceipt;
            }
        },
        .concurrent_drain => {
            if (try event_log.countKind(.queued_receive_timeout) != 0 or
                try event_log.countKind(.queued_full_request_timeout) != 0 or
                try event_log.countKind(.queued_drain) != 1 or
                try event_log.countKind(.queued_failure) != 0 or
                try event_log.countKind(.running_failure) != 0)
            {
                return error.InvalidConcurrentDrainEvents;
            }
            if (snapshot.managed.accepted_connections != 2 or
                snapshot.managed.completed_connections != 0 or
                snapshot.managed.failed_connections != 2 or
                snapshot.queue_enqueued_connections != 2 or
                snapshot.queue_dispatched_connections != 1 or
                snapshot.drain_cancelled_queued_connections != 1 or
                snapshot.managed.drain_signaled_connections != 2 or
                snapshot.managed.last_drain_signaled_phase !=
                    .receiving_head or
                snapshot.failure_cancelled_queued_connections != 0 or
                snapshot.receive_timeout_queued_connections != 0 or
                snapshot.full_request_timeout_queued_connections != 0 or
                snapshot.managed.failure_signaled_connections != 0 or
                snapshot.listener_backpressure_activations == 0 or
                snapshot.listener_backpressure_resumptions + 1 !=
                    snapshot.listener_backpressure_activations)
            {
                return error.InvalidConcurrentDrainReceipt;
            }
        },
        .concurrent_stale_owner_failure => {
            if (try event_log.countKind(.queued_receive_timeout) != 0 or
                try event_log.countKind(.queued_full_request_timeout) != 0 or
                try event_log.countKind(.queued_drain) != 0 or
                try event_log.countKind(.queued_failure) != 1 or
                try event_log.countKind(.running_failure) != 1)
            {
                return error.InvalidConcurrentFailureEvents;
            }
            if (snapshot.managed.accepted_connections != 3 or
                snapshot.managed.completed_connections != 1 or
                snapshot.managed.failed_connections != 2 or
                snapshot.queue_enqueued_connections != 3 or
                snapshot.queue_dispatched_connections != 2 or
                snapshot.failure_cancelled_queued_connections != 1 or
                snapshot.managed.failure_signaled_connections != 1 or
                snapshot.managed.failure_cancelled_work_connections != 0 or
                snapshot.managed.failure_cancelled_response_connections != 0 or
                snapshot.managed.failure_requested_response_write_connections != 0 or
                snapshot.managed.failure_cancelled_response_write_connections != 0 or
                snapshot.managed.last_failure_signaled_phase !=
                    .request_admitted or
                snapshot.managed.drain_signaled_connections != 0 or
                snapshot.managed.drain_cancelled_work_connections != 0 or
                snapshot.drain_cancelled_queued_connections != 0 or
                snapshot.receive_timeout_queued_connections != 0 or
                snapshot.full_request_timeout_queued_connections != 0 or
                snapshot.managed.receive_timeout_signaled_connections != 0 or
                snapshot.managed.full_request_timeout_signaled_connections != 0 or
                snapshot.listener_backpressure_activations == 0 or
                snapshot.listener_backpressure_resumptions + 1 !=
                    snapshot.listener_backpressure_activations)
            {
                return error.InvalidConcurrentFailureReceipt;
            }
        },
        else => return error.InvalidConcurrentWorkerProfile,
    }
}

// Keep optional-error matching out of the large worker control flow: Zig
// 0.15.2 Debug otherwise emits invalid LLVM IR with a dominance failure.
fn validateConcurrentServeThreadError(
    actual_error: ?anyerror,
    expected_error: ?anyerror,
) !void {
    if (expected_error) |expected| {
        const actual = actual_error orelse
            return error.MissingConcurrentServeFailure;
        if (actual != expected)
            return error.UnexpectedConcurrentServeFailure;
    } else if (actual_error) |err| {
        return err;
    }
}

fn observeFullRequestTimeoutWorker(
    lifecycle: *server_api.ManagedLifecycleV1,
    profile: WorkerProfile,
    work_barrier: *WorkAdmissionBarrierV1,
    response_barrier: *ResponseReadyBarrierV1,
    generation: u64,
) !void {
    const expected_phase = profile.fullRequestTimeoutPhase() orelse
        return error.InvalidWorkerProfile;
    switch (profile) {
        .full_request_timeout_request_admitted => {
            work_barrier.reached.wait();
        },
        .full_request_timeout_response_ready => {
            response_barrier.reached.wait();
        },
        .full_request_timeout_response_writing => {
            response_barrier.reached.wait();
            response_barrier.release.set();
            response_barrier.progress_reached.wait();
            if (response_barrier.ready_calls != 1 or
                response_barrier.writing_calls != 1 or
                response_barrier.progress_calls != 1 or
                response_barrier.progress_bytes != 1)
            {
                return error.InvalidResponseProgressReceipt;
            }
        },
        else => unreachable,
    }

    const signaled = try waitForFullRequestTimeoutSignal(
        lifecycle,
        expected_phase,
    );
    try validateFullRequestTimeoutSignalReceipt(
        signaled,
        profile,
    );

    switch (profile) {
        .full_request_timeout_request_admitted => {
            work_barrier.release.set();
            work_barrier.checkpoint_result_reached.wait();
            const cancellation = work_barrier.cancellation orelse
                return error.MissingFullRequestTimeoutCancellation;
            if (work_barrier.cancellation_identity_mismatch or
                work_barrier.checkpoint_failed or
                cancellation.requested_cause !=
                    .full_request_timeout or
                cancellation.winner != .full_request_timeout or
                cancellation.outcome != .cancelled or
                !cancellation.cancellation_was_new)
            {
                return error.InvalidFullRequestTimeoutCancellation;
            }
            work_barrier.retired_reached.wait();
        },
        .full_request_timeout_response_ready => {
            response_barrier.release.set();
            response_barrier.retired_reached.wait();
            if (response_barrier.outcome !=
                .cancelled_before_write or
                response_barrier.ready_calls != 1 or
                response_barrier.writing_calls != 0 or
                response_barrier.progress_calls != 0 or
                response_barrier.progress_bytes != 0)
            {
                return error.InvalidFullRequestTimeoutResponseReceipt;
            }
        },
        .full_request_timeout_response_writing => {
            response_barrier.progress_release.set();
            response_barrier.retired_reached.wait();
            if (response_barrier.outcome !=
                .cancelled_during_write or
                response_barrier.ready_calls != 1 or
                response_barrier.writing_calls != 1 or
                response_barrier.progress_calls != 1 or
                response_barrier.progress_bytes != 1)
            {
                return error.InvalidFullRequestTimeoutResponseReceipt;
            }
        },
        else => unreachable,
    }

    const retired =
        try waitForReadyInactiveFullRequestTimeout(lifecycle);
    try validateDrainSignalReceipt(retired, null);
    try validateDrainWorkReceipt(retired, false);
    try validatePhaseEReceipt(retired, profile);
    try emitCheckpoint("FULL_REQUEST_TIMEOUT", generation);
}

fn waitForFullRequestTimeoutSignal(
    lifecycle: *server_api.ManagedLifecycleV1,
    expected_phase: server_api.ManagedConnectionPhaseV1,
) !server_api.ManagedSnapshotV1 {
    while (true) {
        const snapshot = lifecycle.snapshotV1();
        if (snapshot.state != .ready)
            return error.UnexpectedLifecycleState;
        if (snapshot.full_request_timeout_signaled_connections == 1) {
            if (snapshot.last_full_request_timeout_signaled_phase !=
                expected_phase or
                snapshot.accepted_connections != 1 or
                snapshot.completed_connections != 0 or
                snapshot.failed_connections != 0 or
                snapshot.active_connections != 1 or
                snapshot.active_connection_phase != expected_phase or
                snapshot.drain_signaled_connections != 0 or
                snapshot.receive_timeout_signaled_connections != 0)
            {
                return error.InvalidFullRequestTimeoutSignalReceipt;
            }
            return snapshot;
        }
        if (snapshot.full_request_timeout_signaled_connections != 0 or
            snapshot.accepted_connections != 1 or
            snapshot.completed_connections != 0 or
            snapshot.failed_connections != 0 or
            snapshot.active_connections != 1 or
            snapshot.active_connection_phase != expected_phase)
        {
            return error.InvalidFullRequestTimeoutSignalReceipt;
        }
        std.Thread.yield() catch {};
    }
}

fn validateFullRequestTimeoutSignalReceipt(
    snapshot: server_api.ManagedSnapshotV1,
    profile: WorkerProfile,
) !void {
    const response_cancelled: u64 =
        if (profile == .full_request_timeout_response_ready)
            1
        else
            0;
    const response_write_requested: u64 =
        if (profile == .full_request_timeout_response_writing)
            1
        else
            0;
    const response_phase: server_api.ManagedConnectionPhaseV1 =
        if (response_cancelled == 1) .response_ready else .none;
    const response_write_phase: server_api.ManagedConnectionPhaseV1 =
        if (response_write_requested == 1)
            .response_writing
        else
            .none;
    if (snapshot.full_request_timeout_cancelled_work_connections != 0 or
        snapshot.last_full_request_timeout_cancelled_work_phase !=
            .none or
        snapshot.full_request_timeout_cancelled_response_connections !=
            response_cancelled or
        snapshot.last_full_request_timeout_cancelled_response_phase !=
            response_phase or
        snapshot.full_request_timeout_requested_response_write_connections !=
            response_write_requested or
        snapshot.last_full_request_timeout_requested_response_write_phase !=
            response_write_phase or
        snapshot.full_request_timeout_cancelled_response_write_connections !=
            0 or
        snapshot.last_full_request_timeout_cancelled_response_write_phase !=
            .none)
    {
        return error.InvalidFullRequestTimeoutSignalReceipt;
    }
}

fn waitForReadyInactiveFullRequestTimeout(
    lifecycle: *server_api.ManagedLifecycleV1,
) !server_api.ManagedSnapshotV1 {
    while (true) {
        const snapshot = lifecycle.snapshotV1();
        if (snapshot.state != .ready)
            return error.UnexpectedLifecycleState;
        if (snapshot.active_connections == 0) {
            if (snapshot.active_connection_phase != .none or
                snapshot.accepted_connections != 1 or
                snapshot.completed_connections != 0 or
                snapshot.failed_connections != 1)
            {
                return error.InvalidFullRequestTimeoutRetirementReceipt;
            }
            return snapshot;
        }
        std.Thread.yield() catch {};
    }
}

fn forceDrainAndWake(
    lifecycle: *server_api.ManagedLifecycleV1,
    runtime: *http_server.RuntimeV1,
    listen_address: std.net.Address,
) void {
    server_api.requestDrainAndWakeV1(
        lifecycle,
        runtime,
        listen_address,
    ) catch {
        _ = http_server.beginDrainV1(runtime) catch {};
        const wake = std.net.tcpConnectToAddress(
            listen_address,
        ) catch return;
        wake.close();
    };
}

const DrainControl = enum {
    immediate,
    partial_head,
    partial_body,
    admitted_work,
    terminal_work,
    response_ready,
    response_completed,
    response_writing,
    response_writing_completed,

    fn requestedPhase(
        self: DrainControl,
    ) ?server_api.ManagedConnectionPhaseV1 {
        return switch (self) {
            .immediate,
            .admitted_work,
            .terminal_work,
            .response_ready,
            .response_completed,
            .response_writing,
            .response_writing_completed,
            => null,
            .partial_head => .receiving_head,
            .partial_body => .request_head_received,
        };
    }

    fn usesWorkBarrier(self: DrainControl) bool {
        return self == .admitted_work or
            self == .terminal_work;
    }

    fn expectsWorkCancellation(self: DrainControl) bool {
        return self == .admitted_work;
    }

    fn usesResponseBarrier(self: DrainControl) bool {
        return self == .response_ready or
            self == .response_completed or
            self.usesResponseProgressBarrier();
    }

    fn usesResponseProgressBarrier(self: DrainControl) bool {
        return self == .response_writing or
            self == .response_writing_completed;
    }

    fn repeatsDrain(self: DrainControl) bool {
        return self.usesWorkBarrier() or
            self == .response_ready or
            self == .response_writing;
    }
};

fn profileMatchesControl(
    profile: WorkerProfile,
    control: DrainControl,
) bool {
    return switch (profile) {
        .drain_work => control == .admitted_work,
        .drain_terminal_work => control == .terminal_work,
        .drain_response_ready => control == .response_ready,
        .complete_response_ready => control == .response_completed,
        .drain_response_writing => control == .response_writing,
        .complete_response_writing => control == .response_writing_completed,
        .full_request_timeout_request_admitted,
        .full_request_timeout_response_ready,
        .full_request_timeout_response_writing,
        => control == .immediate,
        .peer_reset_work => false,
        .concurrent_queued_receive_timeout,
        .concurrent_queued_full_request_timeout,
        .concurrent_drain,
        .concurrent_stale_owner_failure,
        .application_rejection,
        .native_load,
        => false,
        .standard,
        .drain_with_deadline,
        .timeout_head,
        .timeout_body,
        => control == .immediate or
            control.requestedPhase() != null,
    };
}

fn readDrainControl(stdin: std.fs.File) !DrainControl {
    var command: [complete_response_writing_command.len + 1]u8 =
        undefined;
    var count: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        const read_count = try stdin.read(&byte);
        if (read_count == 0) break;
        if (count == command.len)
            return error.InvalidControlCommand;
        command[count] = byte[0];
        count += 1;
    }
    if (count == 0 or
        std.mem.eql(u8, command[0..count], drain_command))
    {
        return .immediate;
    }
    if (std.mem.eql(
        u8,
        command[0..count],
        drain_head_command,
    )) {
        return .partial_head;
    }
    if (std.mem.eql(
        u8,
        command[0..count],
        drain_body_command,
    )) {
        return .partial_body;
    }
    if (std.mem.eql(
        u8,
        command[0..count],
        drain_work_command,
    )) {
        return .admitted_work;
    }
    if (std.mem.eql(
        u8,
        command[0..count],
        drain_terminal_work_command,
    )) {
        return .terminal_work;
    }
    if (std.mem.eql(
        u8,
        command[0..count],
        drain_response_ready_command,
    )) {
        return .response_ready;
    }
    if (std.mem.eql(
        u8,
        command[0..count],
        complete_response_ready_command,
    )) {
        return .response_completed;
    }
    if (std.mem.eql(
        u8,
        command[0..count],
        drain_response_writing_command,
    )) {
        return .response_writing;
    }
    if (std.mem.eql(
        u8,
        command[0..count],
        complete_response_writing_command,
    )) {
        return .response_writing_completed;
    }
    return error.InvalidControlCommand;
}

fn expectControlLine(
    stdin: std.fs.File,
    expected: []const u8,
) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    var count: usize = 0;
    while (count < storage.len) : (count += 1) {
        const read_count = try stdin.read(storage[count .. count + 1]);
        if (read_count == 0) return error.UnexpectedControlEof;
        if (storage[count] == '\n') {
            const line = storage[0 .. count + 1];
            if (!std.mem.eql(u8, line, expected))
                return error.InvalidControlCommand;
            return;
        }
    }
    return error.InvalidControlCommand;
}

fn waitForActivePhase(
    lifecycle: *server_api.ManagedLifecycleV1,
    expected: server_api.ManagedConnectionPhaseV1,
) !void {
    var polls: usize = 0;
    while (polls < control_poll_limit) : (polls += 1) {
        const snapshot = lifecycle.snapshotV1();
        if (snapshot.state != .ready)
            return error.UnexpectedLifecycleState;
        if (snapshot.active_connections == 1 and
            snapshot.active_connection_phase == expected)
        {
            return;
        }
        std.Thread.sleep(watchdog_poll_ns);
    }
    return error.ActivePhaseTimeout;
}

fn waitForInactiveConnection(
    lifecycle: *server_api.ManagedLifecycleV1,
) !void {
    var polls: usize = 0;
    while (polls < control_poll_limit) : (polls += 1) {
        const snapshot = lifecycle.snapshotV1();
        if (snapshot.state != .draining and
            snapshot.state != .stopped)
        {
            return error.UnexpectedLifecycleState;
        }
        if (snapshot.active_connections == 0 and
            snapshot.active_connection_phase == .none)
        {
            return;
        }
        std.Thread.sleep(watchdog_poll_ns);
    }
    return error.InactiveConnectionTimeout;
}

fn waitForReceiveTimeout(
    lifecycle: *server_api.ManagedLifecycleV1,
    expected_phase: server_api.ManagedConnectionPhaseV1,
) !server_api.ManagedSnapshotV1 {
    var polls: usize = 0;
    while (polls < control_poll_limit) : (polls += 1) {
        const snapshot = lifecycle.snapshotV1();
        if (snapshot.state != .ready)
            return error.UnexpectedLifecycleState;
        if (snapshot.receive_timeout_signaled_connections == 1 and
            snapshot.last_receive_timeout_signaled_phase ==
                expected_phase and
            snapshot.active_connections == 0 and
            snapshot.active_connection_phase == .none)
        {
            if (snapshot.accepted_connections != 1 or
                snapshot.completed_connections != 0 or
                snapshot.failed_connections != 1 or
                snapshot.drain_signaled_connections != 0 or
                snapshot.last_drain_signaled_phase != .none)
            {
                return error.InvalidReceiveTimeoutReceipt;
            }
            return snapshot;
        }
        std.Thread.sleep(watchdog_poll_ns);
    }
    return error.ReceiveTimeoutObservationTimeout;
}

fn validateDrainSignalReceipt(
    snapshot: server_api.ManagedSnapshotV1,
    expected_phase: ?server_api.ManagedConnectionPhaseV1,
) !void {
    if (expected_phase) |phase| {
        if (snapshot.drain_signaled_connections != 1 or
            snapshot.last_drain_signaled_phase != phase)
        {
            return error.InvalidDrainSignalReceipt;
        }
    } else if (snapshot.drain_signaled_connections != 0 or
        snapshot.last_drain_signaled_phase != .none)
    {
        return error.InvalidDrainSignalReceipt;
    }
}

fn validateDrainWorkReceipt(
    snapshot: server_api.ManagedSnapshotV1,
    expected: bool,
) !void {
    if (expected) {
        if (snapshot.drain_cancelled_work_connections != 1 or
            snapshot.last_drain_cancelled_work_phase !=
                .request_admitted)
        {
            return error.InvalidDrainWorkReceipt;
        }
    } else if (snapshot.drain_cancelled_work_connections != 0 or
        snapshot.last_drain_cancelled_work_phase != .none)
    {
        return error.InvalidDrainWorkReceipt;
    }
}

fn validatePhaseEReceipt(
    snapshot: server_api.ManagedSnapshotV1,
    profile: WorkerProfile,
) !void {
    const expected_peer_reset: u64 =
        if (profile == .peer_reset_work) 1 else 0;
    const expected_response_cancel: u64 =
        if (profile == .drain_response_ready) 1 else 0;
    const expected_response_write_cancel: u64 =
        if (profile == .drain_response_writing) 1 else 0;
    const expected_full_request_timeout: u64 =
        if (profile.isFullRequestTimeout()) 1 else 0;
    const expected_full_request_timeout_work: u64 =
        if (profile == .full_request_timeout_request_admitted)
            1
        else
            0;
    const expected_full_request_timeout_response: u64 =
        if (profile == .full_request_timeout_response_ready)
            1
        else
            0;
    const expected_full_request_timeout_response_write: u64 =
        if (profile == .full_request_timeout_response_writing)
            1
        else
            0;
    const expected_peer_reset_phase: server_api.ManagedConnectionPhaseV1 =
        if (expected_peer_reset == 1)
            .request_admitted
        else
            .none;
    const expected_response_cancel_phase: server_api.ManagedConnectionPhaseV1 =
        if (expected_response_cancel == 1)
            .response_ready
        else
            .none;
    const expected_response_write_phase: server_api.ManagedConnectionPhaseV1 =
        if (expected_response_write_cancel == 1)
            .response_writing
        else
            .none;
    const expected_full_request_timeout_phase =
        profile.fullRequestTimeoutPhase() orelse .none;
    const expected_full_request_timeout_work_phase: server_api.ManagedConnectionPhaseV1 =
        if (expected_full_request_timeout_work == 1)
            .request_admitted
        else
            .none;
    const expected_full_request_timeout_response_phase: server_api.ManagedConnectionPhaseV1 =
        if (expected_full_request_timeout_response == 1)
            .response_ready
        else
            .none;
    const expected_full_request_timeout_response_write_phase: server_api.ManagedConnectionPhaseV1 =
        if (expected_full_request_timeout_response_write == 1)
            .response_writing
        else
            .none;
    if (snapshot.peer_reset_connections != expected_peer_reset or
        snapshot.peer_reset_cancelled_work_connections !=
            expected_peer_reset or
        snapshot.drain_cancelled_response_connections !=
            expected_response_cancel or
        snapshot.drain_requested_response_write_connections !=
            expected_response_write_cancel or
        snapshot.drain_cancelled_response_write_connections !=
            expected_response_write_cancel or
        snapshot.full_request_timeout_signaled_connections !=
            expected_full_request_timeout or
        snapshot.full_request_timeout_cancelled_work_connections !=
            expected_full_request_timeout_work or
        snapshot.full_request_timeout_cancelled_response_connections !=
            expected_full_request_timeout_response or
        snapshot.full_request_timeout_requested_response_write_connections !=
            expected_full_request_timeout_response_write or
        snapshot.full_request_timeout_cancelled_response_write_connections !=
            expected_full_request_timeout_response_write or
        snapshot.response_write_transport_failed_connections != 0 or
        snapshot.last_peer_reset_phase !=
            expected_peer_reset_phase or
        snapshot.last_peer_reset_cancelled_work_phase !=
            expected_peer_reset_phase or
        snapshot.last_drain_cancelled_response_phase !=
            expected_response_cancel_phase or
        snapshot.last_drain_requested_response_write_phase !=
            expected_response_write_phase or
        snapshot.last_drain_cancelled_response_write_phase !=
            expected_response_write_phase or
        snapshot.last_full_request_timeout_signaled_phase !=
            expected_full_request_timeout_phase or
        snapshot.last_full_request_timeout_cancelled_work_phase !=
            expected_full_request_timeout_work_phase or
        snapshot.last_full_request_timeout_cancelled_response_phase !=
            expected_full_request_timeout_response_phase or
        snapshot.last_full_request_timeout_requested_response_write_phase !=
            expected_full_request_timeout_response_write_phase or
        snapshot.last_full_request_timeout_cancelled_response_write_phase !=
            expected_full_request_timeout_response_write_phase or
        snapshot.last_response_write_transport_failed_phase != .none)
    {
        return error.InvalidPhaseEReceipt;
    }
}

fn emitReady(
    generation: u64,
    port: u16,
    model_id: *const [protocol.model_id_bytes]u8,
) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &storage,
        "READY {d} {d} {s}\n",
        .{ generation, port, model_id },
    );
    try std.fs.File.stdout().writeAll(frame);
}

fn emitCheckpoint(name: []const u8, generation: u64) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &storage,
        "{s} {d}\n",
        .{ name, generation },
    );
    try std.fs.File.stdout().writeAll(frame);
}

fn emitConcurrentEventCheckpoint(
    name: []const u8,
    event: server_api.ManagedConcurrentEventV1,
) !void {
    const lease = event.lease orelse
        return error.MissingConcurrentCheckpointLease;
    var storage: [frame_max_bytes]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &storage,
        "{s} {d} {d} {d} {d} {d} {d}\n",
        .{
            name,
            lease.process_generation,
            lease.connection_sequence,
            lease.slot_index,
            lease.slot_generation,
            event.ordinal,
            @intFromEnum(event.kind),
        },
    );
    try std.fs.File.stdout().writeAll(frame);
}

fn responseOutcomeWire(
    outcome: ?http_server.ResponseWriteOutcomeV1,
) u8 {
    return if (outcome) |value|
        @as(u8, @intFromEnum(value)) + 1
    else
        0;
}

fn emitDraining(
    snapshot: server_api.ManagedSnapshotV1,
    response_outcome: ?http_server.ResponseWriteOutcomeV1,
) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &storage,
        "DRAINING " ++
            "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} " ++
            "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} ",
        .{
            snapshot.process_generation,
            snapshot.accepted_connections,
            snapshot.completed_connections,
            snapshot.failed_connections,
            snapshot.active_connections,
            snapshot.drain_signaled_connections,
            @intFromEnum(snapshot.last_drain_signaled_phase),
            snapshot.drain_cancelled_work_connections,
            @intFromEnum(
                snapshot.last_drain_cancelled_work_phase,
            ),
            snapshot.receive_timeout_signaled_connections,
            @intFromEnum(
                snapshot.last_receive_timeout_signaled_phase,
            ),
            snapshot.full_request_timeout_signaled_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_signaled_phase,
            ),
            snapshot.full_request_timeout_cancelled_work_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_cancelled_work_phase,
            ),
            snapshot.full_request_timeout_cancelled_response_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_cancelled_response_phase,
            ),
            snapshot.full_request_timeout_requested_response_write_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_requested_response_write_phase,
            ),
            snapshot.full_request_timeout_cancelled_response_write_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_cancelled_response_write_phase,
            ),
        },
    );
    const suffix = try std.fmt.bufPrint(
        storage[prefix.len..],
        "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n",
        .{
            snapshot.peer_reset_connections,
            snapshot.peer_reset_cancelled_work_connections,
            @intFromEnum(snapshot.last_peer_reset_phase),
            snapshot.drain_cancelled_response_connections,
            @intFromEnum(
                snapshot.last_drain_cancelled_response_phase,
            ),
            @intFromEnum(
                snapshot.last_peer_reset_cancelled_work_phase,
            ),
            snapshot.drain_requested_response_write_connections,
            @intFromEnum(
                snapshot.last_drain_requested_response_write_phase,
            ),
            snapshot.drain_cancelled_response_write_connections,
            @intFromEnum(
                snapshot.last_drain_cancelled_response_write_phase,
            ),
            snapshot.response_write_transport_failed_connections,
            @intFromEnum(
                snapshot.last_response_write_transport_failed_phase,
            ),
            responseOutcomeWire(response_outcome),
        },
    );
    try std.fs.File.stdout().writeAll(
        storage[0 .. prefix.len + suffix.len],
    );
}

fn emitTimedOut(
    generation: u64,
    phase: server_api.ManagedConnectionPhaseV1,
) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &storage,
        "TIMED_OUT {d} {d}\n",
        .{
            generation,
            @intFromEnum(phase),
        },
    );
    try std.fs.File.stdout().writeAll(frame);
}

fn emitClosed(
    snapshot: server_api.ManagedSnapshotV1,
    service_active: u32,
    terminal_records: u32,
    response_outcome: ?http_server.ResponseWriteOutcomeV1,
) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &storage,
        "CLOSED " ++
            "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} " ++
            "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} ",
        .{
            snapshot.process_generation,
            snapshot.accepted_connections,
            snapshot.completed_connections,
            snapshot.failed_connections,
            snapshot.active_connections,
            snapshot.drain_signaled_connections,
            @intFromEnum(snapshot.last_drain_signaled_phase),
            snapshot.drain_cancelled_work_connections,
            @intFromEnum(
                snapshot.last_drain_cancelled_work_phase,
            ),
            snapshot.receive_timeout_signaled_connections,
            @intFromEnum(
                snapshot.last_receive_timeout_signaled_phase,
            ),
            snapshot.full_request_timeout_signaled_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_signaled_phase,
            ),
            snapshot.full_request_timeout_cancelled_work_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_cancelled_work_phase,
            ),
            snapshot.full_request_timeout_cancelled_response_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_cancelled_response_phase,
            ),
            snapshot.full_request_timeout_requested_response_write_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_requested_response_write_phase,
            ),
            snapshot.full_request_timeout_cancelled_response_write_connections,
            @intFromEnum(
                snapshot.last_full_request_timeout_cancelled_response_write_phase,
            ),
        },
    );
    const suffix = try std.fmt.bufPrint(
        storage[prefix.len..],
        "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} " ++
            "{d} {d} 1\n",
        .{
            snapshot.peer_reset_connections,
            snapshot.peer_reset_cancelled_work_connections,
            @intFromEnum(snapshot.last_peer_reset_phase),
            snapshot.drain_cancelled_response_connections,
            @intFromEnum(
                snapshot.last_drain_cancelled_response_phase,
            ),
            @intFromEnum(
                snapshot.last_peer_reset_cancelled_work_phase,
            ),
            snapshot.drain_requested_response_write_connections,
            @intFromEnum(
                snapshot.last_drain_requested_response_write_phase,
            ),
            snapshot.drain_cancelled_response_write_connections,
            @intFromEnum(
                snapshot.last_drain_cancelled_response_write_phase,
            ),
            snapshot.response_write_transport_failed_connections,
            @intFromEnum(
                snapshot.last_response_write_transport_failed_phase,
            ),
            responseOutcomeWire(response_outcome),
            service_active,
            terminal_records,
        },
    );
    try std.fs.File.stdout().writeAll(
        storage[0 .. prefix.len + suffix.len],
    );
}

fn emitConcurrentClosed(
    profile: WorkerProfile,
    snapshot: server_api.ManagedConcurrentSnapshotV1,
    event_count: usize,
    service_snapshot: unary.SnapshotV1,
    scheduler_zero: bool,
    bank_zero: bool,
    serve_joined: bool,
    serving: bool,
) !void {
    const phase_total =
        snapshot.phase_counts.queued +
        snapshot.phase_counts.receiving_head +
        snapshot.phase_counts.request_head_received +
        snapshot.phase_counts.request_received +
        snapshot.phase_counts.request_admitted +
        snapshot.phase_counts.response_ready +
        snapshot.phase_counts.response_writing +
        snapshot.phase_counts.response_written;
    var snapshot_storage: [frame_max_bytes]u8 = undefined;
    const snapshot_frame = try std.fmt.bufPrint(
        &snapshot_storage,
        "CONCURRENT_SNAPSHOT " ++
            "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} " ++
            "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n",
        .{
            @intFromEnum(profile),
            snapshot.managed.process_generation,
            @intFromEnum(snapshot.managed.state),
            snapshot.worker_count,
            snapshot.pending_connection_capacity,
            snapshot.managed.accepted_connections,
            snapshot.managed.completed_connections,
            snapshot.managed.failed_connections,
            snapshot.managed.active_connections,
            snapshot.managed.queued_connections,
            snapshot.running_connections,
            phase_total,
            snapshot.queue_high_watermark,
            snapshot.running_high_watermark,
            snapshot.queue_enqueued_connections,
            snapshot.queue_dispatched_connections,
            snapshot.listener_backpressure_activations,
            snapshot.listener_backpressure_resumptions,
            snapshot.event_ordinal,
            event_count,
            @intFromBool(snapshot.cleanup_failed),
        },
    );
    try std.fs.File.stdout().writeAll(snapshot_frame);

    var cause_storage: [frame_max_bytes]u8 = undefined;
    const cause_frame = try std.fmt.bufPrint(
        &cause_storage,
        "CONCURRENT_CAUSES " ++
            "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} " ++
            "{d} {d} {d} {d} {d} {d} {d} {d}\n",
        .{
            snapshot.managed.process_generation,
            snapshot.drain_cancelled_queued_connections,
            snapshot.failure_cancelled_queued_connections,
            snapshot.receive_timeout_queued_connections,
            snapshot.full_request_timeout_queued_connections,
            snapshot.managed.drain_signaled_connections,
            @intFromEnum(
                snapshot.managed.last_drain_signaled_phase,
            ),
            snapshot.managed.failure_signaled_connections,
            @intFromEnum(
                snapshot.managed.last_failure_signaled_phase,
            ),
            snapshot.managed.receive_timeout_signaled_connections,
            @intFromEnum(
                snapshot.managed.last_receive_timeout_signaled_phase,
            ),
            snapshot.managed.full_request_timeout_signaled_connections,
            @intFromEnum(
                snapshot.managed.last_full_request_timeout_signaled_phase,
            ),
            snapshot.managed.drain_cancelled_work_connections,
            snapshot.managed.failure_cancelled_work_connections,
            snapshot.managed.failure_cancelled_response_connections,
            snapshot.managed.failure_requested_response_write_connections,
            snapshot.managed.failure_cancelled_response_write_connections,
        },
    );
    try std.fs.File.stdout().writeAll(cause_frame);

    var ownership_storage: [frame_max_bytes]u8 = undefined;
    const ownership_frame = try std.fmt.bufPrint(
        &ownership_storage,
        "CONCURRENT_OWNERSHIP " ++
            "{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n",
        .{
            snapshot.managed.process_generation,
            service_snapshot.active_requests,
            service_snapshot.recovery_required,
            service_snapshot.terminal_records,
            service_snapshot.completed_records,
            service_snapshot.cancelled_records,
            service_snapshot.failed_records,
            @intFromBool(scheduler_zero),
            @intFromBool(bank_zero),
            @intFromBool(serve_joined),
            @intFromBool(serving),
        },
    );
    try std.fs.File.stdout().writeAll(ownership_frame);
}

const ReadyFrame = struct {
    generation: u64,
    port: u16,
    model_id: [protocol.model_id_bytes]u8,
};

const ActivityFrame = struct {
    generation: u64,
    accepted: u64,
    completed: u64,
    failed: u64,
    active: u8,
    drain_signaled: u64,
    last_drain_phase: server_api.ManagedConnectionPhaseV1,
    drain_cancelled_work: u64,
    last_drain_cancelled_work_phase: server_api.ManagedConnectionPhaseV1,
    receive_timeout_signaled: u64,
    last_receive_timeout_phase: server_api.ManagedConnectionPhaseV1,
    full_request_timeout_signaled: u64,
    last_full_request_timeout_signaled_phase: server_api.ManagedConnectionPhaseV1,
    full_request_timeout_cancelled_work: u64,
    last_full_request_timeout_cancelled_work_phase: server_api.ManagedConnectionPhaseV1,
    full_request_timeout_cancelled_response: u64,
    last_full_request_timeout_cancelled_response_phase: server_api.ManagedConnectionPhaseV1,
    full_request_timeout_requested_response_write: u64,
    last_full_request_timeout_requested_response_write_phase: server_api.ManagedConnectionPhaseV1,
    full_request_timeout_cancelled_response_write: u64,
    last_full_request_timeout_cancelled_response_write_phase: server_api.ManagedConnectionPhaseV1,
    peer_reset: u64,
    peer_reset_cancelled_work: u64,
    last_peer_reset_phase: server_api.ManagedConnectionPhaseV1,
    drain_cancelled_response: u64,
    last_drain_cancelled_response_phase: server_api.ManagedConnectionPhaseV1,
    last_peer_reset_cancelled_work_phase: server_api.ManagedConnectionPhaseV1,
    drain_requested_response_write: u64,
    last_drain_requested_response_write_phase: server_api.ManagedConnectionPhaseV1,
    drain_cancelled_response_write: u64,
    last_drain_cancelled_response_write_phase: server_api.ManagedConnectionPhaseV1,
    response_write_transport_failed: u64,
    last_response_write_transport_failed_phase: server_api.ManagedConnectionPhaseV1,
    response_outcome: u8,
};

const TimeoutFrame = struct {
    generation: u64,
    phase: server_api.ManagedConnectionPhaseV1,
};

const ClosedFrame = struct {
    activity: ActivityFrame,
    service_active: u32,
    terminal_records: u32,
    bank_zero: u8,
};

const ConcurrentEventFrame = struct {
    generation: u64,
    connection_sequence: u64,
    slot_index: u8,
    slot_generation: u64,
    ordinal: u64,
    kind: server_api.ManagedConcurrentEventKindV1,
};

const ConcurrentSnapshotFrame = struct {
    profile: WorkerProfile,
    generation: u64,
    state: server_api.ManagedStateV1,
    worker_count: u8,
    pending_capacity: u8,
    accepted: u64,
    completed: u64,
    failed: u64,
    active: u8,
    queued: u8,
    running: u8,
    phase_total: u8,
    queue_high_watermark: u8,
    running_high_watermark: u8,
    enqueued: u64,
    dispatched: u64,
    backpressure_activations: u64,
    backpressure_resumptions: u64,
    event_ordinal: u64,
    event_count: usize,
    cleanup_failed: u8,
};

const ConcurrentCauseFrame = struct {
    generation: u64,
    drain_queued: u64,
    failure_queued: u64,
    receive_timeout_queued: u64,
    full_request_timeout_queued: u64,
    drain_signaled: u64,
    last_drain_phase: server_api.ManagedConnectionPhaseV1,
    failure_signaled: u64,
    last_failure_phase: server_api.ManagedConnectionPhaseV1,
    receive_timeout_signaled: u64,
    last_receive_timeout_phase: server_api.ManagedConnectionPhaseV1,
    full_request_timeout_signaled: u64,
    last_full_request_timeout_phase: server_api.ManagedConnectionPhaseV1,
    drain_cancelled_work: u64,
    failure_cancelled_work: u64,
    failure_cancelled_response: u64,
    failure_requested_response_write: u64,
    failure_cancelled_response_write: u64,
};

const ConcurrentOwnershipFrame = struct {
    generation: u64,
    service_active: u32,
    recovery_required: u32,
    terminal_records: u32,
    completed_records: u32,
    cancelled_records: u32,
    failed_records: u32,
    scheduler_zero: u8,
    bank_zero: u8,
    serve_joined: u8,
    serving: u8,
};

fn readFrame(
    stdout: std.fs.File,
    storage: *[frame_max_bytes]u8,
) ![]const u8 {
    var count: usize = 0;
    while (count < storage.len) {
        var byte: [1]u8 = undefined;
        const read_count = try stdout.read(&byte);
        if (read_count == 0)
            return error.UnexpectedFrameEof;
        if (byte[0] == '\n') {
            if (count == 0) return error.InvalidFrame;
            return storage[0..count];
        }
        storage[count] = byte[0];
        count += 1;
    }
    return error.FrameTooLarge;
}

fn parseReady(line: []const u8) !ReadyFrame {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return error.InvalidFrame;
    const generation_text =
        fields.next() orelse return error.InvalidFrame;
    const port_text = fields.next() orelse
        return error.InvalidFrame;
    const model_id = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(u8, name, "READY") or
        model_id.len != protocol.model_id_bytes or
        !validModelId(model_id))
    {
        return error.InvalidFrame;
    }

    var result: ReadyFrame = .{
        .generation = try parseCanonicalInt(
            u64,
            generation_text,
        ),
        .port = try parseCanonicalInt(u16, port_text),
        .model_id = undefined,
    };
    if (result.port == 0) return error.InvalidFrame;
    @memcpy(&result.model_id, model_id);
    return result;
}

fn expectCheckpointFrame(
    line: []const u8,
    expected_name: []const u8,
    expected_generation: u64,
) !void {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return error.InvalidFrame;
    const generation = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(u8, name, expected_name) or
        try parseCanonicalInt(u64, generation) !=
            expected_generation)
    {
        return error.InvalidFrame;
    }
}

fn parseConcurrentEventFrame(
    line: []const u8,
    expected_name: []const u8,
) !ConcurrentEventFrame {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return error.InvalidFrame;
    const generation = fields.next() orelse
        return error.InvalidFrame;
    const sequence = fields.next() orelse
        return error.InvalidFrame;
    const slot_index = fields.next() orelse
        return error.InvalidFrame;
    const slot_generation = fields.next() orelse
        return error.InvalidFrame;
    const ordinal = fields.next() orelse
        return error.InvalidFrame;
    const kind = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(u8, name, expected_name))
    {
        return error.InvalidFrame;
    }
    return .{
        .generation = try parseCanonicalInt(
            u64,
            generation,
        ),
        .connection_sequence = try parseCanonicalInt(
            u64,
            sequence,
        ),
        .slot_index = try parseCanonicalInt(
            u8,
            slot_index,
        ),
        .slot_generation = try parseCanonicalInt(
            u64,
            slot_generation,
        ),
        .ordinal = try parseCanonicalInt(u64, ordinal),
        .kind = std.meta.intToEnum(
            server_api.ManagedConcurrentEventKindV1,
            try parseCanonicalInt(u8, kind),
        ) catch return error.InvalidFrame,
    };
}

fn parseConcurrentSnapshotFrame(
    line: []const u8,
) !ConcurrentSnapshotFrame {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return error.InvalidFrame;
    const profile = fields.next() orelse
        return error.InvalidFrame;
    const generation = fields.next() orelse
        return error.InvalidFrame;
    const state = fields.next() orelse
        return error.InvalidFrame;
    const worker_count = fields.next() orelse
        return error.InvalidFrame;
    const pending_capacity = fields.next() orelse
        return error.InvalidFrame;
    const accepted = fields.next() orelse
        return error.InvalidFrame;
    const completed = fields.next() orelse
        return error.InvalidFrame;
    const failed = fields.next() orelse
        return error.InvalidFrame;
    const active = fields.next() orelse
        return error.InvalidFrame;
    const queued = fields.next() orelse
        return error.InvalidFrame;
    const running = fields.next() orelse
        return error.InvalidFrame;
    const phase_total = fields.next() orelse
        return error.InvalidFrame;
    const queue_high_watermark = fields.next() orelse
        return error.InvalidFrame;
    const running_high_watermark = fields.next() orelse
        return error.InvalidFrame;
    const enqueued = fields.next() orelse
        return error.InvalidFrame;
    const dispatched = fields.next() orelse
        return error.InvalidFrame;
    const activations = fields.next() orelse
        return error.InvalidFrame;
    const resumptions = fields.next() orelse
        return error.InvalidFrame;
    const event_ordinal = fields.next() orelse
        return error.InvalidFrame;
    const event_count = fields.next() orelse
        return error.InvalidFrame;
    const cleanup_failed = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(u8, name, "CONCURRENT_SNAPSHOT"))
    {
        return error.InvalidFrame;
    }
    return .{
        .profile = std.meta.intToEnum(
            WorkerProfile,
            try parseCanonicalInt(u8, profile),
        ) catch return error.InvalidFrame,
        .generation = try parseCanonicalInt(
            u64,
            generation,
        ),
        .state = std.meta.intToEnum(
            server_api.ManagedStateV1,
            try parseCanonicalInt(u8, state),
        ) catch return error.InvalidFrame,
        .worker_count = try parseCanonicalInt(
            u8,
            worker_count,
        ),
        .pending_capacity = try parseCanonicalInt(
            u8,
            pending_capacity,
        ),
        .accepted = try parseCanonicalInt(u64, accepted),
        .completed = try parseCanonicalInt(u64, completed),
        .failed = try parseCanonicalInt(u64, failed),
        .active = try parseCanonicalInt(u8, active),
        .queued = try parseCanonicalInt(u8, queued),
        .running = try parseCanonicalInt(u8, running),
        .phase_total = try parseCanonicalInt(
            u8,
            phase_total,
        ),
        .queue_high_watermark = try parseCanonicalInt(
            u8,
            queue_high_watermark,
        ),
        .running_high_watermark = try parseCanonicalInt(
            u8,
            running_high_watermark,
        ),
        .enqueued = try parseCanonicalInt(u64, enqueued),
        .dispatched = try parseCanonicalInt(
            u64,
            dispatched,
        ),
        .backpressure_activations = try parseCanonicalInt(
            u64,
            activations,
        ),
        .backpressure_resumptions = try parseCanonicalInt(
            u64,
            resumptions,
        ),
        .event_ordinal = try parseCanonicalInt(
            u64,
            event_ordinal,
        ),
        .event_count = try parseCanonicalInt(
            usize,
            event_count,
        ),
        .cleanup_failed = try parseCanonicalInt(
            u8,
            cleanup_failed,
        ),
    };
}

fn parseConcurrentCauseFrame(
    line: []const u8,
) !ConcurrentCauseFrame {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return error.InvalidFrame;
    const generation = fields.next() orelse
        return error.InvalidFrame;
    const drain_queued = fields.next() orelse
        return error.InvalidFrame;
    const failure_queued = fields.next() orelse
        return error.InvalidFrame;
    const receive_queued = fields.next() orelse
        return error.InvalidFrame;
    const full_queued = fields.next() orelse
        return error.InvalidFrame;
    const drain_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_drain = fields.next() orelse
        return error.InvalidFrame;
    const failure_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_failure = fields.next() orelse
        return error.InvalidFrame;
    const receive_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_receive = fields.next() orelse
        return error.InvalidFrame;
    const full_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_full = fields.next() orelse
        return error.InvalidFrame;
    const drain_work = fields.next() orelse
        return error.InvalidFrame;
    const failure_work = fields.next() orelse
        return error.InvalidFrame;
    const failure_response = fields.next() orelse
        return error.InvalidFrame;
    const failure_write_requested = fields.next() orelse
        return error.InvalidFrame;
    const failure_write_cancelled = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(u8, name, "CONCURRENT_CAUSES"))
    {
        return error.InvalidFrame;
    }
    return .{
        .generation = try parseCanonicalInt(
            u64,
            generation,
        ),
        .drain_queued = try parseCanonicalInt(
            u64,
            drain_queued,
        ),
        .failure_queued = try parseCanonicalInt(
            u64,
            failure_queued,
        ),
        .receive_timeout_queued = try parseCanonicalInt(
            u64,
            receive_queued,
        ),
        .full_request_timeout_queued = try parseCanonicalInt(
            u64,
            full_queued,
        ),
        .drain_signaled = try parseCanonicalInt(
            u64,
            drain_signaled,
        ),
        .last_drain_phase = try parseConnectionPhase(
            last_drain,
        ),
        .failure_signaled = try parseCanonicalInt(
            u64,
            failure_signaled,
        ),
        .last_failure_phase = try parseConnectionPhase(
            last_failure,
        ),
        .receive_timeout_signaled = try parseCanonicalInt(
            u64,
            receive_signaled,
        ),
        .last_receive_timeout_phase = try parseConnectionPhase(last_receive),
        .full_request_timeout_signaled = try parseCanonicalInt(u64, full_signaled),
        .last_full_request_timeout_phase = try parseConnectionPhase(last_full),
        .drain_cancelled_work = try parseCanonicalInt(
            u64,
            drain_work,
        ),
        .failure_cancelled_work = try parseCanonicalInt(
            u64,
            failure_work,
        ),
        .failure_cancelled_response = try parseCanonicalInt(u64, failure_response),
        .failure_requested_response_write = try parseCanonicalInt(
            u64,
            failure_write_requested,
        ),
        .failure_cancelled_response_write = try parseCanonicalInt(
            u64,
            failure_write_cancelled,
        ),
    };
}

fn parseConcurrentOwnershipFrame(
    line: []const u8,
) !ConcurrentOwnershipFrame {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return error.InvalidFrame;
    const generation = fields.next() orelse
        return error.InvalidFrame;
    const service_active = fields.next() orelse
        return error.InvalidFrame;
    const recovery_required = fields.next() orelse
        return error.InvalidFrame;
    const terminal_records = fields.next() orelse
        return error.InvalidFrame;
    const completed_records = fields.next() orelse
        return error.InvalidFrame;
    const cancelled_records = fields.next() orelse
        return error.InvalidFrame;
    const failed_records = fields.next() orelse
        return error.InvalidFrame;
    const scheduler_zero = fields.next() orelse
        return error.InvalidFrame;
    const bank_zero = fields.next() orelse
        return error.InvalidFrame;
    const serve_joined = fields.next() orelse
        return error.InvalidFrame;
    const serving = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(u8, name, "CONCURRENT_OWNERSHIP"))
    {
        return error.InvalidFrame;
    }
    return .{
        .generation = try parseCanonicalInt(
            u64,
            generation,
        ),
        .service_active = try parseCanonicalInt(
            u32,
            service_active,
        ),
        .recovery_required = try parseCanonicalInt(
            u32,
            recovery_required,
        ),
        .terminal_records = try parseCanonicalInt(
            u32,
            terminal_records,
        ),
        .completed_records = try parseCanonicalInt(
            u32,
            completed_records,
        ),
        .cancelled_records = try parseCanonicalInt(
            u32,
            cancelled_records,
        ),
        .failed_records = try parseCanonicalInt(
            u32,
            failed_records,
        ),
        .scheduler_zero = try parseCanonicalInt(
            u8,
            scheduler_zero,
        ),
        .bank_zero = try parseCanonicalInt(
            u8,
            bank_zero,
        ),
        .serve_joined = try parseCanonicalInt(
            u8,
            serve_joined,
        ),
        .serving = try parseCanonicalInt(u8, serving),
    };
}

fn parseActivity(
    line: []const u8,
    expected_name: []const u8,
) !ActivityFrame {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return error.InvalidFrame;
    const generation = fields.next() orelse
        return error.InvalidFrame;
    const accepted = fields.next() orelse
        return error.InvalidFrame;
    const completed = fields.next() orelse
        return error.InvalidFrame;
    const failed = fields.next() orelse
        return error.InvalidFrame;
    const active = fields.next() orelse
        return error.InvalidFrame;
    const drain_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_phase = fields.next() orelse
        return error.InvalidFrame;
    const drain_cancelled_work = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_cancelled_work_phase =
        fields.next() orelse return error.InvalidFrame;
    const receive_timeout_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_receive_timeout_phase = fields.next() orelse
        return error.InvalidFrame;
    const full_request_timeout_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_full_request_timeout_signaled_phase =
        fields.next() orelse return error.InvalidFrame;
    const full_request_timeout_cancelled_work =
        fields.next() orelse return error.InvalidFrame;
    const last_full_request_timeout_cancelled_work_phase =
        fields.next() orelse return error.InvalidFrame;
    const full_request_timeout_cancelled_response =
        fields.next() orelse return error.InvalidFrame;
    const last_full_request_timeout_cancelled_response_phase =
        fields.next() orelse return error.InvalidFrame;
    const full_request_timeout_requested_response_write =
        fields.next() orelse return error.InvalidFrame;
    const last_full_request_timeout_requested_response_write_phase =
        fields.next() orelse return error.InvalidFrame;
    const full_request_timeout_cancelled_response_write =
        fields.next() orelse return error.InvalidFrame;
    const last_full_request_timeout_cancelled_response_write_phase =
        fields.next() orelse return error.InvalidFrame;
    const peer_reset = fields.next() orelse
        return error.InvalidFrame;
    const peer_reset_cancelled_work = fields.next() orelse
        return error.InvalidFrame;
    const last_peer_reset_phase = fields.next() orelse
        return error.InvalidFrame;
    const drain_cancelled_response = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_cancelled_response_phase =
        fields.next() orelse return error.InvalidFrame;
    const last_peer_reset_cancelled_work_phase =
        fields.next() orelse return error.InvalidFrame;
    const drain_requested_response_write = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_requested_response_write_phase =
        fields.next() orelse return error.InvalidFrame;
    const drain_cancelled_response_write = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_cancelled_response_write_phase =
        fields.next() orelse return error.InvalidFrame;
    const response_write_transport_failed = fields.next() orelse
        return error.InvalidFrame;
    const last_response_write_transport_failed_phase =
        fields.next() orelse return error.InvalidFrame;
    const response_outcome = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(u8, name, expected_name))
    {
        return error.InvalidFrame;
    }
    return .{
        .generation = try parseCanonicalInt(u64, generation),
        .accepted = try parseCanonicalInt(u64, accepted),
        .completed = try parseCanonicalInt(u64, completed),
        .failed = try parseCanonicalInt(u64, failed),
        .active = try parseCanonicalInt(u8, active),
        .drain_signaled = try parseCanonicalInt(u64, drain_signaled),
        .last_drain_phase = try parseConnectionPhase(last_drain_phase),
        .drain_cancelled_work = try parseCanonicalInt(
            u64,
            drain_cancelled_work,
        ),
        .last_drain_cancelled_work_phase = try parseConnectionPhase(
            last_drain_cancelled_work_phase,
        ),
        .receive_timeout_signaled = try parseCanonicalInt(
            u64,
            receive_timeout_signaled,
        ),
        .last_receive_timeout_phase = try parseConnectionPhase(
            last_receive_timeout_phase,
        ),
        .full_request_timeout_signaled = try parseCanonicalInt(
            u64,
            full_request_timeout_signaled,
        ),
        .last_full_request_timeout_signaled_phase = try parseConnectionPhase(
            last_full_request_timeout_signaled_phase,
        ),
        .full_request_timeout_cancelled_work = try parseCanonicalInt(
            u64,
            full_request_timeout_cancelled_work,
        ),
        .last_full_request_timeout_cancelled_work_phase = try parseConnectionPhase(
            last_full_request_timeout_cancelled_work_phase,
        ),
        .full_request_timeout_cancelled_response = try parseCanonicalInt(
            u64,
            full_request_timeout_cancelled_response,
        ),
        .last_full_request_timeout_cancelled_response_phase = try parseConnectionPhase(
            last_full_request_timeout_cancelled_response_phase,
        ),
        .full_request_timeout_requested_response_write = try parseCanonicalInt(
            u64,
            full_request_timeout_requested_response_write,
        ),
        .last_full_request_timeout_requested_response_write_phase = try parseConnectionPhase(
            last_full_request_timeout_requested_response_write_phase,
        ),
        .full_request_timeout_cancelled_response_write = try parseCanonicalInt(
            u64,
            full_request_timeout_cancelled_response_write,
        ),
        .last_full_request_timeout_cancelled_response_write_phase = try parseConnectionPhase(
            last_full_request_timeout_cancelled_response_write_phase,
        ),
        .peer_reset = try parseCanonicalInt(u64, peer_reset),
        .peer_reset_cancelled_work = try parseCanonicalInt(
            u64,
            peer_reset_cancelled_work,
        ),
        .last_peer_reset_phase = try parseConnectionPhase(
            last_peer_reset_phase,
        ),
        .drain_cancelled_response = try parseCanonicalInt(
            u64,
            drain_cancelled_response,
        ),
        .last_drain_cancelled_response_phase = try parseConnectionPhase(
            last_drain_cancelled_response_phase,
        ),
        .last_peer_reset_cancelled_work_phase = try parseConnectionPhase(
            last_peer_reset_cancelled_work_phase,
        ),
        .drain_requested_response_write = try parseCanonicalInt(
            u64,
            drain_requested_response_write,
        ),
        .last_drain_requested_response_write_phase = try parseConnectionPhase(
            last_drain_requested_response_write_phase,
        ),
        .drain_cancelled_response_write = try parseCanonicalInt(
            u64,
            drain_cancelled_response_write,
        ),
        .last_drain_cancelled_response_write_phase = try parseConnectionPhase(
            last_drain_cancelled_response_write_phase,
        ),
        .response_write_transport_failed = try parseCanonicalInt(
            u64,
            response_write_transport_failed,
        ),
        .last_response_write_transport_failed_phase = try parseConnectionPhase(
            last_response_write_transport_failed_phase,
        ),
        .response_outcome = try parseCanonicalInt(
            u8,
            response_outcome,
        ),
    };
}

fn parseTimedOut(line: []const u8) !TimeoutFrame {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return error.InvalidFrame;
    const generation = fields.next() orelse
        return error.InvalidFrame;
    const phase = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(u8, name, "TIMED_OUT"))
    {
        return error.InvalidFrame;
    }
    return .{
        .generation = try parseCanonicalInt(u64, generation),
        .phase = try parseConnectionPhase(phase),
    };
}

fn parseClosed(line: []const u8) !ClosedFrame {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return error.InvalidFrame;
    const generation = fields.next() orelse
        return error.InvalidFrame;
    const accepted = fields.next() orelse
        return error.InvalidFrame;
    const completed = fields.next() orelse
        return error.InvalidFrame;
    const failed = fields.next() orelse
        return error.InvalidFrame;
    const active = fields.next() orelse
        return error.InvalidFrame;
    const drain_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_phase = fields.next() orelse
        return error.InvalidFrame;
    const drain_cancelled_work = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_cancelled_work_phase =
        fields.next() orelse return error.InvalidFrame;
    const receive_timeout_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_receive_timeout_phase = fields.next() orelse
        return error.InvalidFrame;
    const full_request_timeout_signaled = fields.next() orelse
        return error.InvalidFrame;
    const last_full_request_timeout_signaled_phase =
        fields.next() orelse return error.InvalidFrame;
    const full_request_timeout_cancelled_work =
        fields.next() orelse return error.InvalidFrame;
    const last_full_request_timeout_cancelled_work_phase =
        fields.next() orelse return error.InvalidFrame;
    const full_request_timeout_cancelled_response =
        fields.next() orelse return error.InvalidFrame;
    const last_full_request_timeout_cancelled_response_phase =
        fields.next() orelse return error.InvalidFrame;
    const full_request_timeout_requested_response_write =
        fields.next() orelse return error.InvalidFrame;
    const last_full_request_timeout_requested_response_write_phase =
        fields.next() orelse return error.InvalidFrame;
    const full_request_timeout_cancelled_response_write =
        fields.next() orelse return error.InvalidFrame;
    const last_full_request_timeout_cancelled_response_write_phase =
        fields.next() orelse return error.InvalidFrame;
    const peer_reset = fields.next() orelse
        return error.InvalidFrame;
    const peer_reset_cancelled_work = fields.next() orelse
        return error.InvalidFrame;
    const last_peer_reset_phase = fields.next() orelse
        return error.InvalidFrame;
    const drain_cancelled_response = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_cancelled_response_phase =
        fields.next() orelse return error.InvalidFrame;
    const last_peer_reset_cancelled_work_phase =
        fields.next() orelse return error.InvalidFrame;
    const drain_requested_response_write = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_requested_response_write_phase =
        fields.next() orelse return error.InvalidFrame;
    const drain_cancelled_response_write = fields.next() orelse
        return error.InvalidFrame;
    const last_drain_cancelled_response_write_phase =
        fields.next() orelse return error.InvalidFrame;
    const response_write_transport_failed = fields.next() orelse
        return error.InvalidFrame;
    const last_response_write_transport_failed_phase =
        fields.next() orelse return error.InvalidFrame;
    const response_outcome = fields.next() orelse
        return error.InvalidFrame;
    const service_active = fields.next() orelse
        return error.InvalidFrame;
    const terminal_records = fields.next() orelse
        return error.InvalidFrame;
    const bank_zero = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(u8, name, "CLOSED"))
    {
        return error.InvalidFrame;
    }
    return .{
        .activity = .{
            .generation = try parseCanonicalInt(
                u64,
                generation,
            ),
            .accepted = try parseCanonicalInt(u64, accepted),
            .completed = try parseCanonicalInt(u64, completed),
            .failed = try parseCanonicalInt(u64, failed),
            .active = try parseCanonicalInt(u8, active),
            .drain_signaled = try parseCanonicalInt(u64, drain_signaled),
            .last_drain_phase = try parseConnectionPhase(last_drain_phase),
            .drain_cancelled_work = try parseCanonicalInt(
                u64,
                drain_cancelled_work,
            ),
            .last_drain_cancelled_work_phase = try parseConnectionPhase(
                last_drain_cancelled_work_phase,
            ),
            .receive_timeout_signaled = try parseCanonicalInt(
                u64,
                receive_timeout_signaled,
            ),
            .last_receive_timeout_phase = try parseConnectionPhase(
                last_receive_timeout_phase,
            ),
            .full_request_timeout_signaled = try parseCanonicalInt(
                u64,
                full_request_timeout_signaled,
            ),
            .last_full_request_timeout_signaled_phase = try parseConnectionPhase(
                last_full_request_timeout_signaled_phase,
            ),
            .full_request_timeout_cancelled_work = try parseCanonicalInt(
                u64,
                full_request_timeout_cancelled_work,
            ),
            .last_full_request_timeout_cancelled_work_phase = try parseConnectionPhase(
                last_full_request_timeout_cancelled_work_phase,
            ),
            .full_request_timeout_cancelled_response = try parseCanonicalInt(
                u64,
                full_request_timeout_cancelled_response,
            ),
            .last_full_request_timeout_cancelled_response_phase = try parseConnectionPhase(
                last_full_request_timeout_cancelled_response_phase,
            ),
            .full_request_timeout_requested_response_write = try parseCanonicalInt(
                u64,
                full_request_timeout_requested_response_write,
            ),
            .last_full_request_timeout_requested_response_write_phase = try parseConnectionPhase(
                last_full_request_timeout_requested_response_write_phase,
            ),
            .full_request_timeout_cancelled_response_write = try parseCanonicalInt(
                u64,
                full_request_timeout_cancelled_response_write,
            ),
            .last_full_request_timeout_cancelled_response_write_phase = try parseConnectionPhase(
                last_full_request_timeout_cancelled_response_write_phase,
            ),
            .peer_reset = try parseCanonicalInt(u64, peer_reset),
            .peer_reset_cancelled_work = try parseCanonicalInt(
                u64,
                peer_reset_cancelled_work,
            ),
            .last_peer_reset_phase = try parseConnectionPhase(
                last_peer_reset_phase,
            ),
            .drain_cancelled_response = try parseCanonicalInt(
                u64,
                drain_cancelled_response,
            ),
            .last_drain_cancelled_response_phase = try parseConnectionPhase(
                last_drain_cancelled_response_phase,
            ),
            .last_peer_reset_cancelled_work_phase = try parseConnectionPhase(
                last_peer_reset_cancelled_work_phase,
            ),
            .drain_requested_response_write = try parseCanonicalInt(
                u64,
                drain_requested_response_write,
            ),
            .last_drain_requested_response_write_phase = try parseConnectionPhase(
                last_drain_requested_response_write_phase,
            ),
            .drain_cancelled_response_write = try parseCanonicalInt(
                u64,
                drain_cancelled_response_write,
            ),
            .last_drain_cancelled_response_write_phase = try parseConnectionPhase(
                last_drain_cancelled_response_write_phase,
            ),
            .response_write_transport_failed = try parseCanonicalInt(
                u64,
                response_write_transport_failed,
            ),
            .last_response_write_transport_failed_phase = try parseConnectionPhase(
                last_response_write_transport_failed_phase,
            ),
            .response_outcome = try parseCanonicalInt(
                u8,
                response_outcome,
            ),
        },
        .service_active = try parseCanonicalInt(u32, service_active),
        .terminal_records = try parseCanonicalInt(u32, terminal_records),
        .bank_zero = try parseCanonicalInt(u8, bank_zero),
    };
}

fn parseConnectionPhase(
    text: []const u8,
) !server_api.ManagedConnectionPhaseV1 {
    return switch (try parseCanonicalInt(u8, text)) {
        0 => .none,
        1 => .receiving_head,
        2 => .request_head_received,
        3 => .request_received,
        4 => .request_admitted,
        5 => .response_ready,
        6 => .response_writing,
        7 => .response_written,
        8 => .queued,
        else => error.InvalidFrame,
    };
}

fn parseCanonicalInt(
    comptime T: type,
    text: []const u8,
) !T {
    if (text.len == 0 or
        (text.len > 1 and text[0] == '0'))
    {
        return error.InvalidFrame;
    }
    for (text) |byte| {
        if (!std.ascii.isDigit(byte))
            return error.InvalidFrame;
    }
    return std.fmt.parseInt(T, text, 10) catch
        return error.InvalidFrame;
}

fn validModelId(value: []const u8) bool {
    if (!std.mem.startsWith(
        u8,
        value,
        protocol.model_id_prefix,
    )) return false;
    for (value[protocol.model_id_prefix.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and
            (byte < 'a' or byte > 'f'))
        {
            return false;
        }
    }
    return true;
}

const Observation = struct {
    model_id: [protocol.model_id_bytes]u8,
    binding_sha256: protocol.Digest,
    completion: protocol.CompletionV1,
};

const LocalOracle = struct {
    model_id: [protocol.model_id_bytes]u8,
    binding_sha256: protocol.Digest,
    output_token: u32,
    content_byte: u8,
};

const NativeLoadClientObservation = struct {
    planned_ordinal: u32 = 0,
    flow_id: u32 = 0,
    request_sha256: protocol.Digest =
        [_]u8{0} ** 32,
    response_handle_sha256: protocol.Digest =
        [_]u8{0} ** 32,
    output_sha256: protocol.Digest =
        [_]u8{0} ** 32,
    terminal_sha256: protocol.Digest =
        [_]u8{0} ** 32,
    completion_sha256: protocol.Digest =
        [_]u8{0} ** 32,
    arrival_ns: u64 = 0,
    first_output_ns: u64 = 0,
    terminal_ns: u64 = 0,
    client_settlement_ns: u64 = 0,
    response_bytes: u32 = 0,
    output_token: u32 = 0,
    content_byte: u8 = 0,
};

const NativeLoadClientContext = struct {
    ready: ReadyFrame,
    oracle: LocalOracle,
    planned_ordinal: u32,
    flow_id: u32,
    start: *std.Thread.ResetEvent,
    observation: NativeLoadClientObservation = .{},
    thread_error: ?anyerror = null,

    fn run(self: *NativeLoadClientContext) void {
        self.execute() catch |err| {
            self.thread_error = err;
        };
    }

    fn execute(self: *NativeLoadClientContext) !void {
        var idempotency_storage: [protocol.idempotency_key_max_bytes]u8 =
            undefined;
        const idempotency_key = try std.fmt.bufPrint(
            &idempotency_storage,
            "native-load-{d}",
            .{self.planned_ordinal},
        );
        const tenant_key: u64 =
            10_000 + self.flow_id;
        const request: protocol.RequestV1 = .{
            .model_id = &self.ready.model_id,
            .tenant_key = tenant_key,
            .idempotency_key = idempotency_key,
            .prompt_utf8 = prompt,
            .max_new_tokens = 1,
        };
        const request_sha256 =
            try protocol.requestSha256V1(request);
        var body_storage: [protocol.request_body_max_bytes]u8 =
            undefined;
        const body = try protocol.encodeRequestV1(
            request,
            &body_storage,
        );
        var head_storage: [1024]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &head_storage,
            "POST {s} HTTP/1.1\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "{s}: {s}\r\n" ++
                "{s}: {d}\r\n" ++
                "Connection: close\r\n\r\n",
            .{
                protocol.completions_path_v1,
                loopback_host,
                self.ready.port,
                protocol.json_content_type,
                body.len,
                protocol.idempotency_header,
                idempotency_key,
                protocol.tenant_header,
                tenant_key,
            },
        );

        self.start.wait();
        const arrival_ns = try nativeLoadMonotonicNs();
        const address = try std.net.Address.parseIp(
            loopback_host,
            self.ready.port,
        );
        const peer =
            try std.net.tcpConnectToAddress(address);
        defer peer.close();
        try peer.writeAll(head);
        try peer.writeAll(body);

        var response_storage: [
            protocol.header_max_bytes +
                protocol.response_body_max_bytes
        ]u8 =
            undefined;
        var used: usize = 0;
        var first_output_ns: u64 = 0;
        while (used < response_storage.len) {
            const read_count =
                try peer.read(response_storage[used..]);
            if (read_count == 0) break;
            if (first_output_ns == 0)
                first_output_ns =
                    try nativeLoadMonotonicNs();
            used += read_count;
        }
        if (used == 0 or used == response_storage.len or
            first_output_ns == 0)
        {
            return error.InvalidNativeLoadResponseSize;
        }
        const response = response_storage[0..used];
        const response_body =
            try parseNativeLoadResponseBody(response);
        var parser_storage: [protocol.parser_workspace_bytes]u8 =
            undefined;
        var parser =
            std.heap.FixedBufferAllocator.init(
                &parser_storage,
            );
        const completion =
            try protocol.decodeCompletionV1(
                parser.allocator(),
                response_body,
            );
        const response_handle_sha256 = try parseDigestHex(
            completion.id[protocol.completion_id_prefix.len..],
        );
        if (!std.mem.eql(
            u8,
            &completion.request_sha256,
            &request_sha256,
        ) or !std.mem.eql(
            u8,
            &completion.model_id,
            &self.oracle.model_id,
        ) or completion.prompt_tokens != prompt.len or
            completion.output_count != 1 or
            completion.output_tokens[0] !=
                self.oracle.output_token or
            completion.content_bytes != 1 or
            completion.content[0] !=
                self.oracle.content_byte)
        {
            return error.InvalidNativeLoadCompletion;
        }
        const terminal_ns = try nativeLoadMonotonicNs();
        self.observation = .{
            .planned_ordinal = self.planned_ordinal,
            .flow_id = self.flow_id,
            .request_sha256 = request_sha256,
            .response_handle_sha256 = response_handle_sha256,
            .output_sha256 = completion.output_sha256,
            .terminal_sha256 = completion.terminal_evidence_sha256,
            .completion_sha256 = completion.response_sha256,
            .arrival_ns = arrival_ns,
            .first_output_ns = first_output_ns,
            .terminal_ns = terminal_ns,
            .client_settlement_ns = try nativeLoadMonotonicNs(),
            .response_bytes = @intCast(used),
            .output_token = completion.output_tokens[0],
            .content_byte = completion.content[0],
        };
    }
};

fn parseNativeLoadResponseBody(
    response: []const u8,
) ![]const u8 {
    const head_end = std.mem.indexOf(
        u8,
        response,
        "\r\n\r\n",
    ) orelse return error.InvalidNativeLoadResponseHead;
    const head = response[0..head_end];
    var lines = std.mem.splitSequence(
        u8,
        head,
        "\r\n",
    );
    const status = lines.next() orelse
        return error.InvalidNativeLoadResponseHead;
    if (!std.mem.eql(
        u8,
        status,
        "HTTP/1.1 200 OK",
    )) return error.InvalidNativeLoadStatus;
    var content_length: ?usize = null;
    var content_type = false;
    var connection_close = false;
    while (lines.next()) |line| {
        const separator =
            std.mem.indexOfScalar(u8, line, ':') orelse
            return error.InvalidNativeLoadResponseHeader;
        const name = line[0..separator];
        const value = std.mem.trim(
            u8,
            line[separator + 1 ..],
            " \t",
        );
        if (std.ascii.eqlIgnoreCase(
            name,
            "content-length",
        )) {
            if (content_length != null)
                return error.DuplicateNativeLoadContentLength;
            content_length = try parseCanonicalInt(
                usize,
                value,
            );
        } else if (std.ascii.eqlIgnoreCase(
            name,
            "content-type",
        )) {
            if (content_type or !std.mem.eql(
                u8,
                value,
                protocol.json_content_type,
            )) return error.InvalidNativeLoadContentType;
            content_type = true;
        } else if (std.ascii.eqlIgnoreCase(
            name,
            "connection",
        )) {
            if (connection_close or
                !std.ascii.eqlIgnoreCase(
                    value,
                    "close",
                ))
            {
                return error.InvalidNativeLoadConnection;
            }
            connection_close = true;
        } else if (forbiddenNativeLoadResponseHeader(
            name,
        )) {
            return error.UnsupportedNativeLoadEncoding;
        }
    }
    const body_start = head_end + 4;
    const length = content_length orelse
        return error.MissingNativeLoadContentLength;
    if (!content_type or !connection_close or length == 0 or
        length > protocol.response_body_max_bytes or
        body_start + length != response.len)
    {
        return error.InvalidNativeLoadResponseLength;
    }
    return response[body_start..];
}

fn forbiddenNativeLoadResponseHeader(
    name: []const u8,
) bool {
    return std.ascii.eqlIgnoreCase(
        name,
        "transfer-encoding",
    ) or std.ascii.eqlIgnoreCase(
        name,
        "content-encoding",
    ) or std.ascii.eqlIgnoreCase(
        name,
        "trailer",
    ) or std.ascii.eqlIgnoreCase(
        name,
        "upgrade",
    );
}

comptime {
    if (!forbiddenNativeLoadResponseHeader(
        "Transfer-Encoding",
    ) or !forbiddenNativeLoadResponseHeader(
        "Content-Encoding",
    ) or !forbiddenNativeLoadResponseHeader(
        "Trailer",
    ) or !forbiddenNativeLoadResponseHeader(
        "Upgrade",
    ) or forbiddenNativeLoadResponseHeader(
        "Content-Type",
    )) {
        @compileError(
            "native-load forbidden response header oracle drifted",
        );
    }
}

fn makeLocalOracle(
    allocator: std.mem.Allocator,
    fixture: *const Fixture,
) !LocalOracle {
    const model_file = try engine.bounded_file_input.openRegularV1(
        fixture.prepared_path,
    );
    var model =
        try engine.loader.loadPreparedOwnedFileWithOptionsV1(
            allocator,
            model_file,
            .{
                .expected_source_fingerprint = fixture.bundle.package.model_content_sha256,
                .mlp_layout = .separate_required,
            },
        );
    defer model.deinit();
    const binding = try unary.bindModelV1(
        &model,
        fixture.bundle,
        fixture_license.len,
        engine.core.model_contract.sha256(fixture_license),
    );
    const tokenizer_manifest =
        try engine.tokenizer.makeUtf8ByteManifestV1(
            @intCast(model.config.vocab_size),
            engine.tokenizer.utf8_byte_max_input_bytes,
        );
    var tokenized =
        try engine.tokenizer.tokenizeUtf8BytesV1(
            allocator,
            tokenizer_manifest,
            prompt,
        );
    defer tokenized.deinit();
    const output = try engine.generate.generate(
        allocator,
        model,
        tokenized.tokens,
        (engine.prepared_text_session.OptionsV1{
            .max_new_tokens = 1,
        }).generateOptions(),
    );
    defer allocator.free(output);
    if (output.len != 1)
        return error.InvalidOracle;
    const content_byte = std.math.cast(u8, output[0]) orelse
        return error.InvalidOracle;
    if (!std.unicode.utf8ValidateSlice(&.{content_byte}))
        return error.InvalidOracle;

    return .{
        .model_id = protocol.modelIdV1(binding.binding_sha256),
        .binding_sha256 = binding.binding_sha256,
        .output_token = output[0],
        .content_byte = content_byte,
    };
}

fn parseDigestHex(
    text: []const u8,
) !protocol.Digest {
    if (text.len != 64)
        return error.InvalidDigestHex;
    var result: protocol.Digest = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch
        return error.InvalidDigestHex;
    return result;
}

fn parseNativeLoadWave(
    line: []const u8,
    expected: usize,
) !void {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse
        return error.InvalidFrame;
    const count = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(
            u8,
            name,
            "NATIVE-LOAD-WAVE",
        ) or try parseCanonicalInt(
        usize,
        count,
    ) != expected) {
        return error.InvalidNativeLoadWave;
    }
}

fn parseNativeLoadServerRecord(
    line: []const u8,
    expected_index: usize,
) !NativeLoadServerRecord {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse
        return error.InvalidFrame;
    const index = fields.next() orelse
        return error.InvalidFrame;
    const request = fields.next() orelse
        return error.InvalidFrame;
    const handle = fields.next() orelse
        return error.InvalidFrame;
    const work_sequence = fields.next() orelse
        return error.InvalidFrame;
    const process_generation = fields.next() orelse
        return error.InvalidFrame;
    const connection_sequence = fields.next() orelse
        return error.InvalidFrame;
    const slot_index = fields.next() orelse
        return error.InvalidFrame;
    const slot_generation = fields.next() orelse
        return error.InvalidFrame;
    const worker_index = fields.next() orelse
        return error.InvalidFrame;
    const enqueue_ordinal = fields.next() orelse
        return error.InvalidFrame;
    const enqueue_ns = fields.next() orelse
        return error.InvalidFrame;
    const dispatch_ordinal = fields.next() orelse
        return error.InvalidFrame;
    const dispatch_ns = fields.next() orelse
        return error.InvalidFrame;
    const published_ns = fields.next() orelse
        return error.InvalidFrame;
    const retired_ordinal = fields.next() orelse
        return error.InvalidFrame;
    const retired_ns = fields.next() orelse
        return error.InvalidFrame;
    if (fields.next() != null or
        !std.mem.eql(
            u8,
            name,
            "NATIVE-LOAD-RECORD",
        ) or try parseCanonicalInt(
        usize,
        index,
    ) != expected_index) {
        return error.InvalidNativeLoadRecordFrame;
    }
    const result: NativeLoadServerRecord = .{
        .request_sha256 = try parseDigestHex(request),
        .handle_sha256 = try parseDigestHex(handle),
        .work_sequence = try parseCanonicalInt(
            u64,
            work_sequence,
        ),
        .process_generation = try parseCanonicalInt(
            u64,
            process_generation,
        ),
        .connection_sequence = try parseCanonicalInt(
            u64,
            connection_sequence,
        ),
        .slot_index = try parseCanonicalInt(
            u8,
            slot_index,
        ),
        .slot_generation = try parseCanonicalInt(
            u64,
            slot_generation,
        ),
        .worker_index = try parseCanonicalInt(
            u8,
            worker_index,
        ),
        .enqueue_ordinal = try parseCanonicalInt(
            u64,
            enqueue_ordinal,
        ),
        .enqueue_ns = try parseCanonicalInt(
            u64,
            enqueue_ns,
        ),
        .dispatch_ordinal = try parseCanonicalInt(
            u64,
            dispatch_ordinal,
        ),
        .dispatch_ns = try parseCanonicalInt(
            u64,
            dispatch_ns,
        ),
        .published_ns = try parseCanonicalInt(
            u64,
            published_ns,
        ),
        .retired_ordinal = try parseCanonicalInt(
            u64,
            retired_ordinal,
        ),
        .retired_ns = try parseCanonicalInt(
            u64,
            retired_ns,
        ),
    };
    if (result.work_sequence == 0 or
        result.process_generation !=
            generation_native_load or
        result.connection_sequence == 0 or
        result.slot_index >=
            native_load_worker_count +
                native_load_pending_capacity or
        result.slot_generation == 0 or
        result.worker_index >=
            native_load_worker_count or
        result.enqueue_ordinal == 0 or
        result.dispatch_ordinal == 0 or
        result.retired_ordinal == 0 or
        result.enqueue_ns == 0 or
        result.dispatch_ns == 0 or
        result.published_ns == 0 or
        result.retired_ns == 0 or
        result.enqueue_ordinal >=
            result.dispatch_ordinal or
        result.dispatch_ordinal >=
            result.retired_ordinal or
        result.enqueue_ns > result.dispatch_ns or
        result.dispatch_ns > result.published_ns or
        result.published_ns > result.retired_ns)
    {
        return error.InvalidNativeLoadServerRecord;
    }
    return result;
}

fn parseNativeLoadClosure(
    line: []const u8,
) ![native_load_closure_u64_count]u64 {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse
        return error.InvalidFrame;
    if (!std.mem.eql(
        u8,
        name,
        "NATIVE-LOAD-CLOSED",
    )) return error.InvalidNativeLoadClosureFrame;
    var result: [native_load_closure_u64_count]u64 =
        undefined;
    for (&result) |*value| {
        const text = fields.next() orelse
            return error.InvalidNativeLoadClosureFrame;
        value.* = try parseCanonicalInt(u64, text);
    }
    if (fields.next() != null)
        return error.InvalidNativeLoadClosureFrame;
    return result;
}

fn hashNativeLoadU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashNativeLoadU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn finishNativeLoadHash(
    hash: *std.crypto.hash.sha2.Sha256,
) protocol.Digest {
    var result: protocol.Digest = undefined;
    hash.final(&result);
    return result;
}

fn nativeLoadPinRoot(
    server: NativeLoadServerRecord,
) protocol.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-f1-native-unary-load-pin-v1\x00",
    );
    hashNativeLoadU64(
        &hash,
        server.process_generation,
    );
    hashNativeLoadU64(
        &hash,
        server.connection_sequence,
    );
    hash.update(&.{server.slot_index});
    hashNativeLoadU64(
        &hash,
        server.slot_generation,
    );
    return finishNativeLoadHash(&hash);
}

fn nativeLoadDispatchRoot(
    server: NativeLoadServerRecord,
    pin_sha256: protocol.Digest,
) protocol.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-f1-native-unary-load-dispatch-v1\x00",
    );
    hash.update(&pin_sha256);
    hashNativeLoadU64(&hash, server.enqueue_ordinal);
    hashNativeLoadU64(&hash, server.enqueue_ns);
    hashNativeLoadU64(&hash, server.dispatch_ordinal);
    hashNativeLoadU64(&hash, server.dispatch_ns);
    hash.update(&.{server.worker_index});
    return finishNativeLoadHash(&hash);
}

fn nativeLoadSubmissionRoot(
    client: NativeLoadClientObservation,
    server: NativeLoadServerRecord,
    pin_sha256: protocol.Digest,
) protocol.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-f1-native-unary-load-submission-v1\x00",
    );
    hash.update(&client.request_sha256);
    hash.update(&server.handle_sha256);
    hash.update(&pin_sha256);
    hashNativeLoadU64(&hash, server.work_sequence);
    hashNativeLoadU64(&hash, server.published_ns);
    return finishNativeLoadHash(&hash);
}

fn nativeLoadOracleRoot(
    output_token: u32,
    content_byte: u8,
) protocol.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-f1-native-unary-load-oracle-v1\x00",
    );
    hashNativeLoadU32(&hash, output_token);
    hash.update(&.{content_byte});
    return finishNativeLoadHash(&hash);
}

fn nativeLoadUnavailableReason(
    label: []const u8,
    ordinal: u32,
) protocol.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-f1-native-unary-load-unavailable-v1\x00",
    );
    hashNativeLoadU32(&hash, @intCast(label.len));
    hash.update(label);
    hashNativeLoadU32(&hash, ordinal);
    return finishNativeLoadHash(&hash);
}

fn nativeLoadHostClockIdentity() protocol.Digest {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => native_report.digestV1(
            "darwin-clock-uptime-raw/v1",
        ),
        .linux => native_report.digestV1(
            "linux-clock-monotonic-raw/v1",
        ),
        else => native_report.digestV1(
            "posix-clock-monotonic/v1",
        ),
    };
}

const NativeLoadJoinedRecord = struct {
    client: NativeLoadClientObservation,
    server: NativeLoadServerRecord,
};

const NativeLoadSequencePoint = struct {
    ns: u64,
    record_index: u16,
    event_index: u8,
};

fn nativeLoadJoinedLessThan(
    _: void,
    left: NativeLoadJoinedRecord,
    right: NativeLoadJoinedRecord,
) bool {
    if (left.client.arrival_ns !=
        right.client.arrival_ns)
    {
        return left.client.arrival_ns <
            right.client.arrival_ns;
    }
    return left.client.planned_ordinal <
        right.client.planned_ordinal;
}

fn nativeLoadSequenceLessThan(
    _: void,
    left: NativeLoadSequencePoint,
    right: NativeLoadSequencePoint,
) bool {
    if (left.ns != right.ns) return left.ns < right.ns;
    if (left.event_index != right.event_index)
        return left.event_index < right.event_index;
    return left.record_index < right.record_index;
}

fn nativeLoadTimestamps(
    joined: NativeLoadJoinedRecord,
) ![native_report.event_count]u64 {
    const settlement_ns = @max(
        joined.client.client_settlement_ns,
        joined.server.retired_ns,
    );
    const result =
        [native_report.event_count]u64{
            joined.client.arrival_ns,
            joined.server.enqueue_ns,
            joined.server.dispatch_ns,
            joined.server.published_ns,
            joined.client.first_output_ns,
            joined.client.terminal_ns,
            settlement_ns,
        };
    for (result[1..], result[0 .. result.len - 1]) |
        current,
        previous,
    | {
        if (previous > current)
            return error.InvalidNativeLoadJoinedTimeline;
    }
    return result;
}

fn makeNativeLoadHostEvents(
    timestamps: [native_report.event_count]u64,
    sequences: [native_report.event_count]u64,
) native_report.HostEventsV1 {
    return .{
        .presence_mask = native_report.event_presence_all,
        .arrival = .{
            .ns = timestamps[0],
            .sequence = sequences[0],
        },
        .admission = .{
            .ns = timestamps[1],
            .sequence = sequences[1],
        },
        .first_service = .{
            .ns = timestamps[2],
            .sequence = sequences[2],
        },
        .submit_return = .{
            .ns = timestamps[3],
            .sequence = sequences[3],
        },
        .first_output = .{
            .ns = timestamps[4],
            .sequence = sequences[4],
        },
        .terminal = .{
            .ns = timestamps[5],
            .sequence = sequences[5],
        },
        .settlement = .{
            .ns = timestamps[6],
            .sequence = sequences[6],
        },
    };
}

fn makeNativeLoadScenario(
    fixture: *const Fixture,
    challenge_sha256: protocol.Digest,
    build_sha256: protocol.Digest,
    machine_sha256: protocol.Digest,
) !native_report.ScenarioV1 {
    return native_report.makeScenarioV1(.{
        .mode = .closed,
        .evidence = .production_native,
        .warmup_count = native_load_warmup_count,
        .measured_count = native_load_measured_count,
        .max_in_flight = native_load_flow_count,
        .queue_count = native_load_worker_count +
            native_load_pending_capacity,
        .flow_count = native_load_flow_count,
        .workload_sha256 = native_report.digestV1(
            "glacier-f1-native-unary-load-workload/v1",
        ),
        .profile_sha256 = native_report.digestV1(
            "glacier-f1-native-unary-load-profile/" ++ "8-warmup-64-measured-8-flow-2-worker/v1",
        ),
        .artifact_sha256 = fixture.bundle.package.model_content_sha256,
        .build_sha256 = build_sha256,
        .machine_sha256 = machine_sha256,
        .backend_sha256 = native_report.digestV1(
            "glacier-prepared-text-unary-cpu-backend/v1",
        ),
        .device_sha256 = native_report.digestV1(
            "host-cpu-device-physical-metrics-unavailable/v1",
        ),
        .placement_sha256 = native_report.digestV1(
            "managed-concurrent-loopback-2-worker-8-pending/v1",
        ),
        .host_source_sha256 = native_report.digestV1(
            "f1-native-load-parent-child-observers/v1",
        ),
        .host_clock_sha256 = nativeLoadHostClockIdentity(),
        .device_source_sha256 = native_report.digestV1(
            "f1-native-load-device-observer-unsupported/v1",
        ),
        .device_clock_sha256 = native_report.digestV1(
            "f1-native-load-device-clock-unsupported/v1",
        ),
        .challenge_sha256 = challenge_sha256,
    });
}

fn buildNativeLoadInnerReport(
    fixture: *const Fixture,
    joined: *[native_load_record_count]NativeLoadJoinedRecord,
    challenge_sha256: protocol.Digest,
    build_sha256: protocol.Digest,
    machine_sha256: protocol.Digest,
    record_storage: *[native_load_record_count]native_report.RecordV1,
    encoded_storage: *[native_load_inner_bytes]u8,
) ![]const u8 {
    std.mem.sort(
        NativeLoadJoinedRecord,
        joined,
        {},
        nativeLoadJoinedLessThan,
    );
    for (joined[0..native_load_warmup_count]) |record| {
        if (record.client.planned_ordinal >=
            native_load_warmup_count)
        {
            return error.InvalidNativeLoadWarmupOrder;
        }
    }
    for (joined[native_load_warmup_count..]) |record| {
        if (record.client.planned_ordinal <
            native_load_warmup_count)
        {
            return error.InvalidNativeLoadMeasuredOrder;
        }
    }

    var timestamps: [native_load_record_count][native_report.event_count]u64 =
        undefined;
    var sequence_points: [
        native_load_record_count *
            native_report.event_count
    ]NativeLoadSequencePoint =
        undefined;
    var point_count: usize = 0;
    for (joined, 0..) |record, record_index| {
        timestamps[record_index] =
            try nativeLoadTimestamps(record);
        for (
            timestamps[record_index],
            0..,
        ) |ns, event_index| {
            sequence_points[point_count] = .{
                .ns = ns,
                .record_index = @intCast(record_index),
                .event_index = @intCast(event_index),
            };
            point_count += 1;
        }
    }
    std.mem.sort(
        NativeLoadSequencePoint,
        &sequence_points,
        {},
        nativeLoadSequenceLessThan,
    );
    var sequences: [native_load_record_count][native_report.event_count]u64 =
        [_][native_report.event_count]u64{
            [_]u64{0} ** native_report.event_count,
        } ** native_load_record_count;
    for (sequence_points, 0..) |point, index| {
        sequences[point.record_index][point.event_index] =
            index + 1;
    }

    const scenario = try makeNativeLoadScenario(
        fixture,
        challenge_sha256,
        build_sha256,
        machine_sha256,
    );
    for (joined, 0..) |record, index| {
        if (!std.mem.eql(
            u8,
            &record.client.request_sha256,
            &record.server.request_sha256,
        )) return error.NativeLoadRequestCorrelationMismatch;
        const pin_sha256 =
            nativeLoadPinRoot(record.server);
        const ordinal: u32 = @intCast(index);
        record_storage[index] =
            try native_report.makeRecordV1(.{
                .ordinal = ordinal,
                .cohort = if (index <
                    native_load_warmup_count)
                    .warmup
                else
                    .measured,
                .outcome = .completed,
                .correctness = .correct,
                .fallback = false,
                .flow_id = record.client.flow_id,
                .work_units = 1,
                .adapter_queue_slot = record.server.slot_index,
                .host = makeNativeLoadHostEvents(
                    timestamps[index],
                    sequences[index],
                ),
                .roots = .{
                    .request_sha256 = record.client.request_sha256,
                    .ticket_sha256 = record.server.handle_sha256,
                    .pin_sha256 = pin_sha256,
                    .dispatch_sha256 = nativeLoadDispatchRoot(
                        record.server,
                        pin_sha256,
                    ),
                    .submission_sha256 = nativeLoadSubmissionRoot(
                        record.client,
                        record.server,
                        pin_sha256,
                    ),
                    .output_sha256 = record.client.output_sha256,
                    .oracle_sha256 = nativeLoadOracleRoot(
                        record.client.output_token,
                        record.client.content_byte,
                    ),
                    .terminal_sha256 = record.client.terminal_sha256,
                    .completion_sha256 = record.client.completion_sha256,
                },
                .maximum_abs_error_f64_bits = @bitCast(@as(f64, 0)),
                .device_timing = .{
                    .availability = .unsupported,
                    .source_sha256 = scenario.device_source_sha256,
                    .clock_sha256 = scenario.device_clock_sha256,
                    .reason_sha256 = nativeLoadUnavailableReason(
                        "device timing",
                        ordinal,
                    ),
                },
                .allocated_context = .{
                    .availability = .unsupported,
                    .source_sha256 = scenario.device_source_sha256,
                    .reason_sha256 = nativeLoadUnavailableReason(
                        "allocated context",
                        ordinal,
                    ),
                },
                .logical = .{
                    .bank_acquisitions = 1,
                    .bank_completions = 1,
                },
            });
    }
    const closure = try native_report.makeClosureV1(
        native_load_record_count,
        native_load_record_count,
    );
    const report = try native_report.sealV1(
        scenario,
        record_storage,
        closure,
    );
    return native_report.encodeV1(
        report,
        encoded_storage,
    );
}

fn nativeLoadDomainDigest(
    domain: []const u8,
    bytes: []const u8,
) protocol.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(bytes);
    return finishNativeLoadHash(&hash);
}

const NativeLoadOuterWriter = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(
        self: *NativeLoadOuterWriter,
        value: []const u8,
    ) !void {
        const end = std.math.add(
            usize,
            self.position,
            value.len,
        ) catch return error.NativeLoadOuterOverflow;
        if (end > self.bytes.len)
            return error.NativeLoadOuterOverflow;
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeU8(
        self: *NativeLoadOuterWriter,
        value: u8,
    ) !void {
        try self.writeBytes(&.{value});
    }

    fn writeU32(
        self: *NativeLoadOuterWriter,
        value: u32,
    ) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeU64(
        self: *NativeLoadOuterWriter,
        value: u64,
    ) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeDigest(
        self: *NativeLoadOuterWriter,
        value: protocol.Digest,
    ) !void {
        try self.writeBytes(&value);
    }

    fn writeReserved(
        self: *NativeLoadOuterWriter,
        count: usize,
    ) !void {
        if (count > 16)
            return error.NativeLoadOuterOverflow;
        try self.writeBytes(
            ([_]u8{0} ** 16)[0..count],
        );
    }
};

fn validateNativeLoadClosureValues(
    values: *const [native_load_closure_u64_count]u64,
) !void {
    if (values[0] != native_load_record_count or
        values[1] != native_load_record_count or
        values[2] != 0 or
        values[3] != native_load_record_count or
        values[4] != native_load_record_count or
        values[5] == 0 or
        values[5] > native_load_pending_capacity or
        values[6] == 0 or
        values[6] > native_load_worker_count or
        values[7] != values[8] or
        values[9] != 0 or values[10] != 0 or
        values[11] != 0 or values[12] != 0 or
        values[13] != 0 or values[14] != 0 or
        values[15] != 0 or values[16] != 0 or
        values[17] != 0 or
        values[18] != native_load_record_count or
        values[19] != native_load_record_count or
        values[20] != 0 or values[21] != 0 or
        values[22] != 0 or values[23] != 1 or
        values[24] != 1 or values[25] != 1 or
        values[26] != 0 or values[27] == 0)
    {
        return error.InvalidNativeLoadClosure;
    }
}

fn encodeNativeLoadOuter(
    joined: *const [native_load_record_count]NativeLoadJoinedRecord,
    closure: *const [native_load_closure_u64_count]u64,
    inner: []const u8,
    output: *[native_load_outer_bytes]u8,
) ![]const u8 {
    if (inner.len != native_load_inner_bytes)
        return error.InvalidNativeLoadInnerLength;
    try validateNativeLoadClosureValues(closure);
    @memset(output, 0);
    var writer: NativeLoadOuterWriter = .{
        .bytes = output,
    };
    try writer.writeBytes(&native_load_outer_magic);
    try writer.writeU64(native_load_outer_abi);
    try writer.writeU64(native_load_outer_bytes);
    try writer.writeU32(native_load_record_count);
    try writer.writeU32(native_load_sidecar_bytes);
    try writer.writeU32(native_load_closure_bytes);
    try writer.writeU32(native_load_inner_bytes);
    if (writer.position !=
        native_load_outer_header_bytes)
    {
        return error.InvalidNativeLoadOuterHeader;
    }

    const body_start = writer.position;
    for (joined, 0..) |record, index| {
        const sidecar_start = writer.position;
        try writer.writeU32(@intCast(index));
        try writer.writeU32(
            record.client.response_bytes,
        );
        try writer.writeU64(
            record.server.enqueue_ordinal,
        );
        try writer.writeU64(
            record.server.dispatch_ordinal,
        );
        try writer.writeU64(
            record.server.retired_ordinal,
        );
        try writer.writeU64(record.server.enqueue_ns);
        try writer.writeU64(record.server.dispatch_ns);
        try writer.writeU64(
            record.server.published_ns,
        );
        try writer.writeU64(record.server.retired_ns);
        try writer.writeU64(
            record.server.work_sequence,
        );
        try writer.writeU64(
            record.server.process_generation,
        );
        try writer.writeU64(
            record.server.connection_sequence,
        );
        try writer.writeU64(
            record.server.slot_generation,
        );
        try writer.writeU8(record.server.slot_index);
        try writer.writeU8(
            record.server.worker_index,
        );
        try writer.writeU8(record.client.content_byte);
        try writer.writeReserved(1);
        try writer.writeU32(record.client.output_token);
        try writer.writeDigest(
            record.client.request_sha256,
        );
        try writer.writeDigest(
            record.client.response_handle_sha256,
        );
        try writer.writeDigest(
            record.server.handle_sha256,
        );
        try writer.writeDigest(
            record.client.output_sha256,
        );
        try writer.writeDigest(
            record.client.terminal_sha256,
        );
        try writer.writeDigest(
            record.client.completion_sha256,
        );
        if (writer.position - sidecar_start !=
            native_load_sidecar_bytes)
        {
            return error.InvalidNativeLoadSidecarLayout;
        }
    }
    for (closure) |value| try writer.writeU64(value);
    try writer.writeBytes(inner);
    const body_end = writer.position;
    if (body_end + native_load_outer_digest_bytes !=
        output.len)
    {
        return error.InvalidNativeLoadOuterLayout;
    }
    try writer.writeDigest(nativeLoadDomainDigest(
        native_load_outer_body_domain,
        output[body_start..body_end],
    ));
    try writer.writeDigest(nativeLoadDomainDigest(
        native_load_outer_footer_domain,
        output[0..writer.position],
    ));
    if (writer.position != output.len)
        return error.InvalidNativeLoadOuterLayout;
    return output;
}

fn runNativeLoadSupervisor(
    allocator: std.mem.Allocator,
    challenge_hex: []const u8,
    build_hex: []const u8,
    machine_hex: []const u8,
) !void {
    if (comptime builtin.os.tag == .windows or
        builtin.os.tag == .wasi or builtin.os.tag == .uefi)
    {
        return error.NativeLoadUnsupported;
    }
    _ = try nativeLoadMonotonicNs();
    const challenge_sha256 =
        try parseDigestHex(challenge_hex);
    const build_sha256 =
        try parseDigestHex(build_hex);
    const machine_sha256 =
        try parseDigestHex(machine_hex);

    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const executable =
        try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable);
    const oracle =
        try makeLocalOracle(allocator, &fixture);
    var child = try spawnWorker(
        allocator,
        executable,
        &fixture,
        generation_native_load,
        .native_load,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);

    var frame_storage: [frame_max_bytes]u8 = undefined;
    const ready = try parseReady(
        try readFrame(child.stdout.?, &frame_storage),
    );
    if (ready.generation != generation_native_load or
        !std.mem.eql(
            u8,
            &ready.model_id,
            &oracle.model_id,
        ))
    {
        return error.InvalidNativeLoadReady;
    }

    var client_observations: [native_load_record_count]NativeLoadClientObservation =
        undefined;
    for (0..native_load_wave_count) |wave| {
        var start: std.Thread.ResetEvent = .{};
        var contexts: [native_load_flow_count]NativeLoadClientContext =
            undefined;
        var threads: [native_load_flow_count]std.Thread =
            undefined;
        var spawned: usize = 0;
        errdefer {
            start.set();
            for (threads[0..spawned]) |thread|
                thread.join();
        }
        for (0..native_load_flow_count) |flow| {
            const planned =
                wave * native_load_flow_count + flow;
            contexts[flow] = .{
                .ready = ready,
                .oracle = oracle,
                .planned_ordinal = @intCast(planned),
                .flow_id = @intCast(flow),
                .start = &start,
            };
            threads[flow] = try std.Thread.spawn(
                .{},
                NativeLoadClientContext.run,
                .{&contexts[flow]},
            );
            spawned += 1;
        }
        start.set();
        for (threads) |thread| thread.join();
        spawned = 0;
        for (contexts, 0..) |context, flow| {
            if (context.thread_error) |err| return err;
            const planned =
                wave * native_load_flow_count + flow;
            client_observations[planned] =
                context.observation;
        }

        const expected =
            (wave + 1) * native_load_flow_count;
        var command_storage: [64]u8 = undefined;
        const command = try std.fmt.bufPrint(
            &command_storage,
            "native-load-wave {d}\n",
            .{expected},
        );
        try child.stdin.?.writeAll(command);
        try parseNativeLoadWave(
            try readFrame(
                child.stdout.?,
                &frame_storage,
            ),
            expected,
        );
    }
    try child.stdin.?.writeAll(
        native_load_drain_command,
    );
    child.stdin.?.close();
    child.stdin = null;

    var server_records: [native_load_record_count]NativeLoadServerRecord =
        undefined;
    for (&server_records, 0..) |*record, index| {
        record.* = try parseNativeLoadServerRecord(
            try readFrame(
                child.stdout.?,
                &frame_storage,
            ),
            index,
        );
    }
    const closure = try parseNativeLoadClosure(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try requireWorkerEof(child.stdout.?);
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| if (code != 0)
            return error.NativeLoadWorkerFailed,
        else => return error.UnexpectedWorkerTermination,
    }

    var joined: [native_load_record_count]NativeLoadJoinedRecord =
        undefined;
    var matched =
        [_]bool{false} ** native_load_record_count;
    for (client_observations, 0..) |
        client,
        client_index,
    | {
        var found: ?usize = null;
        for (server_records, 0..) |
            server,
            server_index,
        | {
            if (!std.mem.eql(
                u8,
                &client.request_sha256,
                &server.request_sha256,
            )) continue;
            if (found != null or matched[server_index])
                return error.DuplicateNativeLoadCorrelation;
            found = server_index;
        }
        const server_index = found orelse
            return error.MissingNativeLoadCorrelation;
        if (!std.mem.eql(
            u8,
            &client.response_handle_sha256,
            &server_records[server_index].handle_sha256,
        )) return error.NativeLoadResponseHandleMismatch;
        matched[server_index] = true;
        joined[client_index] = .{
            .client = client,
            .server = server_records[server_index],
        };
    }
    for (matched) |present| {
        if (!present)
            return error.MissingNativeLoadCorrelation;
    }

    var report_records: [native_load_record_count]native_report.RecordV1 =
        undefined;
    var inner_storage: [native_load_inner_bytes]u8 = undefined;
    const inner = try buildNativeLoadInnerReport(
        &fixture,
        &joined,
        challenge_sha256,
        build_sha256,
        machine_sha256,
        &report_records,
        &inner_storage,
    );
    var outer_storage: [native_load_outer_bytes]u8 = undefined;
    const outer = try encodeNativeLoadOuter(
        &joined,
        &closure,
        inner,
        &outer_storage,
    );
    var stdout_storage: [8192]u8 = undefined;
    var stdout =
        std.fs.File.stdout().writer(&stdout_storage);
    try stdout.interface.writeAll(outer);
    try stdout.interface.flush();
}

fn runSupervisor(allocator: std.mem.Allocator) !void {
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const executable = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable);
    const oracle = try makeLocalOracle(allocator, &fixture);

    try proveInvalidStartup(
        allocator,
        executable,
        &fixture,
    );
    const first = try exerciseWorker(
        allocator,
        executable,
        &fixture,
        generation_a,
        "server-process-key-a",
        true,
    );
    try validateObservation(first, oracle);
    try exercisePartialDrain(
        allocator,
        executable,
        &fixture,
        generation_partial_head,
        .head,
        &oracle.model_id,
    );
    try exercisePartialDrain(
        allocator,
        executable,
        &fixture,
        generation_partial_body,
        .body,
        &oracle.model_id,
    );
    try exerciseReceiveTimeout(
        allocator,
        executable,
        &fixture,
        generation_timeout_head,
        .head,
        &oracle.model_id,
    );
    try exerciseReceiveTimeout(
        allocator,
        executable,
        &fixture,
        generation_timeout_body,
        .body,
        &oracle.model_id,
    );
    try exerciseAdmittedWorkDrain(
        allocator,
        executable,
        &fixture,
        generation_drain_work,
        &oracle.model_id,
    );
    try exerciseTerminalWorkDrain(
        allocator,
        executable,
        &fixture,
        generation_drain_terminal_work,
        oracle,
    );
    try exercisePhaseE(
        allocator,
        executable,
        &fixture,
        generation_peer_reset_work,
        .peer_reset_work,
        oracle,
    );
    try exercisePhaseE(
        allocator,
        executable,
        &fixture,
        generation_drain_response_ready,
        .drain_response_ready,
        oracle,
    );
    try exercisePhaseE(
        allocator,
        executable,
        &fixture,
        generation_complete_response_ready,
        .complete_response_ready,
        oracle,
    );
    try exercisePhaseE(
        allocator,
        executable,
        &fixture,
        generation_drain_response_writing,
        .drain_response_writing,
        oracle,
    );
    try exercisePhaseE(
        allocator,
        executable,
        &fixture,
        generation_complete_response_writing,
        .complete_response_writing,
        oracle,
    );
    try exercisePhaseE(
        allocator,
        executable,
        &fixture,
        generation_full_request_timeout_request_admitted,
        .full_request_timeout_request_admitted,
        oracle,
    );
    try exercisePhaseE(
        allocator,
        executable,
        &fixture,
        generation_full_request_timeout_response_ready,
        .full_request_timeout_response_ready,
        oracle,
    );
    try exercisePhaseE(
        allocator,
        executable,
        &fixture,
        generation_full_request_timeout_response_writing,
        .full_request_timeout_response_writing,
        oracle,
    );
    try exerciseApplicationRejection(
        allocator,
        executable,
        &fixture,
        generation_application_rejection,
        oracle,
    );
    try exerciseConcurrentProfile(
        allocator,
        executable,
        &fixture,
        generation_concurrent_queued_receive_timeout,
        .concurrent_queued_receive_timeout,
        oracle,
    );
    try exerciseConcurrentProfile(
        allocator,
        executable,
        &fixture,
        generation_concurrent_queued_full_request_timeout,
        .concurrent_queued_full_request_timeout,
        oracle,
    );
    try exerciseConcurrentProfile(
        allocator,
        executable,
        &fixture,
        generation_concurrent_drain,
        .concurrent_drain,
        oracle,
    );
    try exerciseConcurrentProfile(
        allocator,
        executable,
        &fixture,
        generation_concurrent_stale_owner_failure,
        .concurrent_stale_owner_failure,
        oracle,
    );
    const second = try exerciseWorker(
        allocator,
        executable,
        &fixture,
        generation_b,
        "server-process-key-b",
        false,
    );
    try validateObservation(second, oracle);

    try require(std.mem.eql(
        u8,
        &first.model_id,
        &second.model_id,
    ));
    try require(std.mem.eql(
        u8,
        &first.binding_sha256,
        &second.binding_sha256,
    ));
    try require(std.mem.eql(
        u8,
        first.completion.contentSlice(),
        second.completion.contentSlice(),
    ));
    try require(std.mem.eql(
        u32,
        first.completion.outputSlice(),
        second.completion.outputSlice(),
    ));
    try require(
        first.completion.prompt_tokens ==
            second.completion.prompt_tokens,
    );
}

fn validateObservation(
    observation: Observation,
    oracle: LocalOracle,
) !void {
    try require(std.mem.eql(
        u8,
        &observation.model_id,
        &oracle.model_id,
    ));
    try require(std.mem.eql(
        u8,
        &observation.binding_sha256,
        &oracle.binding_sha256,
    ));
    try require(observation.completion.output_count == 1);
    try require(observation.completion.output_tokens[0] ==
        oracle.output_token);
    try require(observation.completion.content_bytes == 1);
    try require(observation.completion.content[0] ==
        oracle.content_byte);
}

const WorkerWatchdog = struct {
    const active: u8 = 0;
    const stopped: u8 = 1;
    const timed_out: u8 = 2;

    process_id: std.process.Child.Id,
    state: std.atomic.Value(u8) =
        std.atomic.Value(u8).init(active),
    thread: ?std.Thread = null,

    fn start(self: *WorkerWatchdog) !void {
        if (self.thread != null or
            self.state.load(.acquire) != active)
        {
            return error.InvalidWatchdogState;
        }
        self.thread = try std.Thread.spawn(
            .{},
            WorkerWatchdog.run,
            .{self},
        );
    }

    fn stop(self: *WorkerWatchdog) bool {
        const observed = self.state.cmpxchgStrong(
            active,
            stopped,
            .acq_rel,
            .acquire,
        );
        const did_time_out =
            observed != null and observed.? == timed_out;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        return did_time_out;
    }

    fn run(self: *WorkerWatchdog) void {
        const poll_count =
            worker_timeout_ns / watchdog_poll_ns;
        var polls: u64 = 0;
        while (polls < poll_count) : (polls += 1) {
            if (self.state.load(.acquire) != active)
                return;
            std.Thread.sleep(watchdog_poll_ns);
        }
        if (self.state.cmpxchgStrong(
            active,
            timed_out,
            .acq_rel,
            .acquire,
        ) == null) {
            hardTerminateProcess(self.process_id);
        }
    }
};

fn hardTerminateProcess(process_id: std.process.Child.Id) void {
    switch (builtin.os.tag) {
        .windows => {
            _ = std.os.windows.kernel32.TerminateProcess(
                process_id,
                124,
            );
        },
        .linux, .macos, .freebsd => {
            std.posix.kill(
                process_id,
                std.posix.SIG.KILL,
            ) catch {};
        },
        else => {},
    }
}

fn proveInvalidStartup(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
) !void {
    var child = try spawnWorker(
        allocator,
        executable,
        fixture,
        0,
        .standard,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);
    var watchdog: WorkerWatchdog = .{
        .process_id = child.id,
    };
    try watchdog.start();
    var watchdog_running = true;
    defer if (watchdog_running) {
        _ = watchdog.stop();
    };

    const stdout = try child.stdout.?.readToEndAlloc(
        allocator,
        frame_max_bytes,
    );
    defer allocator.free(stdout);
    try require(std.mem.indexOf(
        u8,
        stdout,
        "READY ",
    ) == null);
    const did_time_out = watchdog.stop();
    watchdog_running = false;
    if (did_time_out) return error.WorkerTimeout;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| try require(code == 2),
        else => return error.UnexpectedWorkerTermination,
    }
}

const PartialDrainKind = enum {
    head,
    body,

    fn command(self: PartialDrainKind) []const u8 {
        return switch (self) {
            .head => drain_head_command,
            .body => drain_body_command,
        };
    }

    fn phase(
        self: PartialDrainKind,
    ) server_api.ManagedConnectionPhaseV1 {
        return switch (self) {
            .head => .receiving_head,
            .body => .request_head_received,
        };
    }
};

fn exercisePartialDrain(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
    generation: u64,
    kind: PartialDrainKind,
    expected_model_id: *const [protocol.model_id_bytes]u8,
) !void {
    var child = try spawnWorker(
        allocator,
        executable,
        fixture,
        generation,
        .drain_with_deadline,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);
    var watchdog: WorkerWatchdog = .{
        .process_id = child.id,
    };
    try watchdog.start();
    var watchdog_running = true;
    defer if (watchdog_running) {
        _ = watchdog.stop();
    };

    var frame_storage: [frame_max_bytes]u8 = undefined;
    const ready = try parseReady(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try require(ready.generation == generation);
    try require(std.mem.eql(
        u8,
        &ready.model_id,
        expected_model_id,
    ));

    const address = try std.net.Address.parseIp(
        loopback_host,
        ready.port,
    );
    const peer = try std.net.tcpConnectToAddress(address);
    defer peer.close();
    try writePartialRequest(peer, ready, kind);

    try child.stdin.?.writeAll(kind.command());
    child.stdin.?.close();
    child.stdin = null;

    const draining = try parseActivity(
        try readFrame(child.stdout.?, &frame_storage),
        "DRAINING",
    );
    try validateActivity(
        draining,
        generation,
        1,
        0,
        1,
        1,
        kind.phase(),
        0,
        .none,
        0,
        .none,
    );
    try requirePeerEofWithoutResponse(peer);

    const closed = try parseClosed(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try validateActivity(
        closed.activity,
        generation,
        1,
        0,
        1,
        1,
        kind.phase(),
        0,
        .none,
        0,
        .none,
    );
    try require(closed.service_active == 0);
    try require(closed.terminal_records == 0);
    try require(closed.bank_zero == 1);
    try requireWorkerEof(child.stdout.?);

    const did_time_out = watchdog.stop();
    watchdog_running = false;
    if (did_time_out) return error.WorkerTimeout;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| try require(code == 0),
        else => return error.UnexpectedWorkerTermination,
    }
}

fn exerciseReceiveTimeout(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
    generation: u64,
    kind: PartialDrainKind,
    expected_model_id: *const [protocol.model_id_bytes]u8,
) !void {
    const profile: WorkerProfile = switch (kind) {
        .head => .timeout_head,
        .body => .timeout_body,
    };
    var child = try spawnWorker(
        allocator,
        executable,
        fixture,
        generation,
        profile,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);
    var watchdog: WorkerWatchdog = .{
        .process_id = child.id,
    };
    try watchdog.start();
    var watchdog_running = true;
    defer if (watchdog_running) {
        _ = watchdog.stop();
    };

    var frame_storage: [frame_max_bytes]u8 = undefined;
    const ready = try parseReady(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try require(ready.generation == generation);
    try require(std.mem.eql(
        u8,
        &ready.model_id,
        expected_model_id,
    ));

    const address = try std.net.Address.parseIp(
        loopback_host,
        ready.port,
    );
    const peer = try std.net.tcpConnectToAddress(address);
    defer peer.close();
    var timeout_timer = try std.time.Timer.start();
    try writePartialRequest(peer, ready, kind);
    if (kind == .head) {
        for (0..timeout_head_trickle_count) |_| {
            std.Thread.sleep(timeout_head_trickle_interval_ns);
            try peer.writeAll("x");
        }
    }

    const timed_out = try parseTimedOut(
        try readFrame(child.stdout.?, &frame_storage),
    );
    const observed_timeout_ns = timeout_timer.read();
    if (observed_timeout_ns <
        retained_receive_timeout_minimum_observation_ns)
    {
        return error.ReceiveTimeoutTooEarly;
    }
    if (kind == .head and
        observed_timeout_ns >
            retained_receive_timeout_maximum_observation_ns)
    {
        return error.ReceiveTimeoutTooLate;
    }
    try require(timed_out.generation == generation);
    try require(timed_out.phase == kind.phase());
    try requirePeerEofWithoutResponse(peer);

    var client = try http_client.ClientV1.initLoopback(
        allocator,
        loopback_host,
        ready.port,
    );
    defer client.deinit();
    const models = try expectModels(
        try client.listModelsV1(),
    );
    try require(std.mem.eql(
        u8,
        &models.model_id,
        expected_model_id,
    ));

    try child.stdin.?.writeAll(drain_command);
    child.stdin.?.close();
    child.stdin = null;

    const draining = try parseActivity(
        try readFrame(child.stdout.?, &frame_storage),
        "DRAINING",
    );
    try validateActivity(
        draining,
        generation,
        2,
        1,
        1,
        0,
        .none,
        1,
        kind.phase(),
        0,
        .none,
    );
    const closed = try parseClosed(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try validateActivity(
        closed.activity,
        generation,
        2,
        1,
        1,
        0,
        .none,
        1,
        kind.phase(),
        0,
        .none,
    );
    try require(closed.service_active == 0);
    try require(closed.terminal_records == 0);
    try require(closed.bank_zero == 1);
    try requireWorkerEof(child.stdout.?);

    const did_time_out = watchdog.stop();
    watchdog_running = false;
    if (did_time_out) return error.WorkerTimeout;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| try require(code == 0),
        else => return error.UnexpectedWorkerTermination,
    }
}

fn writePartialRequest(
    peer: std.net.Stream,
    ready: ReadyFrame,
    kind: PartialDrainKind,
) !void {
    switch (kind) {
        .head => try peer.writeAll(
            "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1",
        ),
        .body => {
            var body_storage: [protocol.request_body_max_bytes]u8 = undefined;
            const body = try protocol.encodeRequestV1(.{
                .model_id = &ready.model_id,
                .tenant_key = 31,
                .idempotency_key = "server-process-partial-body",
                .prompt_utf8 = prompt,
                .max_new_tokens = 1,
            }, &body_storage);
            if (body.len < 2)
                return error.InvalidPartialRequestFixture;

            var head_storage: [1024]u8 = undefined;
            const head = try std.fmt.bufPrint(
                &head_storage,
                "POST {s} HTTP/1.1\r\n" ++
                    "Host: {s}:{d}\r\n" ++
                    "Content-Type: {s}\r\n" ++
                    "Content-Length: {d}\r\n" ++
                    "{s}: server-process-partial-body\r\n" ++
                    "{s}: 31\r\n" ++
                    "Connection: close\r\n\r\n",
                .{
                    protocol.completions_path_v1,
                    loopback_host,
                    ready.port,
                    protocol.json_content_type,
                    body.len,
                    protocol.idempotency_header,
                    protocol.tenant_header,
                },
            );
            try peer.writeAll(head);
            try peer.writeAll(body[0 .. body.len - 1]);
        },
    }
}

fn requirePeerEofWithoutResponse(peer: std.net.Stream) !void {
    var response: [1]u8 = undefined;
    const read_count = peer.read(&response) catch |read_error| {
        const transport_error: anyerror = read_error;
        switch (transport_error) {
            error.ConnectionResetByPeer,
            error.ConnectionAborted,
            => return,
            else => return read_error,
        }
    };
    if (read_count != 0)
        return error.UnexpectedPartialDrainResponse;
}

fn requirePeerEofWithoutCompleteResponse(
    peer: std.net.Stream,
) !usize {
    var response: [protocol.header_max_bytes]u8 = undefined;
    var used: usize = 0;
    while (used < response.len) {
        const read_count = peer.read(response[used..]) catch |read_error| {
            const transport_error: anyerror = read_error;
            switch (transport_error) {
                error.ConnectionResetByPeer,
                error.ConnectionAborted,
                => break,
                else => return read_error,
            }
        };
        if (read_count == 0) break;
        used += read_count;
    }
    if (used == response.len or
        std.mem.indexOf(u8, response[0..used], "\r\n\r\n") != null)
    {
        return error.UnexpectedCompleteTimeoutResponse;
    }
    return used;
}

const CancellationClientContext = struct {
    port: u16,
    model_id: [protocol.model_id_bytes]u8,
    api_error: ?protocol.ApiErrorV1 = null,
    unexpected_completion: bool = false,
    thread_error: ?anyerror = null,

    fn run(self: *CancellationClientContext) void {
        self.runFallible() catch |err| {
            self.thread_error = err;
        };
    }

    fn runFallible(self: *CancellationClientContext) !void {
        var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        var client = try http_client.ClientV1.initLoopback(
            gpa.allocator(),
            loopback_host,
            self.port,
        );
        defer client.deinit();
        const result = try client.completeV1(.{
            .model_id = &self.model_id,
            .tenant_key = 37,
            .idempotency_key = "server-process-drain-work",
            .prompt_utf8 = prompt,
            .max_new_tokens = 1,
        });
        switch (result) {
            .ok => self.unexpected_completion = true,
            .api_error => |api_error| self.api_error = api_error,
        }
    }
};

fn exerciseAdmittedWorkDrain(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
    generation: u64,
    expected_model_id: *const [protocol.model_id_bytes]u8,
) !void {
    var child = try spawnWorker(
        allocator,
        executable,
        fixture,
        generation,
        .drain_work,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);
    var watchdog: WorkerWatchdog = .{
        .process_id = child.id,
    };
    try watchdog.start();
    var watchdog_running = true;
    defer if (watchdog_running) {
        _ = watchdog.stop();
    };

    var frame_storage: [frame_max_bytes]u8 = undefined;
    const ready = try parseReady(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try require(ready.generation == generation);
    try require(std.mem.eql(
        u8,
        &ready.model_id,
        expected_model_id,
    ));

    var client_context: CancellationClientContext = .{
        .port = ready.port,
        .model_id = ready.model_id,
    };
    const client_thread = try std.Thread.spawn(
        .{},
        CancellationClientContext.run,
        .{&client_context},
    );
    var client_joined = false;
    defer if (!client_joined) {
        if (!waited) {
            terminateChild(&child);
            waited = true;
        }
        client_thread.join();
    };

    try child.stdin.?.writeAll(drain_work_command);
    child.stdin.?.close();
    child.stdin = null;

    const draining = try parseActivity(
        try readFrame(child.stdout.?, &frame_storage),
        "DRAINING",
    );
    client_thread.join();
    client_joined = true;
    if (client_context.thread_error) |err| return err;
    try require(!client_context.unexpected_completion);
    const api_error = client_context.api_error orelse
        return error.MissingCancellationResponse;
    try require(api_error.code == .request_cancelled);
    try require(api_error.retry == .never);
    const request_sha256 = try protocol.requestSha256V1(.{
        .model_id = &ready.model_id,
        .tenant_key = 37,
        .idempotency_key = "server-process-drain-work",
        .prompt_utf8 = prompt,
        .max_new_tokens = 1,
    });
    const response_request_sha256 =
        api_error.request_sha256 orelse
        return error.MissingCancellationCorrelation;
    try require(std.mem.eql(
        u8,
        &request_sha256,
        &response_request_sha256,
    ));

    try validateActivity(
        draining,
        generation,
        1,
        1,
        0,
        0,
        .none,
        0,
        .none,
        1,
        .request_admitted,
    );
    const closed = try parseClosed(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try validateActivity(
        closed.activity,
        generation,
        1,
        1,
        0,
        0,
        .none,
        0,
        .none,
        1,
        .request_admitted,
    );
    try require(closed.service_active == 0);
    try require(closed.terminal_records == 1);
    try require(closed.bank_zero == 1);
    try requireWorkerEof(child.stdout.?);

    const did_time_out = watchdog.stop();
    watchdog_running = false;
    if (did_time_out) return error.WorkerTimeout;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| try require(code == 0),
        else => return error.UnexpectedWorkerTermination,
    }
}

const TerminalClientContext = struct {
    port: u16,
    model_id: [protocol.model_id_bytes]u8,
    completion: ?protocol.CompletionV1 = null,
    unexpected_api_error: ?protocol.ApiErrorV1 = null,
    thread_error: ?anyerror = null,

    fn run(self: *TerminalClientContext) void {
        self.runFallible() catch |err| {
            self.thread_error = err;
        };
    }

    fn runFallible(self: *TerminalClientContext) !void {
        var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        var client = try http_client.ClientV1.initLoopback(
            gpa.allocator(),
            loopback_host,
            self.port,
        );
        defer client.deinit();
        const result = try client.completeV1(.{
            .model_id = &self.model_id,
            .tenant_key = 41,
            .idempotency_key = "server-process-terminal-work",
            .prompt_utf8 = prompt,
            .max_new_tokens = 1,
        });
        switch (result) {
            .ok => |completion| self.completion = completion,
            .api_error => |api_error| {
                self.unexpected_api_error = api_error;
            },
        }
    }
};

fn exerciseTerminalWorkDrain(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
    generation: u64,
    oracle: LocalOracle,
) !void {
    var child = try spawnWorker(
        allocator,
        executable,
        fixture,
        generation,
        .drain_terminal_work,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);
    var watchdog: WorkerWatchdog = .{
        .process_id = child.id,
    };
    try watchdog.start();
    var watchdog_running = true;
    defer if (watchdog_running) {
        _ = watchdog.stop();
    };

    var frame_storage: [frame_max_bytes]u8 = undefined;
    const ready = try parseReady(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try require(ready.generation == generation);
    try require(std.mem.eql(
        u8,
        &ready.model_id,
        &oracle.model_id,
    ));

    var client_context: TerminalClientContext = .{
        .port = ready.port,
        .model_id = ready.model_id,
    };
    const client_thread = try std.Thread.spawn(
        .{},
        TerminalClientContext.run,
        .{&client_context},
    );
    var client_joined = false;
    defer if (!client_joined) {
        if (!waited) {
            terminateChild(&child);
            waited = true;
        }
        client_thread.join();
    };

    try child.stdin.?.writeAll(drain_terminal_work_command);
    child.stdin.?.close();
    child.stdin = null;

    const draining = try parseActivity(
        try readFrame(child.stdout.?, &frame_storage),
        "DRAINING",
    );
    client_thread.join();
    client_joined = true;
    if (client_context.thread_error) |err| return err;
    try require(client_context.unexpected_api_error == null);
    const completion = client_context.completion orelse
        return error.MissingTerminalCompletion;
    try require(completion.output_count == 1);
    try require(completion.output_tokens[0] ==
        oracle.output_token);
    try require(completion.content_bytes == 1);
    try require(completion.content[0] ==
        oracle.content_byte);
    const request_sha256 = try protocol.requestSha256V1(.{
        .model_id = &ready.model_id,
        .tenant_key = 41,
        .idempotency_key = "server-process-terminal-work",
        .prompt_utf8 = prompt,
        .max_new_tokens = 1,
    });
    try require(std.mem.eql(
        u8,
        &completion.request_sha256,
        &request_sha256,
    ));

    try validateActivity(
        draining,
        generation,
        1,
        1,
        0,
        0,
        .none,
        0,
        .none,
        0,
        .none,
    );
    const closed = try parseClosed(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try validateActivity(
        closed.activity,
        generation,
        1,
        1,
        0,
        0,
        .none,
        0,
        .none,
        0,
        .none,
    );
    try require(closed.service_active == 0);
    try require(closed.terminal_records == 1);
    try require(closed.bank_zero == 1);
    try requireWorkerEof(child.stdout.?);

    const did_time_out = watchdog.stop();
    watchdog_running = false;
    if (did_time_out) return error.WorkerTimeout;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| try require(code == 0),
        else => return error.UnexpectedWorkerTermination,
    }
}

fn exercisePhaseE(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
    generation: u64,
    profile: WorkerProfile,
    oracle: LocalOracle,
) !void {
    if (!profile.isPhaseE())
        return error.InvalidWorkerProfile;
    var child = try spawnWorker(
        allocator,
        executable,
        fixture,
        generation,
        profile,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);
    var watchdog: WorkerWatchdog = .{
        .process_id = child.id,
    };
    try watchdog.start();
    var watchdog_running = true;
    defer if (watchdog_running) {
        _ = watchdog.stop();
    };

    var frame_storage: [frame_max_bytes]u8 = undefined;
    const ready = try parseReady(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try require(ready.generation == generation);
    try require(std.mem.eql(
        u8,
        &ready.model_id,
        &oracle.model_id,
    ));

    var peer: ?std.net.Stream = null;
    defer if (peer) |stream| stream.close();
    var client_context: TerminalClientContext = .{
        .port = ready.port,
        .model_id = ready.model_id,
    };
    var client_thread: ?std.Thread = null;
    var client_joined = false;
    defer if (client_thread) |thread| {
        if (!client_joined) {
            if (!waited) {
                terminateChild(&child);
                waited = true;
            }
            thread.join();
        }
    };

    switch (profile) {
        .peer_reset_work => {
            peer = try openCompletionPeer(
                ready,
                43,
                "server-process-peer-reset",
            );
            try child.stdin.?.writeAll(
                peer_reset_arm_command,
            );
            try expectCheckpointFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "WORK_ADMITTED",
                generation,
            );
            try setAbortiveReset(peer.?);
            peer.?.close();
            peer = null;
            try child.stdin.?.writeAll(
                peer_reset_release_command,
            );
            try expectCheckpointFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "PEER_RESET",
                generation,
            );

            var liveness_client =
                try http_client.ClientV1.initLoopback(
                    allocator,
                    loopback_host,
                    ready.port,
                );
            defer liveness_client.deinit();
            const models = try expectModels(
                try liveness_client.listModelsV1(),
            );
            try require(std.mem.eql(
                u8,
                &models.model_id,
                &ready.model_id,
            ));
            try child.stdin.?.writeAll(
                peer_reset_drain_command,
            );
            child.stdin.?.close();
            child.stdin = null;
        },
        .drain_response_ready => {
            peer = try openCompletionPeer(
                ready,
                47,
                "server-process-response-drain",
            );
            try child.stdin.?.writeAll(
                drain_response_ready_command,
            );
            child.stdin.?.close();
            child.stdin = null;
        },
        .complete_response_ready => {
            client_thread = try std.Thread.spawn(
                .{},
                TerminalClientContext.run,
                .{&client_context},
            );
            try child.stdin.?.writeAll(
                complete_response_ready_command,
            );
            child.stdin.?.close();
            child.stdin = null;
        },
        .drain_response_writing => {
            peer = try openCompletionPeer(
                ready,
                53,
                "server-process-response-write-drain",
            );
            try child.stdin.?.writeAll(
                drain_response_writing_command,
            );
            child.stdin.?.close();
            child.stdin = null;
        },
        .complete_response_writing => {
            client_thread = try std.Thread.spawn(
                .{},
                TerminalClientContext.run,
                .{&client_context},
            );
            try child.stdin.?.writeAll(
                complete_response_writing_command,
            );
            child.stdin.?.close();
            child.stdin = null;
        },
        .full_request_timeout_request_admitted,
        .full_request_timeout_response_ready,
        .full_request_timeout_response_writing,
        => {
            const tenant_key: u64 = switch (profile) {
                .full_request_timeout_request_admitted => 59,
                .full_request_timeout_response_ready => 61,
                .full_request_timeout_response_writing => 67,
                else => unreachable,
            };
            const idempotency_key = switch (profile) {
                .full_request_timeout_request_admitted => "server-process-full-timeout-work",
                .full_request_timeout_response_ready => "server-process-full-timeout-response",
                .full_request_timeout_response_writing => "server-process-full-timeout-write",
                else => unreachable,
            };
            peer = try openCompletionPeer(
                ready,
                tenant_key,
                idempotency_key,
            );
            try expectCheckpointFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "FULL_REQUEST_TIMEOUT",
                generation,
            );
            const response_bytes =
                try requirePeerEofWithoutCompleteResponse(peer.?);
            if (profile ==
                .full_request_timeout_response_writing)
            {
                try require(response_bytes <= 1);
            } else {
                try require(response_bytes == 0);
            }
            peer.?.close();
            peer = null;

            var liveness_client =
                try http_client.ClientV1.initLoopback(
                    allocator,
                    loopback_host,
                    ready.port,
                );
            defer liveness_client.deinit();
            const models = try expectModels(
                try liveness_client.listModelsV1(),
            );
            try require(std.mem.eql(
                u8,
                &models.model_id,
                &ready.model_id,
            ));
            try child.stdin.?.writeAll(drain_command);
            child.stdin.?.close();
            child.stdin = null;
        },
        else => unreachable,
    }

    const draining = try parseActivity(
        try readFrame(child.stdout.?, &frame_storage),
        "DRAINING",
    );
    const response_completed =
        profile == .complete_response_ready or
        profile == .complete_response_writing;
    const full_request_timeout =
        profile.isFullRequestTimeout();
    const expected_completed: u64 =
        if (profile == .peer_reset_work or
        response_completed or
        full_request_timeout)
            1
        else
            0;
    const expected_failed: u64 =
        if (response_completed) 0 else 1;
    try validateActivity(
        draining,
        generation,
        if (profile == .peer_reset_work or
            full_request_timeout)
            2
        else
            1,
        expected_completed,
        expected_failed,
        0,
        .none,
        0,
        .none,
        0,
        .none,
    );
    try validatePhaseEActivity(draining, profile);

    if (profile == .drain_response_ready) {
        try requirePeerEofWithoutResponse(peer.?);
        peer.?.close();
        peer = null;
    }
    if (profile == .drain_response_writing) {
        peer.?.close();
        peer = null;
    }
    if (client_thread) |thread| {
        thread.join();
        client_joined = true;
        if (client_context.thread_error) |err| return err;
        try require(client_context.unexpected_api_error == null);
        const completion = client_context.completion orelse
            return error.MissingTerminalCompletion;
        try require(std.mem.eql(
            u8,
            &completion.model_id,
            &ready.model_id,
        ));
        try require(completion.output_count == 1);
        try require(completion.output_tokens[0] ==
            oracle.output_token);
        try require(completion.content_bytes == 1);
        try require(completion.content[0] ==
            oracle.content_byte);
        const request_sha256 = try protocol.requestSha256V1(.{
            .model_id = &ready.model_id,
            .tenant_key = 41,
            .idempotency_key = "server-process-terminal-work",
            .prompt_utf8 = prompt,
            .max_new_tokens = 1,
        });
        try require(std.mem.eql(
            u8,
            &completion.request_sha256,
            &request_sha256,
        ));
    }

    const closed = try parseClosed(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try validateActivity(
        closed.activity,
        generation,
        if (profile == .peer_reset_work or
            full_request_timeout)
            2
        else
            1,
        expected_completed,
        expected_failed,
        0,
        .none,
        0,
        .none,
        0,
        .none,
    );
    try validatePhaseEActivity(closed.activity, profile);
    try require(closed.service_active == 0);
    try require(closed.terminal_records == 1);
    try require(closed.bank_zero == 1);
    try requireWorkerEof(child.stdout.?);

    const did_time_out = watchdog.stop();
    watchdog_running = false;
    if (did_time_out) return error.WorkerTimeout;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| try require(code == 0),
        else => return error.UnexpectedWorkerTermination,
    }
}

fn exerciseConcurrentProfile(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
    generation: u64,
    profile: WorkerProfile,
    oracle: LocalOracle,
) !void {
    if (!profile.isConcurrent())
        return error.InvalidConcurrentWorkerProfile;
    var child = try spawnWorker(
        allocator,
        executable,
        fixture,
        generation,
        profile,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);
    var watchdog: WorkerWatchdog = .{
        .process_id = child.id,
    };
    try watchdog.start();
    var watchdog_running = true;
    defer if (watchdog_running) {
        _ = watchdog.stop();
    };

    var frame_storage: [frame_max_bytes]u8 = undefined;
    const ready = try parseReady(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try require(ready.generation == generation);
    try require(std.mem.eql(
        u8,
        &ready.model_id,
        &oracle.model_id,
    ));

    var first_peer: ?std.net.Stream = null;
    defer if (first_peer) |stream| stream.close();
    var queued_peer: ?std.net.Stream = null;
    defer if (queued_peer) |stream| stream.close();
    var active_client: TerminalClientContext = .{
        .port = ready.port,
        .model_id = ready.model_id,
    };
    var active_client_thread: ?std.Thread = null;
    var active_client_joined = false;
    defer if (active_client_thread) |thread| {
        if (!active_client_joined) {
            if (!waited) {
                terminateChild(&child);
                waited = true;
            }
            thread.join();
        }
    };

    switch (profile) {
        .concurrent_queued_receive_timeout,
        .concurrent_queued_full_request_timeout,
        => {
            active_client_thread = try std.Thread.spawn(
                .{},
                TerminalClientContext.run,
                .{&active_client},
            );
            const active = try parseConcurrentEventFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_ACTIVE",
            );
            try validateConcurrentEventCheckpoint(
                active,
                generation,
                1,
                .dispatched,
            );

            queued_peer = try openModelsPeer(ready);
            const queued = try parseConcurrentEventFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_QUEUED",
            );
            try validateConcurrentEventCheckpoint(
                queued,
                generation,
                2,
                .enqueued,
            );
            try require(queued.ordinal > active.ordinal);
            try require(!sameConcurrentLease(
                active,
                queued,
            ));

            const timed_out = try parseConcurrentEventFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_QUEUED_TIMEOUT",
            );
            try validateConcurrentEventCheckpoint(
                timed_out,
                generation,
                2,
                if (profile ==
                    .concurrent_queued_receive_timeout)
                    .queued_receive_timeout
                else
                    .queued_full_request_timeout,
            );
            try require(timed_out.ordinal > queued.ordinal);
            try require(sameConcurrentLease(
                timed_out,
                queued,
            ));
            try requirePeerEofWithoutResponse(queued_peer.?);
            queued_peer.?.close();
            queued_peer = null;

            try child.stdin.?.writeAll(
                concurrent_release_command,
            );
            const retired = try parseConcurrentEventFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_FIRST_RETIRED",
            );
            try validateConcurrentEventCheckpoint(
                retired,
                generation,
                1,
                .retired,
            );
            try require(retired.ordinal > timed_out.ordinal);
            try require(sameConcurrentLease(
                retired,
                active,
            ));

            const thread = active_client_thread.?;
            thread.join();
            active_client_joined = true;
            if (profile ==
                .concurrent_queued_receive_timeout)
            {
                if (active_client.thread_error) |err| return err;
                try require(
                    active_client.unexpected_api_error == null,
                );
                const completion =
                    active_client.completion orelse
                    return error.MissingConcurrentActiveCompletion;
                try validateCompletionAgainstOracle(
                    completion,
                    ready,
                    oracle,
                    41,
                    "server-process-terminal-work",
                );
            } else {
                try require(active_client.completion == null);
                try require(
                    active_client.thread_error != null or
                        active_client.unexpected_api_error != null,
                );
            }

            try completeConcurrentSuccessor(
                allocator,
                ready,
                oracle,
                if (profile ==
                    .concurrent_queued_receive_timeout)
                    71
                else
                    73,
                if (profile ==
                    .concurrent_queued_receive_timeout)
                    "concurrent-receive-successor"
                else
                    "concurrent-full-successor",
            );
            try child.stdin.?.writeAll(drain_command);
        },
        .concurrent_drain => {
            first_peer = try connectReadyPeer(ready);
            try writePartialRequest(
                first_peer.?,
                ready,
                .head,
            );
            const active = try parseConcurrentEventFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_ACTIVE",
            );
            try validateConcurrentEventCheckpoint(
                active,
                generation,
                1,
                .dispatched,
            );

            queued_peer = try openModelsPeer(ready);
            const queued = try parseConcurrentEventFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_QUEUED",
            );
            try validateConcurrentEventCheckpoint(
                queued,
                generation,
                2,
                .enqueued,
            );
            try require(queued.ordinal > active.ordinal);
            try require(!sameConcurrentLease(
                active,
                queued,
            ));

            try child.stdin.?.writeAll(drain_command);
            const queued_drain =
                try parseConcurrentEventFrame(
                    try readFrame(
                        child.stdout.?,
                        &frame_storage,
                    ),
                    "CONCURRENT_QUEUED_DRAIN",
                );
            try validateConcurrentEventCheckpoint(
                queued_drain,
                generation,
                2,
                .queued_drain,
            );
            try require(queued_drain.ordinal > queued.ordinal);
            try require(sameConcurrentLease(
                queued_drain,
                queued,
            ));
            try requirePeerEofWithoutResponse(
                queued_peer.?,
            );
            queued_peer.?.close();
            queued_peer = null;
            try requirePeerEofWithoutResponse(first_peer.?);
            first_peer.?.close();
            first_peer = null;
        },
        .concurrent_stale_owner_failure => {
            {
                var client =
                    try http_client.ClientV1.initLoopback(
                        allocator,
                        loopback_host,
                        ready.port,
                    );
                defer client.deinit();
                const models = try expectModels(
                    try client.listModelsV1(),
                );
                try require(std.mem.eql(
                    u8,
                    &models.model_id,
                    &ready.model_id,
                ));
            }
            const predecessor = try parseConcurrentEventFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_PREDECESSOR_RETIRED",
            );
            try validateConcurrentEventCheckpoint(
                predecessor,
                generation,
                1,
                .retired,
            );

            first_peer = try openCompletionPeer(
                ready,
                79,
                "concurrent-stale-active",
            );
            const active = try parseConcurrentEventFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_WORK_ADMITTED",
            );
            try validateConcurrentEventCheckpoint(
                active,
                generation,
                2,
                .dispatched,
            );
            try require(active.ordinal > predecessor.ordinal);
            try require(
                active.slot_index == predecessor.slot_index and
                    active.slot_generation >
                        predecessor.slot_generation,
            );

            queued_peer = try openModelsPeer(ready);
            const queued = try parseConcurrentEventFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_QUEUED",
            );
            try validateConcurrentEventCheckpoint(
                queued,
                generation,
                3,
                .enqueued,
            );
            try require(queued.ordinal > active.ordinal);
            try require(!sameConcurrentLease(
                active,
                queued,
            ));

            try child.stdin.?.writeAll(
                concurrent_fault_command,
            );
            try expectCheckpointFrame(
                try readFrame(child.stdout.?, &frame_storage),
                "CONCURRENT_STALE_OWNER_REJECTED",
                generation,
            );
            const queued_failure =
                try parseConcurrentEventFrame(
                    try readFrame(
                        child.stdout.?,
                        &frame_storage,
                    ),
                    "CONCURRENT_QUEUED_FAILURE",
                );
            try validateConcurrentEventCheckpoint(
                queued_failure,
                generation,
                3,
                .queued_failure,
            );
            try require(
                queued_failure.ordinal > queued.ordinal,
            );
            try require(sameConcurrentLease(
                queued_failure,
                queued,
            ));
            const running_failure =
                try parseConcurrentEventFrame(
                    try readFrame(
                        child.stdout.?,
                        &frame_storage,
                    ),
                    "CONCURRENT_RUNNING_FAILURE",
                );
            try validateConcurrentEventCheckpoint(
                running_failure,
                generation,
                2,
                .running_failure,
            );
            try require(
                running_failure.ordinal >
                    queued_failure.ordinal,
            );
            try require(sameConcurrentLease(
                running_failure,
                active,
            ));
            try requirePeerEofWithoutResponse(
                queued_peer.?,
            );
            queued_peer.?.close();
            queued_peer = null;
            try require(
                try requirePeerEofWithoutCompleteResponse(
                    first_peer.?,
                ) == 0,
            );
            first_peer.?.close();
            first_peer = null;
        },
        else => unreachable,
    }

    child.stdin.?.close();
    child.stdin = null;
    try validateConcurrentClosedFrames(
        child.stdout.?,
        &frame_storage,
        generation,
        profile,
    );
    try requireWorkerEof(child.stdout.?);

    const did_time_out = watchdog.stop();
    watchdog_running = false;
    if (did_time_out) return error.WorkerTimeout;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| try require(code == 0),
        else => return error.UnexpectedWorkerTermination,
    }
}

fn validateConcurrentEventCheckpoint(
    frame: ConcurrentEventFrame,
    generation: u64,
    sequence: u64,
    kind: server_api.ManagedConcurrentEventKindV1,
) !void {
    try require(frame.generation == generation);
    try require(frame.connection_sequence == sequence);
    try require(frame.slot_generation != 0);
    try require(frame.ordinal != 0);
    try require(frame.kind == kind);
}

fn sameConcurrentLease(
    first: ConcurrentEventFrame,
    second: ConcurrentEventFrame,
) bool {
    return first.generation == second.generation and
        first.connection_sequence ==
            second.connection_sequence and
        first.slot_index == second.slot_index and
        first.slot_generation == second.slot_generation;
}

fn validateCompletionAgainstOracle(
    completion: protocol.CompletionV1,
    ready: ReadyFrame,
    oracle: LocalOracle,
    tenant_key: u64,
    idempotency_key: []const u8,
) !void {
    try require(std.mem.eql(
        u8,
        &completion.model_id,
        &ready.model_id,
    ));
    try require(completion.output_count == 1);
    try require(completion.output_tokens[0] ==
        oracle.output_token);
    try require(completion.content_bytes == 1);
    try require(completion.content[0] ==
        oracle.content_byte);
    const request_sha256 = try protocol.requestSha256V1(.{
        .model_id = &ready.model_id,
        .tenant_key = tenant_key,
        .idempotency_key = idempotency_key,
        .prompt_utf8 = prompt,
        .max_new_tokens = 1,
    });
    try require(std.mem.eql(
        u8,
        &completion.request_sha256,
        &request_sha256,
    ));
}

fn completeConcurrentSuccessor(
    allocator: std.mem.Allocator,
    ready: ReadyFrame,
    oracle: LocalOracle,
    tenant_key: u64,
    idempotency_key: []const u8,
) !void {
    var client = try http_client.ClientV1.initLoopback(
        allocator,
        loopback_host,
        ready.port,
    );
    defer client.deinit();
    const completion = try expectCompletion(
        try client.completeV1(.{
            .model_id = &ready.model_id,
            .tenant_key = tenant_key,
            .idempotency_key = idempotency_key,
            .prompt_utf8 = prompt,
            .max_new_tokens = 1,
        }),
    );
    try validateCompletionAgainstOracle(
        completion,
        ready,
        oracle,
        tenant_key,
        idempotency_key,
    );
}

fn validateConcurrentClosedFrames(
    stdout: std.fs.File,
    storage: *[frame_max_bytes]u8,
    generation: u64,
    profile: WorkerProfile,
) !void {
    const snapshot = try parseConcurrentSnapshotFrame(
        try readFrame(stdout, storage),
    );
    const causes = try parseConcurrentCauseFrame(
        try readFrame(stdout, storage),
    );
    const ownership = try parseConcurrentOwnershipFrame(
        try readFrame(stdout, storage),
    );

    try require(snapshot.profile == profile);
    try require(snapshot.generation == generation);
    const expected_state: server_api.ManagedStateV1 =
        if (profile == .concurrent_stale_owner_failure)
            .failed
        else
            .stopped;
    try require(snapshot.state == expected_state);
    try require(snapshot.worker_count == 1);
    try require(snapshot.pending_capacity == 1);
    try require(snapshot.active == 0);
    try require(snapshot.queued == 0);
    try require(snapshot.running == 0);
    try require(snapshot.phase_total == 0);
    try require(snapshot.queue_high_watermark == 1);
    try require(snapshot.running_high_watermark == 1);
    try require(snapshot.enqueued == snapshot.accepted);
    try require(snapshot.accepted ==
        snapshot.completed + snapshot.failed);
    try require(snapshot.event_ordinal ==
        snapshot.event_count);
    try require(snapshot.cleanup_failed == 0);
    try require(snapshot.backpressure_activations != 0);

    const base_event_count: usize = switch (profile) {
        .concurrent_queued_receive_timeout,
        .concurrent_queued_full_request_timeout,
        => 8,
        .concurrent_drain => 5,
        .concurrent_stale_owner_failure => 9,
        else => unreachable,
    };
    try require(snapshot.event_count ==
        base_event_count +
            @as(
                usize,
                @intCast(
                    snapshot.backpressure_activations +
                        snapshot.backpressure_resumptions,
                ),
            ));

    try require(causes.generation == generation);
    try require(causes.drain_cancelled_work == 0);
    try require(causes.failure_cancelled_work == 0);
    try require(causes.failure_cancelled_response == 0);
    try require(
        causes.failure_requested_response_write == 0,
    );
    try require(
        causes.failure_cancelled_response_write == 0,
    );
    switch (profile) {
        .concurrent_queued_receive_timeout => {
            try require(snapshot.accepted == 3);
            try require(snapshot.completed == 2);
            try require(snapshot.failed == 1);
            try require(snapshot.dispatched == 2);
            try require(
                snapshot.backpressure_resumptions ==
                    snapshot.backpressure_activations,
            );
            try require(causes.drain_queued == 0);
            try require(causes.failure_queued == 0);
            try require(causes.receive_timeout_queued == 1);
            try require(
                causes.full_request_timeout_queued == 0,
            );
            try require(causes.drain_signaled == 0);
            try require(causes.last_drain_phase == .none);
            try require(causes.failure_signaled == 0);
            try require(causes.last_failure_phase == .none);
            try require(causes.receive_timeout_signaled == 1);
            try require(
                causes.last_receive_timeout_phase == .queued,
            );
            try require(
                causes.full_request_timeout_signaled == 0,
            );
            try require(
                causes.last_full_request_timeout_phase == .none,
            );
        },
        .concurrent_queued_full_request_timeout => {
            try require(snapshot.accepted == 3);
            try require(snapshot.completed == 1);
            try require(snapshot.failed == 2);
            try require(snapshot.dispatched == 2);
            try require(
                snapshot.backpressure_resumptions ==
                    snapshot.backpressure_activations,
            );
            try require(causes.drain_queued == 0);
            try require(causes.failure_queued == 0);
            try require(causes.receive_timeout_queued == 0);
            try require(
                causes.full_request_timeout_queued == 1,
            );
            try require(causes.drain_signaled == 0);
            try require(causes.last_drain_phase == .none);
            try require(causes.failure_signaled == 0);
            try require(causes.last_failure_phase == .none);
            try require(causes.receive_timeout_signaled == 0);
            try require(
                causes.last_receive_timeout_phase == .none,
            );
            try require(
                causes.full_request_timeout_signaled == 2,
            );
            try require(
                causes.last_full_request_timeout_phase ==
                    .queued or
                    causes.last_full_request_timeout_phase ==
                        .request_admitted,
            );
        },
        .concurrent_drain => {
            try require(snapshot.accepted == 2);
            try require(snapshot.completed == 0);
            try require(snapshot.failed == 2);
            try require(snapshot.dispatched == 1);
            try require(
                snapshot.backpressure_resumptions + 1 ==
                    snapshot.backpressure_activations,
            );
            try require(causes.drain_queued == 1);
            try require(causes.failure_queued == 0);
            try require(causes.receive_timeout_queued == 0);
            try require(
                causes.full_request_timeout_queued == 0,
            );
            try require(causes.drain_signaled == 2);
            try require(
                causes.last_drain_phase == .receiving_head,
            );
            try require(causes.failure_signaled == 0);
            try require(causes.last_failure_phase == .none);
            try require(causes.receive_timeout_signaled == 0);
            try require(
                causes.last_receive_timeout_phase == .none,
            );
            try require(
                causes.full_request_timeout_signaled == 0,
            );
            try require(
                causes.last_full_request_timeout_phase == .none,
            );
        },
        .concurrent_stale_owner_failure => {
            try require(snapshot.accepted == 3);
            try require(snapshot.completed == 1);
            try require(snapshot.failed == 2);
            try require(snapshot.dispatched == 2);
            try require(
                snapshot.backpressure_resumptions + 1 ==
                    snapshot.backpressure_activations,
            );
            try require(causes.drain_queued == 0);
            try require(causes.failure_queued == 1);
            try require(causes.receive_timeout_queued == 0);
            try require(
                causes.full_request_timeout_queued == 0,
            );
            try require(causes.drain_signaled == 0);
            try require(causes.last_drain_phase == .none);
            try require(causes.failure_signaled == 1);
            try require(
                causes.last_failure_phase ==
                    .request_admitted,
            );
            try require(causes.receive_timeout_signaled == 0);
            try require(
                causes.last_receive_timeout_phase == .none,
            );
            try require(
                causes.full_request_timeout_signaled == 0,
            );
            try require(
                causes.last_full_request_timeout_phase == .none,
            );
        },
        else => unreachable,
    }

    try require(ownership.generation == generation);
    try require(ownership.service_active == 0);
    try require(ownership.recovery_required == 0);
    try require(ownership.failed_records == 0);
    try require(ownership.scheduler_zero == 1);
    try require(ownership.bank_zero == 1);
    try require(ownership.serve_joined == 1);
    try require(ownership.serving == 0);
    switch (profile) {
        .concurrent_queued_receive_timeout => {
            try require(ownership.terminal_records == 2);
            try require(ownership.completed_records == 2);
            try require(ownership.cancelled_records == 0);
        },
        .concurrent_queued_full_request_timeout => {
            try require(ownership.terminal_records == 2);
            try require(ownership.completed_records == 1);
            try require(ownership.cancelled_records == 1);
        },
        .concurrent_drain => {
            try require(ownership.terminal_records == 0);
            try require(ownership.completed_records == 0);
            try require(ownership.cancelled_records == 0);
        },
        .concurrent_stale_owner_failure => {
            try require(ownership.terminal_records == 1);
            try require(ownership.completed_records == 0);
            try require(ownership.cancelled_records == 1);
        },
        else => unreachable,
    }
}

fn connectReadyPeer(ready: ReadyFrame) !std.net.Stream {
    const address = try std.net.Address.parseIp(
        loopback_host,
        ready.port,
    );
    return std.net.tcpConnectToAddress(address);
}

fn openModelsPeer(ready: ReadyFrame) !std.net.Stream {
    const peer = try connectReadyPeer(ready);
    errdefer peer.close();
    var storage: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &storage,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{
            protocol.models_path_v1,
            loopback_host,
            ready.port,
        },
    );
    try peer.writeAll(request);
    return peer;
}

fn openCompletionPeer(
    ready: ReadyFrame,
    tenant_key: u64,
    idempotency_key: []const u8,
) !std.net.Stream {
    const address = try std.net.Address.parseIp(
        loopback_host,
        ready.port,
    );
    const peer = try std.net.tcpConnectToAddress(address);
    errdefer peer.close();
    var body_storage: [protocol.request_body_max_bytes]u8 =
        undefined;
    const body = try protocol.encodeRequestV1(.{
        .model_id = &ready.model_id,
        .tenant_key = tenant_key,
        .idempotency_key = idempotency_key,
        .prompt_utf8 = prompt,
        .max_new_tokens = 1,
    }, &body_storage);
    var head_storage: [1024]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &head_storage,
        "POST {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "{s}: {s}\r\n" ++
            "{s}: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{
            protocol.completions_path_v1,
            loopback_host,
            ready.port,
            protocol.json_content_type,
            body.len,
            protocol.idempotency_header,
            idempotency_key,
            protocol.tenant_header,
            tenant_key,
        },
    );
    try peer.writeAll(head);
    try peer.writeAll(body);
    return peer;
}

fn setAbortiveReset(peer: std.net.Stream) !void {
    if (comptime builtin.os.tag == .windows) {
        const linger: std.os.windows.ws2_32.linger = .{
            .onoff = 1,
            .linger = 0,
        };
        try std.posix.setsockopt(
            peer.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.LINGER,
            std.mem.asBytes(&linger),
        );
    } else {
        const Linger = extern struct {
            l_onoff: c_int,
            l_linger: c_int,
        };
        const linger: Linger = .{
            .l_onoff = 1,
            .l_linger = 0,
        };
        try std.posix.setsockopt(
            peer.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.LINGER,
            std.mem.asBytes(&linger),
        );
    }
}

fn validatePhaseEActivity(
    activity: ActivityFrame,
    profile: WorkerProfile,
) !void {
    const peer: u64 = if (profile == .peer_reset_work) 1 else 0;
    const response: u64 =
        if (profile == .drain_response_ready) 1 else 0;
    const response_write: u64 =
        if (profile == .drain_response_writing) 1 else 0;
    const full_request_timeout: u64 =
        if (profile.isFullRequestTimeout()) 1 else 0;
    const full_request_timeout_work: u64 =
        if (profile == .full_request_timeout_request_admitted)
            1
        else
            0;
    const full_request_timeout_response: u64 =
        if (profile == .full_request_timeout_response_ready)
            1
        else
            0;
    const full_request_timeout_response_write: u64 =
        if (profile == .full_request_timeout_response_writing)
            1
        else
            0;
    const peer_phase: server_api.ManagedConnectionPhaseV1 =
        if (peer == 1) .request_admitted else .none;
    const response_phase: server_api.ManagedConnectionPhaseV1 =
        if (response == 1) .response_ready else .none;
    const response_write_phase: server_api.ManagedConnectionPhaseV1 =
        if (response_write == 1) .response_writing else .none;
    const full_request_timeout_phase =
        profile.fullRequestTimeoutPhase() orelse .none;
    const full_request_timeout_work_phase: server_api.ManagedConnectionPhaseV1 =
        if (full_request_timeout_work == 1)
            .request_admitted
        else
            .none;
    const full_request_timeout_response_phase: server_api.ManagedConnectionPhaseV1 =
        if (full_request_timeout_response == 1)
            .response_ready
        else
            .none;
    const full_request_timeout_response_write_phase: server_api.ManagedConnectionPhaseV1 =
        if (full_request_timeout_response_write == 1)
            .response_writing
        else
            .none;
    try require(activity.peer_reset == peer);
    try require(activity.peer_reset_cancelled_work == peer);
    try require(activity.last_peer_reset_phase == peer_phase);
    try require(
        activity.last_peer_reset_cancelled_work_phase ==
            peer_phase,
    );
    try require(activity.drain_cancelled_response == response);
    try require(
        activity.last_drain_cancelled_response_phase ==
            response_phase,
    );
    try require(
        activity.drain_requested_response_write ==
            response_write,
    );
    try require(
        activity.last_drain_requested_response_write_phase ==
            response_write_phase,
    );
    try require(
        activity.drain_cancelled_response_write ==
            response_write,
    );
    try require(
        activity.last_drain_cancelled_response_write_phase ==
            response_write_phase,
    );
    try require(
        activity.full_request_timeout_signaled ==
            full_request_timeout,
    );
    try require(
        activity.last_full_request_timeout_signaled_phase ==
            full_request_timeout_phase,
    );
    try require(
        activity.full_request_timeout_cancelled_work ==
            full_request_timeout_work,
    );
    try require(
        activity.last_full_request_timeout_cancelled_work_phase ==
            full_request_timeout_work_phase,
    );
    try require(
        activity.full_request_timeout_cancelled_response ==
            full_request_timeout_response,
    );
    try require(
        activity.last_full_request_timeout_cancelled_response_phase ==
            full_request_timeout_response_phase,
    );
    try require(
        activity.full_request_timeout_requested_response_write ==
            full_request_timeout_response_write,
    );
    try require(
        activity.last_full_request_timeout_requested_response_write_phase ==
            full_request_timeout_response_write_phase,
    );
    try require(
        activity.full_request_timeout_cancelled_response_write ==
            full_request_timeout_response_write,
    );
    try require(
        activity.last_full_request_timeout_cancelled_response_write_phase ==
            full_request_timeout_response_write_phase,
    );
    try require(activity.response_write_transport_failed == 0);
    try require(
        activity.last_response_write_transport_failed_phase ==
            .none,
    );
    const outcome: u8 = switch (profile) {
        .drain_response_ready,
        .full_request_timeout_response_ready,
        => responseOutcomeWire(.cancelled_before_write),
        .complete_response_ready, .complete_response_writing => responseOutcomeWire(.write_completed),
        .drain_response_writing,
        .full_request_timeout_response_writing,
        => responseOutcomeWire(.cancelled_during_write),
        else => 0,
    };
    try require(activity.response_outcome == outcome);
}

fn exerciseApplicationRejection(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
    generation: u64,
    oracle: LocalOracle,
) !void {
    var child = try spawnWorker(
        allocator,
        executable,
        fixture,
        generation,
        .application_rejection,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);
    var watchdog: WorkerWatchdog = .{
        .process_id = child.id,
    };
    try watchdog.start();
    var watchdog_running = true;
    defer if (watchdog_running) {
        _ = watchdog.stop();
    };

    var frame_storage: [frame_max_bytes]u8 = undefined;
    const ready = try parseReady(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try require(ready.generation == generation);
    var client = try http_client.ClientV1.initLoopback(
        allocator,
        loopback_host,
        ready.port,
    );
    defer client.deinit();

    const scheduler_request: protocol.RequestV1 = .{
        .model_id = &ready.model_id,
        .tenant_key = 73,
        .idempotency_key = "process-observer-scheduler",
        .prompt_utf8 = prompt,
        .max_new_tokens = 2,
        .deadline_tick = 1,
    };
    const scheduler_request_sha256 =
        try protocol.requestSha256V1(scheduler_request);
    const scheduler_error = try expectApiError(
        try client.completeV1(scheduler_request),
        .scheduler_rejected,
    );
    try require(
        scheduler_error.retry ==
            .same_request_after_backoff,
    );
    try require(scheduler_error.request_sha256 != null);
    try require(std.mem.eql(
        u8,
        &scheduler_request_sha256,
        &scheduler_error.request_sha256.?,
    ));

    const success_tenant: u64 = 79;
    const success_key = "process-observer-success";
    const success = try expectCompletion(
        try client.completeV1(.{
            .model_id = &ready.model_id,
            .tenant_key = success_tenant,
            .idempotency_key = success_key,
            .prompt_utf8 = prompt,
            .max_new_tokens = 1,
        }),
    );
    try validateCompletionAgainstOracle(
        success,
        ready,
        oracle,
        success_tenant,
        success_key,
    );

    const capacity_request: protocol.RequestV1 = .{
        .model_id = &ready.model_id,
        .tenant_key = 83,
        .idempotency_key = "process-observer-capacity",
        .prompt_utf8 = prompt,
        .max_new_tokens = 1,
    };
    const capacity_request_sha256 =
        try protocol.requestSha256V1(capacity_request);
    const capacity_error = try expectApiError(
        try client.completeV1(capacity_request),
        .service_capacity,
    );
    try require(
        capacity_error.retry ==
            .same_request_after_backoff,
    );
    try require(capacity_error.request_sha256 != null);
    try require(std.mem.eql(
        u8,
        &capacity_request_sha256,
        &capacity_error.request_sha256.?,
    ));

    const conflict_request: protocol.RequestV1 = .{
        .model_id = &ready.model_id,
        .tenant_key = success_tenant,
        .idempotency_key = success_key,
        .prompt_utf8 = "changed intent",
        .max_new_tokens = 1,
    };
    const conflict_request_sha256 =
        try protocol.requestSha256V1(conflict_request);
    const conflict_error = try expectApiError(
        try client.completeV1(conflict_request),
        .idempotency_conflict,
    );
    try require(conflict_error.request_sha256 != null);
    try require(std.mem.eql(
        u8,
        &conflict_request_sha256,
        &conflict_error.request_sha256.?,
    ));

    child.stdin.?.close();
    child.stdin = null;
    try expectCheckpointFrame(
        try readFrame(child.stdout.?, &frame_storage),
        "APPLICATION_REJECTION",
        generation,
    );
    const closed = try parseClosed(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try validateActivity(
        closed.activity,
        generation,
        4,
        4,
        0,
        0,
        .none,
        0,
        .none,
        0,
        .none,
    );
    try require(closed.service_active == 0);
    try require(closed.terminal_records == 1);
    try require(closed.bank_zero == 1);
    try requireWorkerEof(child.stdout.?);

    const did_time_out = watchdog.stop();
    watchdog_running = false;
    if (did_time_out) return error.WorkerTimeout;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| try require(code == 0),
        else => return error.UnexpectedWorkerTermination,
    }
}

fn exerciseWorker(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
    generation: u64,
    idempotency_key: []const u8,
    exercise_replay_and_disconnect: bool,
) !Observation {
    var child = try spawnWorker(
        allocator,
        executable,
        fixture,
        generation,
        .standard,
    );
    var waited = false;
    defer if (!waited) terminateChild(&child);
    var watchdog: WorkerWatchdog = .{
        .process_id = child.id,
    };
    try watchdog.start();
    var watchdog_running = true;
    defer if (watchdog_running) {
        _ = watchdog.stop();
    };

    var frame_storage: [frame_max_bytes]u8 = undefined;
    const ready = try parseReady(
        try readFrame(child.stdout.?, &frame_storage),
    );
    try require(ready.generation == generation);

    var client = try http_client.ClientV1.initLoopback(
        allocator,
        loopback_host,
        ready.port,
    );
    defer client.deinit();
    const models = try expectModels(
        try client.listModelsV1(),
    );
    try require(std.mem.eql(
        u8,
        &ready.model_id,
        &models.model_id,
    ));

    const request: protocol.RequestV1 = .{
        .model_id = &models.model_id,
        .tenant_key = 23,
        .idempotency_key = idempotency_key,
        .prompt_utf8 = prompt,
        .max_new_tokens = 1,
    };
    const completion = try expectCompletion(
        try client.completeV1(request),
    );
    if (exercise_replay_and_disconnect) {
        const replay = try expectCompletion(
            try client.completeV1(request),
        );
        try require(std.meta.eql(completion, replay));

        const malformed_address =
            try std.net.Address.parseIp(
                loopback_host,
                ready.port,
            );
        const malformed =
            try std.net.tcpConnectToAddress(malformed_address);
        malformed.close();
        const barrier_models = try expectModels(
            try client.listModelsV1(),
        );
        try require(std.meta.eql(models, barrier_models));
    }

    try child.stdin.?.writeAll(drain_command);
    child.stdin.?.close();
    child.stdin = null;

    const draining = try parseActivity(
        try readFrame(child.stdout.?, &frame_storage),
        "DRAINING",
    );
    const closed = try parseClosed(
        try readFrame(child.stdout.?, &frame_storage),
    );
    const expected_completed: u64 =
        if (exercise_replay_and_disconnect) 4 else 2;
    const expected_failed: u64 =
        if (exercise_replay_and_disconnect) 1 else 0;
    const expected_accepted =
        expected_completed + expected_failed;
    try validateActivity(
        draining,
        generation,
        expected_accepted,
        expected_completed,
        expected_failed,
        0,
        .none,
        0,
        .none,
        0,
        .none,
    );
    try validateActivity(
        closed.activity,
        generation,
        expected_accepted,
        expected_completed,
        expected_failed,
        0,
        .none,
        0,
        .none,
        0,
        .none,
    );
    try require(closed.service_active == 0);
    try require(closed.terminal_records == 1);
    try require(closed.bank_zero == 1);
    try requireWorkerEof(child.stdout.?);

    const did_time_out = watchdog.stop();
    watchdog_running = false;
    if (did_time_out) return error.WorkerTimeout;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| try require(code == 0),
        else => return error.UnexpectedWorkerTermination,
    }
    return .{
        .model_id = ready.model_id,
        .binding_sha256 = models.model_binding_sha256,
        .completion = completion,
    };
}

fn requireWorkerEof(stdout: std.fs.File) !void {
    var trailing: [1]u8 = undefined;
    if (try stdout.read(&trailing) != 0)
        return error.TrailingWorkerOutput;
}

fn spawnWorker(
    allocator: std.mem.Allocator,
    executable: []const u8,
    fixture: *const Fixture,
    generation: u64,
    profile: WorkerProfile,
) !std.process.Child {
    var generation_storage: [20]u8 = undefined;
    const generation_text = try std.fmt.bufPrint(
        &generation_storage,
        "{d}",
        .{generation},
    );
    var child = std.process.Child.init(
        &.{
            executable,
            worker_mode,
            fixture.prepared_path,
            fixture.package_path,
            fixture.license_path,
            generation_text,
            profile.wire(),
        },
        allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = if (profile == .native_load)
        .Inherit
    else
        .Ignore;
    try child.spawn();
    child.argv = &.{};
    return child;
}

fn terminateChild(child: *std.process.Child) void {
    if (child.stdin) |stdin| {
        stdin.close();
        child.stdin = null;
    }
    hardTerminateProcess(child.id);
    _ = child.wait() catch {};
}

fn validateActivity(
    activity: ActivityFrame,
    generation: u64,
    accepted: u64,
    completed: u64,
    failed: u64,
    drain_signaled: u64,
    last_drain_phase: server_api.ManagedConnectionPhaseV1,
    receive_timeout_signaled: u64,
    last_receive_timeout_phase: server_api.ManagedConnectionPhaseV1,
    drain_cancelled_work: u64,
    last_drain_cancelled_work_phase: server_api.ManagedConnectionPhaseV1,
) !void {
    try require(activity.generation == generation);
    try require(activity.accepted == accepted);
    try require(activity.completed == completed);
    try require(activity.failed == failed);
    try require(activity.active == 0);
    try require(activity.drain_signaled == drain_signaled);
    try require(
        activity.last_drain_phase == last_drain_phase,
    );
    try require(
        activity.receive_timeout_signaled ==
            receive_timeout_signaled,
    );
    try require(
        activity.last_receive_timeout_phase ==
            last_receive_timeout_phase,
    );
    try require(
        activity.drain_cancelled_work ==
            drain_cancelled_work,
    );
    try require(
        activity.last_drain_cancelled_work_phase ==
            last_drain_cancelled_work_phase,
    );
}

fn expectModels(
    result: http_client.ModelsResultV1,
) !protocol.ModelListV1 {
    return switch (result) {
        .ok => |models| models,
        .api_error => error.UnexpectedApiError,
    };
}

fn expectCompletion(
    result: http_client.CompletionResultV1,
) !protocol.CompletionV1 {
    return switch (result) {
        .ok => |completion| completion,
        .api_error => error.UnexpectedApiError,
    };
}

fn expectApiError(
    result: http_client.CompletionResultV1,
    expected: protocol.ErrorCodeV1,
) !protocol.ApiErrorV1 {
    return switch (result) {
        .ok => error.UnexpectedCompletion,
        .api_error => |api_error| {
            try require(api_error.code == expected);
            return api_error;
        },
    };
}

fn require(condition: bool) !void {
    if (!condition) return error.TestUnexpectedResult;
}
