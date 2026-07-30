const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const testing = std.testing;
const unary = engine.prepared_text_unary_service;
const protocol = engine.prepared_text_unary_http_v1;
const server = engine.prepared_text_unary_http_server;
const server_api = engine.server_api;
const client_api = engine.prepared_text_unary_http_client;

const fixture_license =
    "Glacier unary HTTP synthetic fixture\n";
const fixture_config =
    \\{"hidden_size":32,"intermediate_size":64,"num_hidden_layers":1,
    \\"vocab_size":256,"num_attention_heads":4,"num_key_value_heads":4,
    \\"rms_norm_eps":0.00001,"rope_theta":500000,
    \\"tie_word_embeddings":false}
    \\
;

fn pathInTmp(
    tmp: *testing.TmpDir,
    basename: []const u8,
) ![]u8 {
    const root = try tmp.dir.realpathAlloc(
        testing.allocator,
        ".",
    );
    defer testing.allocator.free(root);
    return std.fs.path.join(
        testing.allocator,
        &.{ root, basename },
    );
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const file = try std.fs.cwd().createFile(
        path,
        .{ .truncate = true },
    );
    defer file.close();
    try file.writeAll(contents);
}

const ModelFixture = struct {
    tmp: testing.TmpDir,
    source_path: []u8,
    portable_path: []u8,
    prepared_path: []u8,
    package_path: []u8,
    config_path: []u8,
    license_path: []u8,
    model: engine.loader.LoadedModel,
    bundle: engine.model_package_manifest.AdmissionBundleV2,

    fn init() !ModelFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const source_path = try pathInTmp(
            &tmp,
            "unary-http.safetensors",
        );
        errdefer testing.allocator.free(source_path);
        const portable_path = try pathInTmp(
            &tmp,
            "unary-http.glacier",
        );
        errdefer testing.allocator.free(portable_path);
        const prepared_path = try pathInTmp(
            &tmp,
            "unary-http.glrt",
        );
        errdefer testing.allocator.free(prepared_path);
        const package_path = try pathInTmp(
            &tmp,
            "unary-http.glpkg",
        );
        errdefer testing.allocator.free(package_path);
        const config_path = try pathInTmp(
            &tmp,
            "unary-http-config.json",
        );
        errdefer testing.allocator.free(config_path);
        const license_path = try pathInTmp(
            &tmp,
            "unary-http-license.txt",
        );
        errdefer testing.allocator.free(license_path);

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
                testing.allocator,
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
        var model = try engine.loader.loadPreparedWithOptions(
            testing.allocator,
            prepared_path,
            .{
                .expected_source_fingerprint = produced.package.model_content_sha256,
                .mlp_layout = .separate_required,
            },
        );
        errdefer model.deinit();

        return .{
            .tmp = tmp,
            .source_path = source_path,
            .portable_path = portable_path,
            .prepared_path = prepared_path,
            .package_path = package_path,
            .config_path = config_path,
            .license_path = license_path,
            .model = model,
            .bundle = .{
                .package = produced.package,
                .representation = produced.representation,
            },
        };
    }

    fn deinit(self: *ModelFixture) void {
        self.model.deinit();
        testing.allocator.free(self.license_path);
        testing.allocator.free(self.config_path);
        testing.allocator.free(self.package_path);
        testing.allocator.free(self.prepared_path);
        testing.allocator.free(self.portable_path);
        testing.allocator.free(self.source_path);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn bind(self: *ModelFixture) !unary.ModelBindingV1 {
        return unary.bindModelV1(
            &self.model,
            self.bundle,
            fixture_license.len,
            engine.core.model_contract.sha256(
                fixture_license,
            ),
        );
    }
};

fn ServiceHarness(
    comptime active_capacity: usize,
    comptime record_capacity: usize,
) type {
    return struct {
        bank_slots: [active_capacity]engine.resource_bank.Slot =
            [_]engine.resource_bank.Slot{.{}} **
            active_capacity,
        lane_slots: [active_capacity]engine.lane_weave_qos.Slot =
            [_]engine.lane_weave_qos.Slot{.{}} **
            active_capacity,
        projection: [active_capacity]engine.lane_weave_qos.ProjectionSlot =
            [_]engine.lane_weave_qos.ProjectionSlot{.{}} **
            active_capacity,
        active: [active_capacity]unary.ActiveSlotV1 =
            [_]unary.ActiveSlotV1{.{}} **
            active_capacity,
        records: [record_capacity]unary.RecordSlotV1 =
            [_]unary.RecordSlotV1{.{}} **
            record_capacity,
        bank: engine.resource_bank.Bank = undefined,
        scheduler: engine.lane_weave_qos.Scheduler = undefined,
        service: unary.ServiceV1 = .{},

        fn init(
            self: *@This(),
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
                            "unary HTTP scheduler challenge",
                        ),
                        .max_weight = 1,
                    },
                );
            try self.service.init(
                testing.allocator,
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

fn oracleTokens(
    fixture: *ModelFixture,
    prompt_utf8: []const u8,
    max_new_tokens: usize,
) ![]u32 {
    const manifest =
        try engine.tokenizer.makeUtf8ByteManifestV1(
            @intCast(fixture.model.config.vocab_size),
            engine.tokenizer.utf8_byte_max_input_bytes,
        );
    var tokenized =
        try engine.tokenizer.tokenizeUtf8BytesV1(
            testing.allocator,
            manifest,
            prompt_utf8,
        );
    defer tokenized.deinit();
    return engine.generate.generate(
        testing.allocator,
        fixture.model,
        tokenized.tokens,
        (engine.prepared_text_session.OptionsV1{
            .max_new_tokens = max_new_tokens,
        }).generateOptions(),
    );
}

const LoopbackServer = struct {
    listener: std.net.Server = undefined,
    runtime: *server.RuntimeV1 = undefined,
    request_count: u64 = 0,
    lifecycle: ?*server_api.ManagedLifecycleV1 = null,
    work_observer: ?server.RequestWorkControlV1 = null,
    thread: ?std.Thread = null,
    thread_error: ?anyerror = null,
    listener_open: bool = false,

    fn start(
        self: *LoopbackServer,
        runtime: *server.RuntimeV1,
        request_count: u64,
    ) !void {
        return self.startWithControls(
            runtime,
            request_count,
            null,
            null,
        );
    }

    fn startManaged(
        self: *LoopbackServer,
        runtime: *server.RuntimeV1,
        request_count: u64,
        lifecycle: *server_api.ManagedLifecycleV1,
        work_observer: server.RequestWorkControlV1,
    ) !void {
        return self.startWithControls(
            runtime,
            request_count,
            lifecycle,
            work_observer,
        );
    }

    fn startWithControls(
        self: *LoopbackServer,
        runtime: *server.RuntimeV1,
        request_count: u64,
        lifecycle: ?*server_api.ManagedLifecycleV1,
        work_observer: ?server.RequestWorkControlV1,
    ) !void {
        if (request_count == 0)
            return error.TestUnexpectedResult;
        const address = try std.net.Address.parseIp(
            "127.0.0.1",
            0,
        );
        self.listener = try address.listen(.{
            .reuse_address = true,
        });
        self.listener_open = true;
        self.runtime = runtime;
        self.request_count = request_count;
        self.lifecycle = lifecycle;
        self.work_observer = work_observer;
        self.thread = std.Thread.spawn(
            .{},
            run,
            .{self},
        ) catch |err| {
            self.listener.deinit();
            self.listener_open = false;
            return err;
        };
    }

    fn run(self: *LoopbackServer) void {
        if (self.lifecycle) |lifecycle| {
            engine.server_api.serveManagedListenerWithWorkObserverV1(
                &self.listener,
                .{ .stop_after_requests = self.request_count },
                self.runtime,
                lifecycle,
                self.work_observer,
            ) catch |err| {
                self.thread_error = err;
            };
        } else {
            engine.server_api.serveListenerV1(
                &self.listener,
                .{ .stop_after_requests = self.request_count },
                self.runtime,
            ) catch |err| {
                self.thread_error = err;
            };
        }
    }

    fn port(self: *const LoopbackServer) u16 {
        return self.listener.listen_address.getPort();
    }

    fn finish(self: *LoopbackServer) !void {
        const thread = self.thread orelse
            return error.TestUnexpectedResult;
        thread.join();
        self.thread = null;
        self.listener.deinit();
        self.listener_open = false;
        if (self.thread_error) |err| return err;
    }

    fn deinit(self: *LoopbackServer) void {
        if (self.thread) |thread| {
            if (self.listener_open) {
                var wake_count: u64 = 0;
                while (wake_count < self.request_count) : (wake_count += 1) {
                    const wake =
                        std.net.tcpConnectToAddress(
                            self.listener.listen_address,
                        ) catch break;
                    wake.close();
                }
            }
            thread.join();
            self.thread = null;
        }
        if (self.listener_open) {
            self.listener.deinit();
            self.listener_open = false;
        }
    }
};

const AdmissionObservationLogV1 = struct {
    mutex: std.Thread.Mutex = .{},
    rejections: [2]server.RequestAdmissionRejectionV1 =
        undefined,
    rejection_count: usize = 0,
    admitted_count: usize = 0,
    retired_count: usize = 0,
    overflowed: bool = false,

    fn admittedOpaque(
        context: *anyopaque,
        identity: server.WorkIdentityV1,
    ) anyerror!server.WorkDispositionV1 {
        const self: *AdmissionObservationLogV1 =
            @ptrCast(@alignCast(context));
        _ = identity;
        self.mutex.lock();
        self.admitted_count += 1;
        self.mutex.unlock();
        return .proceed;
    }

    fn rejectedOpaque(
        context: *anyopaque,
        rejection: server.RequestAdmissionRejectionV1,
    ) void {
        const self: *AdmissionObservationLogV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        if (self.rejection_count == self.rejections.len) {
            self.overflowed = true;
        } else {
            self.rejections[self.rejection_count] = rejection;
            self.rejection_count += 1;
        }
        self.mutex.unlock();
    }

    fn retiredOpaque(
        context: *anyopaque,
        identity: server.WorkIdentityV1,
    ) void {
        const self: *AdmissionObservationLogV1 =
            @ptrCast(@alignCast(context));
        _ = identity;
        self.mutex.lock();
        self.retired_count += 1;
        self.mutex.unlock();
    }

    fn control(
        self: *AdmissionObservationLogV1,
    ) server.RequestWorkControlV1 {
        return .{
            .context = self,
            .admitted_fn = admittedOpaque,
            .retired_fn = retiredOpaque,
            .transport_owner = .{
                .process_generation = 1,
                .connection_sequence = 2,
                .slot_index = 3,
                .slot_generation = 4,
            },
            .admission_rejected_fn = rejectedOpaque,
        };
    }

    fn rejectionAt(
        self: *AdmissionObservationLogV1,
        index: usize,
    ) !server.RequestAdmissionRejectionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.overflowed)
            return error.AdmissionObservationOverflow;
        if (index >= self.rejection_count)
            return error.MissingAdmissionObservation;
        return self.rejections[index];
    }

    fn expectCounts(
        self: *AdmissionObservationLogV1,
        admitted: usize,
        rejected: usize,
        retired: usize,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try testing.expect(!self.overflowed);
        try testing.expectEqual(admitted, self.admitted_count);
        try testing.expectEqual(rejected, self.rejection_count);
        try testing.expectEqual(retired, self.retired_count);
    }
};

const concurrent_test_watchdog_ns: u64 =
    10 * std.time.ns_per_s;
const concurrent_test_event_capacity: usize = 128;
const raw_models_request =
    "GET /v1/models HTTP/1.1\r\n" ++
    "Host: 127.0.0.1\r\n" ++
    "Connection: close\r\n\r\n";

fn waitForConcurrentTestEvent(
    event: *std.Thread.ResetEvent,
) !void {
    event.timedWait(concurrent_test_watchdog_ns) catch
        return error.ConcurrentTestTimedOut;
}

const ConcurrentEventLog = struct {
    mutex: std.Thread.Mutex = .{},
    changed: std.Thread.Condition = .{},
    events: [concurrent_test_event_capacity]server_api.ManagedConcurrentEventV1 = undefined,
    event_count: usize = 0,
    overflowed: bool = false,
    block_first_dispatch: bool = false,
    block_first_enqueued_until_dispatch: bool = false,
    enqueued_count: usize = 0,
    dispatch_count: usize = 0,
    first_dispatch_reached: std.Thread.ResetEvent = .{},
    first_dispatch_release: std.Thread.ResetEvent = .{},
    first_enqueued_callback_reached: std.Thread.ResetEvent = .{},
    first_inverted_dispatch_completed: std.Thread.ResetEvent = .{},
    inverted_callback_wait_failed: bool = false,

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
        var should_block_dispatch = false;
        var should_block_enqueued = false;
        var should_wait_for_enqueued = false;
        self.mutex.lock();
        if (event.kind == .enqueued) {
            self.enqueued_count += 1;
            should_block_enqueued =
                self.block_first_enqueued_until_dispatch and
                self.enqueued_count == 1;
        }
        if (event.kind == .dispatched) {
            self.dispatch_count += 1;
            should_block_dispatch =
                self.block_first_dispatch and
                self.dispatch_count == 1;
            should_wait_for_enqueued =
                self.block_first_enqueued_until_dispatch and
                self.dispatch_count == 1;
        }
        if (should_block_enqueued or should_wait_for_enqueued) {
            self.mutex.unlock();
            if (should_block_enqueued) {
                self.first_enqueued_callback_reached.set();
                self.first_inverted_dispatch_completed.timedWait(
                    concurrent_test_watchdog_ns,
                ) catch {
                    self.mutex.lock();
                    self.inverted_callback_wait_failed = true;
                    self.changed.broadcast();
                    self.mutex.unlock();
                };
            } else {
                self.first_enqueued_callback_reached.timedWait(
                    concurrent_test_watchdog_ns,
                ) catch {
                    self.mutex.lock();
                    self.inverted_callback_wait_failed = true;
                    self.changed.broadcast();
                    self.mutex.unlock();
                };
            }
            self.mutex.lock();
        }

        if (self.event_count == self.events.len) {
            self.overflowed = true;
        } else {
            self.events[self.event_count] = event;
            self.event_count += 1;
        }
        self.changed.broadcast();
        self.mutex.unlock();

        if (should_wait_for_enqueued) {
            self.first_inverted_dispatch_completed.set();
        }
        if (should_block_dispatch) {
            self.first_dispatch_reached.set();
            self.first_dispatch_release.wait();
        }
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
            if (elapsed_ns >= concurrent_test_watchdog_ns)
                return error.ConcurrentEventTimedOut;
            self.changed.timedWait(
                &self.mutex,
                concurrent_test_watchdog_ns - elapsed_ns,
            ) catch return error.ConcurrentEventTimedOut;
        }
    }

    fn waitForKindAfterOrdinal(
        self: *ConcurrentEventLog,
        kind: server_api.ManagedConcurrentEventKindV1,
        after_ordinal: u64,
    ) !server_api.ManagedConcurrentEventV1 {
        var timer = try std.time.Timer.start();
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.overflowed)
                return error.ConcurrentEventLogOverflow;
            var selected: ?server_api.ManagedConcurrentEventV1 = null;
            for (self.events[0..self.event_count]) |event| {
                if (event.kind != kind or
                    event.ordinal <= after_ordinal)
                {
                    continue;
                }
                if (selected == null or
                    event.ordinal < selected.?.ordinal)
                {
                    selected = event;
                }
            }
            if (selected) |event| return event;
            const elapsed_ns = timer.read();
            if (elapsed_ns >= concurrent_test_watchdog_ns)
                return error.ConcurrentEventTimedOut;
            self.changed.timedWait(
                &self.mutex,
                concurrent_test_watchdog_ns - elapsed_ns,
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

    fn copyKind(
        self: *ConcurrentEventLog,
        kind: server_api.ManagedConcurrentEventKindV1,
        destination: []server_api.ManagedConcurrentEventV1,
    ) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.overflowed)
            return error.ConcurrentEventLogOverflow;
        var copied: usize = 0;
        for (self.events[0..self.event_count]) |event| {
            if (event.kind != kind) continue;
            if (copied == destination.len)
                return error.ConcurrentEventDestinationTooSmall;
            destination[copied] = event;
            copied += 1;
        }
        return copied;
    }

    fn totalCount(self: *ConcurrentEventLog) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.overflowed)
            return error.ConcurrentEventLogOverflow;
        return self.event_count;
    }

    fn firstIndexOfKind(
        self: *ConcurrentEventLog,
        kind: server_api.ManagedConcurrentEventKindV1,
    ) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.overflowed)
            return error.ConcurrentEventLogOverflow;
        for (self.events[0..self.event_count], 0..) |event, index| {
            if (event.kind == kind) return index;
        }
        return error.ConcurrentEventKindNotObserved;
    }

    fn waitForFirstDispatch(self: *ConcurrentEventLog) !void {
        try waitForConcurrentTestEvent(
            &self.first_dispatch_reached,
        );
    }

    fn releaseFirstDispatch(self: *ConcurrentEventLog) void {
        self.first_dispatch_release.set();
    }

    fn waitForFirstEnqueuedCallback(self: *ConcurrentEventLog) !void {
        try waitForConcurrentTestEvent(
            &self.first_enqueued_callback_reached,
        );
    }

    fn waitForFirstInvertedDispatch(self: *ConcurrentEventLog) !void {
        try waitForConcurrentTestEvent(
            &self.first_inverted_dispatch_completed,
        );
    }

    fn expectNoInvertedCallbackWaitFailure(
        self: *ConcurrentEventLog,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try testing.expect(!self.inverted_callback_wait_failed);
    }

    fn releaseInvertedCallbackBarrier(
        self: *ConcurrentEventLog,
    ) void {
        self.first_enqueued_callback_reached.set();
        self.first_inverted_dispatch_completed.set();
    }
};

fn sortConcurrentEventsByOrdinal(
    events: []server_api.ManagedConcurrentEventV1,
) void {
    var index: usize = 1;
    while (index < events.len) : (index += 1) {
        const selected = events[index];
        var insertion = index;
        while (insertion != 0 and
            events[insertion - 1].ordinal > selected.ordinal)
        {
            events[insertion] = events[insertion - 1];
            insertion -= 1;
        }
        events[insertion] = selected;
    }
}

const ConcurrentServerHarness = struct {
    listener: std.net.Server = undefined,
    runtime: *server.RuntimeV1 = undefined,
    lifecycle: *server_api.ManagedConcurrentLifecycleV1 =
        undefined,
    config: server_api.ServerConfig = .{},
    observer: ?server_api.ManagedConcurrentObserverV1 = null,
    thread: ?std.Thread = null,
    thread_error: ?anyerror = null,
    done: std.Thread.ResetEvent = .{},
    listener_open: bool = false,

    fn start(
        self: *ConcurrentServerHarness,
        runtime: *server.RuntimeV1,
        lifecycle: *server_api.ManagedConcurrentLifecycleV1,
        config: server_api.ServerConfig,
        observer: ?server_api.ManagedConcurrentObserverV1,
    ) !void {
        const bind_address = try std.net.Address.parseIp(
            "127.0.0.1",
            0,
        );
        self.listener = try bind_address.listen(.{
            .reuse_address = true,
        });
        self.listener_open = true;
        self.runtime = runtime;
        self.lifecycle = lifecycle;
        self.config = config;
        self.observer = observer;
        self.thread = std.Thread.spawn(
            .{},
            run,
            .{self},
        ) catch |err| {
            self.listener.deinit();
            self.listener_open = false;
            return err;
        };
    }

    fn run(self: *ConcurrentServerHarness) void {
        defer self.done.set();
        server_api
            .serveManagedConcurrentListenerWithObserverV1(
            &self.listener,
            self.config,
            self.runtime,
            self.lifecycle,
            self.observer,
        ) catch |err| {
            self.thread_error = err;
        };
    }

    fn address(
        self: *const ConcurrentServerHarness,
    ) std.net.Address {
        return self.listener.listen_address;
    }

    fn port(self: *const ConcurrentServerHarness) u16 {
        return self.listener.listen_address.getPort();
    }

    fn drain(self: *ConcurrentServerHarness) !void {
        try server_api.requestManagedConcurrentDrainAndWakeV1(
            self.lifecycle,
            self.runtime,
            self.listener.listen_address,
        );
    }

    fn finish(self: *ConcurrentServerHarness) !void {
        try waitForConcurrentTestEvent(&self.done);
        const thread = self.thread orelse
            return error.ConcurrentServerNotRunning;
        thread.join();
        self.thread = null;
        self.listener.deinit();
        self.listener_open = false;
        if (self.thread_error) |err| return err;
    }

    fn deinit(self: *ConcurrentServerHarness) void {
        if (self.thread) |thread| {
            server_api
                .requestManagedConcurrentDrainAndWakeV1(
                self.lifecycle,
                self.runtime,
                self.listener.listen_address,
            ) catch {
                _ = server.beginDrainV1(self.runtime) catch {};
                const wake = std.net.tcpConnectToAddress(
                    self.listener.listen_address,
                ) catch null;
                if (wake) |stream| stream.close();
            };
            thread.join();
            self.thread = null;
        }
        if (self.listener_open) {
            self.listener.deinit();
            self.listener_open = false;
        }
    }
};

const ModelsCall = struct {
    port: u16 = 0,
    done: std.Thread.ResetEvent = .{},
    model_id: ?[protocol.model_id_bytes]u8 = null,
    thread: ?std.Thread = null,
    thread_error: ?anyerror = null,

    fn start(self: *ModelsCall, port: u16) !void {
        self.port = port;
        self.thread = try std.Thread.spawn(
            .{},
            run,
            .{self},
        );
    }

    fn run(self: *ModelsCall) void {
        defer self.done.set();
        self.runFallible() catch |err| {
            self.thread_error = err;
        };
    }

    fn runFallible(self: *ModelsCall) !void {
        var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        var client = try client_api.ClientV1.initLoopback(
            gpa.allocator(),
            "127.0.0.1",
            self.port,
        );
        defer client.deinit();
        const models = try expectModels(
            try client.listModelsV1(),
        );
        self.model_id = models.model_id;
    }

    fn finish(
        self: *ModelsCall,
        expected_model_id: *const [protocol.model_id_bytes]u8,
    ) !void {
        try waitForConcurrentTestEvent(&self.done);
        const thread = self.thread orelse
            return error.ModelsCallNotRunning;
        thread.join();
        self.thread = null;
        if (self.thread_error) |err| return err;
        const actual_model_id = self.model_id orelse
            return error.ModelsCallMissingResult;
        try testing.expectEqualSlices(
            u8,
            expected_model_id,
            &actual_model_id,
        );
    }

    fn deinit(self: *ModelsCall) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
};

fn openRawLoopbackPeer(port: u16) !std.net.Stream {
    return std.net.tcpConnectToAddress(
        try std.net.Address.parseIp(
            "127.0.0.1",
            port,
        ),
    );
}

fn writeRawModelsRequest(peer: std.net.Stream) !void {
    try peer.writeAll(raw_models_request);
}

fn writeRawPartialModelsHead(peer: std.net.Stream) !void {
    try peer.writeAll(
        "GET /v1/models HTTP/1.1\r\n" ++
            "Host: 127.0.0.1",
    );
}

fn waitRawPeerReadable(
    handle: std.net.Stream.Handle,
    timer: *std.time.Timer,
) !void {
    while (true) {
        const elapsed_ns = timer.read();
        if (elapsed_ns >= concurrent_test_watchdog_ns)
            return error.ConcurrentPeerReadTimedOut;
        const remaining_ns =
            concurrent_test_watchdog_ns - elapsed_ns;
        const remaining_ms: i32 = @intCast(
            std.math.divCeil(
                u64,
                remaining_ns,
                std.time.ns_per_ms,
            ) catch unreachable,
        );
        const ready = if (builtin.os.tag == .windows) blk: {
            var descriptors = [_]std.posix.pollfd{.{
                .fd = handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            break :blk try std.posix.poll(
                &descriptors,
                remaining_ms,
            ) != 0;
        } else blk: {
            var descriptors = [_]std.c.pollfd{.{
                .fd = handle,
                .events = std.c.POLL.IN,
                .revents = 0,
            }};
            const result = std.c.poll(
                &descriptors,
                @intCast(descriptors.len),
                remaining_ms,
            );
            break :blk switch (std.posix.errno(result)) {
                .SUCCESS => result != 0,
                .INTR => false,
                .NOMEM => return error.SystemResources,
                else => return error.ConcurrentPeerPollFailed,
            };
        };
        if (ready) return;
    }
}

fn expectRawPeerEofWithoutResponse(
    peer: std.net.Stream,
) !void {
    var timer = try std.time.Timer.start();
    try waitRawPeerReadable(peer.handle, &timer);
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
        return error.UnexpectedConcurrentHttpResponse;
}

fn expectRawModelsResponse(
    peer: std.net.Stream,
    expected_model_id: *const [protocol.model_id_bytes]u8,
) !void {
    var timer = try std.time.Timer.start();
    var response: [
        protocol.header_max_bytes +
            protocol.response_body_max_bytes
    ]u8 = undefined;
    var used: usize = 0;
    while (used < response.len) {
        try waitRawPeerReadable(peer.handle, &timer);
        const read_count =
            peer.read(response[used..]) catch |read_error| {
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
    if (used == response.len)
        return error.ConcurrentHttpResponseTooLarge;
    const header_end = std.mem.indexOf(
        u8,
        response[0..used],
        "\r\n\r\n",
    ) orelse return error.ConcurrentHttpResponseMissingHead;
    try testing.expect(std.mem.startsWith(
        u8,
        response[0..header_end],
        "HTTP/1.1 200",
    ));
    var parser_workspace: [protocol.parser_workspace_bytes]u8 = undefined;
    var parser = std.heap.FixedBufferAllocator.init(
        &parser_workspace,
    );
    const models = try protocol.decodeModelListV1(
        parser.allocator(),
        response[header_end + 4 .. used],
    );
    try testing.expectEqualSlices(
        u8,
        expected_model_id,
        &models.model_id,
    );
}

fn expectConcurrentSnapshotConservation(
    snapshot: server_api.ManagedConcurrentSnapshotV1,
) !void {
    try testing.expectEqual(
        snapshot.managed.accepted_connections,
        snapshot.managed.completed_connections +
            snapshot.managed.failed_connections +
            snapshot.managed.active_connections,
    );
    try testing.expectEqual(
        snapshot.managed.active_connections,
        snapshot.running_connections +
            snapshot.managed.queued_connections,
    );
    try testing.expectEqual(
        snapshot.managed.queued_connections,
        snapshot.phase_counts.queued,
    );
    const phase_total: u16 =
        @as(u16, snapshot.phase_counts.queued) +
        @as(u16, snapshot.phase_counts.receiving_head) +
        @as(u16, snapshot.phase_counts.request_head_received) +
        @as(u16, snapshot.phase_counts.request_received) +
        @as(u16, snapshot.phase_counts.request_admitted) +
        @as(u16, snapshot.phase_counts.response_ready) +
        @as(u16, snapshot.phase_counts.response_writing) +
        @as(u16, snapshot.phase_counts.response_written);
    try testing.expectEqual(
        @as(u16, snapshot.managed.active_connections),
        phase_total,
    );
    try testing.expectEqual(
        snapshot.queue_enqueued_connections,
        snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        snapshot.queue_enqueued_connections,
        snapshot.queue_dispatched_connections +
            snapshot.drain_cancelled_queued_connections +
            snapshot.failure_cancelled_queued_connections +
            snapshot.receive_timeout_queued_connections +
            snapshot.full_request_timeout_queued_connections +
            snapshot.managed.queued_connections,
    );
    try testing.expect(
        snapshot.queue_high_watermark <=
            snapshot.pending_connection_capacity,
    );
    try testing.expect(
        snapshot.running_high_watermark <=
            snapshot.worker_count,
    );
    try testing.expect(
        snapshot.listener_backpressure_resumptions <=
            snapshot.listener_backpressure_activations,
    );
}

fn expectBackpressureTransitionsAreExact(
    event_log: *ConcurrentEventLog,
) !void {
    var transitions: [concurrent_test_event_capacity]server_api.ManagedConcurrentEventV1 = undefined;
    var transition_count: usize = 0;
    transition_count += try event_log.copyKind(
        .backpressure_paused,
        transitions[transition_count..],
    );
    transition_count += try event_log.copyKind(
        .backpressure_resumed,
        transitions[transition_count..],
    );
    sortConcurrentEventsByOrdinal(
        transitions[0..transition_count],
    );
    var paused = false;
    for (transitions[0..transition_count]) |event| {
        switch (event.kind) {
            .backpressure_paused => {
                try testing.expect(!paused);
                try testing.expectEqual(
                    @as(u8, 1),
                    event.queued_connections,
                );
                paused = true;
            },
            .backpressure_resumed => {
                try testing.expect(paused);
                paused = false;
            },
            else => unreachable,
        }
    }
    try testing.expect(!paused);
}

fn expectModelOnlyServiceCleanup(
    service: *unary.ServiceV1,
) !void {
    const snapshot = try service.snapshotV1();
    try testing.expectEqual(
        @as(u32, 0),
        snapshot.active_requests,
    );
    try testing.expectEqual(
        @as(u32, 0),
        snapshot.terminal_records,
    );
    try testing.expect(snapshot.bank.?.used.isZero());
    const close = try service.closeV1();
    try testing.expectEqual(
        @as(u32, 0),
        close.terminal_records,
    );
    try testing.expect(close.bank_snapshot.used.isZero());
}

const ConcurrentDrainCall = struct {
    lifecycle: *server_api.ManagedConcurrentLifecycleV1,
    runtime: *server.RuntimeV1,
    listen_address: std.net.Address,
    start: *std.Thread.ResetEvent,
    done: std.Thread.ResetEvent = .{},
    thread_error: ?anyerror = null,

    fn run(self: *ConcurrentDrainCall) void {
        self.start.wait();
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

fn expectModels(
    result: client_api.ModelsResultV1,
) !protocol.ModelListV1 {
    return switch (result) {
        .ok => |models| models,
        .api_error => error.TestUnexpectedResult,
    };
}

fn expectCompletion(
    result: client_api.CompletionResultV1,
) !protocol.CompletionV1 {
    return switch (result) {
        .ok => |completion| completion,
        .api_error => error.TestUnexpectedResult,
    };
}

fn expectApiError(
    result: client_api.CompletionResultV1,
    expected: protocol.ErrorCodeV1,
) !protocol.ApiErrorV1 {
    return switch (result) {
        .ok => error.TestUnexpectedResult,
        .api_error => |api_error| {
            try testing.expectEqual(expected, api_error.code);
            return api_error;
        },
    };
}

// A: one worker remains live while its sibling owns a partial HTTP head.
fn runConcurrentSiblingLivenessScenario(
    binding: unary.ModelBindingV1,
) !void {
    var service_harness: ServiceHarness(1, 1) = .{};
    try service_harness.init(
        binding,
        0x4854_5450_4641,
    );
    var service_closed = false;
    defer if (!service_closed) {
        _ = service_harness.service.closeV1() catch {};
    };

    var runtime = try server.initV1(
        &service_harness.service,
        binding.binding_sha256,
    );
    var lifecycle =
        try server_api.ManagedConcurrentLifecycleV1.initV1(
            0x4641_0000_0000_0001,
            .{
                .worker_count = 2,
                .pending_connection_capacity = 2,
            },
        );
    try lifecycle.markReadyV1();
    var event_log: ConcurrentEventLog = .{};
    var transport: ConcurrentServerHarness = .{};
    var models_call: ModelsCall = .{};
    var partial_peer: ?std.net.Stream = null;
    try transport.start(
        &runtime,
        &lifecycle,
        .{},
        event_log.observer(),
    );
    defer {
        event_log.releaseFirstDispatch();
        transport.deinit();
        models_call.deinit();
        if (partial_peer) |peer| peer.close();
    }

    partial_peer = try openRawLoopbackPeer(
        transport.port(),
    );
    try writeRawPartialModelsHead(partial_peer.?);
    const first_dispatch =
        try event_log.waitForKind(.dispatched, 1);
    try testing.expectEqual(
        @as(u64, 1),
        first_dispatch.lease.?.connection_sequence,
    );
    const partial_snapshot = lifecycle.snapshotV1();
    try expectConcurrentSnapshotConservation(
        partial_snapshot,
    );
    try testing.expectEqual(
        @as(u64, 1),
        partial_snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        partial_snapshot.running_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        partial_snapshot.phase_counts.receiving_head,
    );

    try models_call.start(transport.port());
    try models_call.finish(&runtime.model_id);
    _ = try event_log.waitForKind(.retired, 1);
    const sibling_snapshot = lifecycle.snapshotV1();
    try expectConcurrentSnapshotConservation(
        sibling_snapshot,
    );
    try testing.expectEqual(
        @as(u64, 2),
        sibling_snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        sibling_snapshot.managed.completed_connections,
    );
    try testing.expectEqual(
        @as(u64, 0),
        sibling_snapshot.managed.failed_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        sibling_snapshot.managed.active_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        sibling_snapshot.phase_counts.receiving_head,
    );
    try testing.expectEqual(
        @as(u8, 2),
        sibling_snapshot.running_high_watermark,
    );

    partial_peer.?.close();
    partial_peer = null;
    _ = try event_log.waitForKind(.retired, 2);
    try transport.drain();
    try transport.finish();

    const final_snapshot = lifecycle.snapshotV1();
    try expectConcurrentSnapshotConservation(
        final_snapshot,
    );
    try testing.expectEqual(
        server_api.ManagedStateV1.stopped,
        final_snapshot.managed.state,
    );
    try testing.expectEqual(
        @as(u64, 2),
        final_snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot.managed.completed_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot.managed.failed_connections,
    );
    try testing.expectEqual(
        @as(u64, 2),
        final_snapshot.queue_enqueued_connections,
    );
    try testing.expectEqual(
        @as(u64, 2),
        final_snapshot.queue_dispatched_connections,
    );
    try testing.expectEqual(
        final_snapshot.event_ordinal,
        @as(u64, @intCast(try event_log.totalCount())),
    );
    try expectModelOnlyServiceCleanup(
        &service_harness.service,
    );
    service_closed = true;
}

// B: a one-worker/one-pending transport preserves FIFO under backpressure.
fn runConcurrentFifoBackpressureScenario(
    binding: unary.ModelBindingV1,
) !void {
    var failure_stage: []const u8 = "setup";
    errdefer std.log.err(
        "F1 scenario B stage: {s}",
        .{failure_stage},
    );
    var service_harness: ServiceHarness(1, 1) = .{};
    try service_harness.init(
        binding,
        0x4854_5450_4642,
    );
    var service_closed = false;
    defer if (!service_closed) {
        _ = service_harness.service.closeV1() catch {};
    };

    var runtime = try server.initV1(
        &service_harness.service,
        binding.binding_sha256,
    );
    var lifecycle =
        try server_api.ManagedConcurrentLifecycleV1.initV1(
            0x4642_0000_0000_0001,
            .{
                .worker_count = 1,
                .pending_connection_capacity = 1,
            },
        );
    try lifecycle.markReadyV1();
    var event_log: ConcurrentEventLog = .{
        .block_first_dispatch = true,
    };
    try testing.expect(
        !event_log.first_dispatch_release.isSet(),
    );
    var transport: ConcurrentServerHarness = .{};
    var first_models: ModelsCall = .{};
    var follow_up_models: ModelsCall = .{};
    var second_peer: ?std.net.Stream = null;
    var third_peer: ?std.net.Stream = null;
    try transport.start(
        &runtime,
        &lifecycle,
        .{},
        event_log.observer(),
    );
    defer {
        event_log.releaseFirstDispatch();
        transport.deinit();
        first_models.deinit();
        follow_up_models.deinit();
        if (second_peer) |peer| peer.close();
        if (third_peer) |peer| peer.close();
    }

    try first_models.start(transport.port());
    try event_log.waitForFirstDispatch();
    try testing.expect(
        !event_log.first_dispatch_release.isSet(),
    );
    const first_dispatch =
        try event_log.waitForKind(.dispatched, 1);
    failure_stage = "first dispatch";
    try testing.expectEqual(
        @as(u64, 1),
        first_dispatch.lease.?.connection_sequence,
    );

    second_peer = try openRawLoopbackPeer(
        transport.port(),
    );
    try writeRawModelsRequest(second_peer.?);
    const second_enqueued =
        try event_log.waitForKind(.enqueued, 2);
    try testing.expectEqual(
        @as(u64, 2),
        second_enqueued.lease.?.connection_sequence,
    );
    const paused =
        try event_log.waitForKindAfterOrdinal(
            .backpressure_paused,
            second_enqueued.ordinal,
        );
    failure_stage = "pause event";
    try testing.expectEqual(@as(u8, 1), paused.queued_connections);
    try testing.expectEqual(@as(u8, 1), paused.running_connections);

    third_peer = try openRawLoopbackPeer(
        transport.port(),
    );
    try writeRawModelsRequest(third_peer.?);
    const paused_snapshot = lifecycle.snapshotV1();
    failure_stage = "paused snapshot";
    try expectConcurrentSnapshotConservation(
        paused_snapshot,
    );
    try testing.expectEqual(
        @as(u64, 2),
        paused_snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        paused_snapshot.managed.queued_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        paused_snapshot.running_connections,
    );
    try testing.expect(paused_snapshot.accept_paused);
    try testing.expectEqual(
        paused_snapshot.listener_backpressure_activations,
        paused_snapshot.listener_backpressure_resumptions + 1,
    );

    event_log.releaseFirstDispatch();
    failure_stage = "released dispatch";
    try first_models.finish(&runtime.model_id);
    const resumed =
        try event_log.waitForKindAfterOrdinal(
            .backpressure_resumed,
            paused.ordinal,
        );
    try testing.expect(resumed.ordinal > paused.ordinal);
    try expectRawModelsResponse(
        second_peer.?,
        &runtime.model_id,
    );
    try expectRawModelsResponse(
        third_peer.?,
        &runtime.model_id,
    );
    _ = try event_log.waitForKind(.retired, 3);

    var dispatches: [8]server_api.ManagedConcurrentEventV1 =
        undefined;
    const dispatch_count = try event_log.copyKind(
        .dispatched,
        &dispatches,
    );
    failure_stage = "FIFO dispatch evidence";
    try testing.expectEqual(
        @as(usize, 3),
        dispatch_count,
    );
    sortConcurrentEventsByOrdinal(
        dispatches[0..dispatch_count],
    );
    try testing.expect(
        dispatches[0].ordinal < dispatches[1].ordinal,
    );
    try testing.expect(
        dispatches[1].ordinal < dispatches[2].ordinal,
    );
    for (
        dispatches[0..3],
        1..4,
    ) |dispatch, expected_sequence| {
        try testing.expectEqual(
            @as(u64, @intCast(expected_sequence)),
            dispatch.lease.?.connection_sequence,
        );
    }

    try follow_up_models.start(transport.port());
    try follow_up_models.finish(&runtime.model_id);
    _ = try event_log.waitForKind(.retired, 4);
    try transport.drain();
    try transport.finish();

    const final_snapshot = lifecycle.snapshotV1();
    failure_stage = "final snapshot";
    try expectConcurrentSnapshotConservation(
        final_snapshot,
    );
    try testing.expectEqual(
        server_api.ManagedStateV1.stopped,
        final_snapshot.managed.state,
    );
    try testing.expectEqual(
        @as(u64, 4),
        final_snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        @as(u64, 4),
        final_snapshot.managed.completed_connections,
    );
    try testing.expectEqual(
        @as(u64, 0),
        final_snapshot.managed.failed_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        final_snapshot.queue_high_watermark,
    );
    try testing.expectEqual(
        @as(u8, 1),
        final_snapshot.running_high_watermark,
    );
    try testing.expectEqual(
        final_snapshot.listener_backpressure_activations,
        final_snapshot.listener_backpressure_resumptions,
    );
    try expectBackpressureTransitionsAreExact(
        &event_log,
    );
    failure_stage = "event conservation";
    try testing.expectEqual(
        final_snapshot.event_ordinal,
        @as(u64, @intCast(try event_log.totalCount())),
    );
    try expectModelOnlyServiceCleanup(
        &service_harness.service,
    );
    failure_stage = "service cleanup";
    service_closed = true;
}

// C: accept-origin timeout authority retires an exact queued lease.
fn runConcurrentQueuedTimeoutScenario(
    binding: unary.ModelBindingV1,
) !void {
    var service_harness: ServiceHarness(1, 1) = .{};
    try service_harness.init(
        binding,
        0x4854_5450_4643,
    );
    var service_closed = false;
    defer if (!service_closed) {
        _ = service_harness.service.closeV1() catch {};
    };

    var runtime = try server.initV1(
        &service_harness.service,
        binding.binding_sha256,
    );
    var lifecycle =
        try server_api.ManagedConcurrentLifecycleV1.initV1(
            0x4643_0000_0000_0001,
            .{
                .worker_count = 1,
                .pending_connection_capacity = 1,
            },
        );
    try lifecycle.markReadyV1();
    var event_log: ConcurrentEventLog = .{
        .block_first_dispatch = true,
    };
    var transport: ConcurrentServerHarness = .{};
    var first_peer: ?std.net.Stream = null;
    var timed_out_peer: ?std.net.Stream = null;
    var successor_peer: ?std.net.Stream = null;
    try transport.start(
        &runtime,
        &lifecycle,
        .{
            .full_request_timeout_ns = std.time.ns_per_s,
        },
        event_log.observer(),
    );
    defer {
        event_log.releaseFirstDispatch();
        transport.deinit();
        if (first_peer) |peer| peer.close();
        if (timed_out_peer) |peer| peer.close();
        if (successor_peer) |peer| peer.close();
    }

    first_peer = try openRawLoopbackPeer(
        transport.port(),
    );
    try writeRawModelsRequest(first_peer.?);
    try event_log.waitForFirstDispatch();
    const first_dispatch =
        try event_log.waitForKind(.dispatched, 1);
    try testing.expectEqual(
        @as(u64, 1),
        first_dispatch.lease.?.connection_sequence,
    );

    timed_out_peer = try openRawLoopbackPeer(
        transport.port(),
    );
    try writeRawModelsRequest(timed_out_peer.?);
    const queued =
        try event_log.waitForKind(.enqueued, 2);
    try testing.expectEqual(
        @as(u64, 2),
        queued.lease.?.connection_sequence,
    );
    _ = try event_log.waitForKind(
        .backpressure_paused,
        1,
    );
    const timeout_event =
        try event_log.waitForKind(
            .queued_full_request_timeout,
            1,
        );
    try testing.expectEqual(
        queued.lease.?.connection_sequence,
        timeout_event.lease.?.connection_sequence,
    );
    try expectRawPeerEofWithoutResponse(
        timed_out_peer.?,
    );

    const timed_out_snapshot = lifecycle.snapshotV1();
    try expectConcurrentSnapshotConservation(
        timed_out_snapshot,
    );
    try testing.expectEqual(
        @as(u64, 2),
        timed_out_snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        timed_out_snapshot.managed.failed_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        timed_out_snapshot.managed.active_connections,
    );
    try testing.expectEqual(
        @as(u8, 0),
        timed_out_snapshot.managed.queued_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        timed_out_snapshot.phase_counts.receiving_head,
    );
    try testing.expectEqual(
        @as(u64, 1),
        timed_out_snapshot
            .full_request_timeout_queued_connections,
    );
    try testing.expect(
        timed_out_snapshot
            .managed
            .full_request_timeout_signaled_connections >= 1,
    );

    successor_peer = try openRawLoopbackPeer(
        transport.port(),
    );
    try writeRawModelsRequest(successor_peer.?);
    const successor_enqueued =
        try event_log.waitForKind(.enqueued, 3);
    try testing.expectEqual(
        @as(u64, 3),
        successor_enqueued.lease.?.connection_sequence,
    );
    event_log.releaseFirstDispatch();

    try expectRawPeerEofWithoutResponse(first_peer.?);
    try expectRawModelsResponse(
        successor_peer.?,
        &runtime.model_id,
    );
    _ = try event_log.waitForKind(.retired, 2);
    try transport.drain();
    try transport.finish();

    const final_snapshot = lifecycle.snapshotV1();
    try expectConcurrentSnapshotConservation(
        final_snapshot,
    );
    try testing.expectEqual(
        server_api.ManagedStateV1.stopped,
        final_snapshot.managed.state,
    );
    try testing.expectEqual(
        @as(u64, 3),
        final_snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot.managed.completed_connections,
    );
    try testing.expectEqual(
        @as(u64, 2),
        final_snapshot.managed.failed_connections,
    );
    try testing.expectEqual(
        @as(u64, 3),
        final_snapshot.queue_enqueued_connections,
    );
    try testing.expectEqual(
        @as(u64, 2),
        final_snapshot.queue_dispatched_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot
            .full_request_timeout_queued_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        final_snapshot.queue_high_watermark,
    );
    try testing.expectEqual(
        @as(u8, 1),
        final_snapshot.running_high_watermark,
    );
    try testing.expectEqual(
        @as(u64, 2),
        final_snapshot
            .managed
            .full_request_timeout_signaled_connections,
    );
    try testing.expectEqual(
        final_snapshot.event_ordinal,
        @as(u64, @intCast(try event_log.totalCount())),
    );
    try expectBackpressureTransitionsAreExact(
        &event_log,
    );
    try expectModelOnlyServiceCleanup(
        &service_harness.service,
    );
    service_closed = true;
}

// D: repeated drain converges one active receive and one queued socket.
fn runConcurrentDrainScenario(
    binding: unary.ModelBindingV1,
) !void {
    var service_harness: ServiceHarness(1, 1) = .{};
    try service_harness.init(
        binding,
        0x4854_5450_4644,
    );
    var service_closed = false;
    defer if (!service_closed) {
        _ = service_harness.service.closeV1() catch {};
    };

    var runtime = try server.initV1(
        &service_harness.service,
        binding.binding_sha256,
    );
    var lifecycle =
        try server_api.ManagedConcurrentLifecycleV1.initV1(
            0x4644_0000_0000_0001,
            .{
                .worker_count = 1,
                .pending_connection_capacity = 1,
            },
        );
    try lifecycle.markReadyV1();
    var event_log: ConcurrentEventLog = .{};
    var transport: ConcurrentServerHarness = .{};
    var active_peer: ?std.net.Stream = null;
    var queued_peer: ?std.net.Stream = null;
    var drain_start: std.Thread.ResetEvent = .{};
    var first_drain: ConcurrentDrainCall = .{
        .lifecycle = &lifecycle,
        .runtime = &runtime,
        .listen_address = undefined,
        .start = &drain_start,
    };
    var second_drain: ConcurrentDrainCall = .{
        .lifecycle = &lifecycle,
        .runtime = &runtime,
        .listen_address = undefined,
        .start = &drain_start,
    };
    var first_drain_thread: ?std.Thread = null;
    var second_drain_thread: ?std.Thread = null;
    try transport.start(
        &runtime,
        &lifecycle,
        .{},
        event_log.observer(),
    );
    first_drain.listen_address = transport.address();
    second_drain.listen_address = transport.address();
    defer {
        drain_start.set();
        if (first_drain_thread) |thread| thread.join();
        if (second_drain_thread) |thread| thread.join();
        event_log.releaseFirstDispatch();
        transport.deinit();
        if (active_peer) |peer| peer.close();
        if (queued_peer) |peer| peer.close();
    }

    active_peer = try openRawLoopbackPeer(
        transport.port(),
    );
    try writeRawPartialModelsHead(active_peer.?);
    const active_dispatch =
        try event_log.waitForKind(.dispatched, 1);
    try testing.expectEqual(
        @as(u64, 1),
        active_dispatch.lease.?.connection_sequence,
    );

    queued_peer = try openRawLoopbackPeer(
        transport.port(),
    );
    try writeRawModelsRequest(queued_peer.?);
    const queued_event =
        try event_log.waitForKind(.enqueued, 2);
    try testing.expectEqual(
        @as(u64, 2),
        queued_event.lease.?.connection_sequence,
    );
    _ = try event_log.waitForKind(
        .backpressure_paused,
        1,
    );
    const before_drain = lifecycle.snapshotV1();
    try expectConcurrentSnapshotConservation(
        before_drain,
    );
    try testing.expectEqual(
        @as(u8, 1),
        before_drain.phase_counts.receiving_head,
    );
    try testing.expectEqual(
        @as(u8, 1),
        before_drain.phase_counts.queued,
    );

    first_drain_thread = try std.Thread.spawn(
        .{},
        ConcurrentDrainCall.run,
        .{&first_drain},
    );
    second_drain_thread = try std.Thread.spawn(
        .{},
        ConcurrentDrainCall.run,
        .{&second_drain},
    );
    drain_start.set();
    try waitForConcurrentTestEvent(&first_drain.done);
    try waitForConcurrentTestEvent(&second_drain.done);
    first_drain_thread.?.join();
    first_drain_thread = null;
    second_drain_thread.?.join();
    second_drain_thread = null;
    if (first_drain.thread_error) |err| return err;
    if (second_drain.thread_error) |err| return err;

    const queued_drain =
        try event_log.waitForKind(.queued_drain, 1);
    try testing.expectEqual(
        queued_event.lease.?.connection_sequence,
        queued_drain.lease.?.connection_sequence,
    );
    try expectRawPeerEofWithoutResponse(queued_peer.?);
    try expectRawPeerEofWithoutResponse(active_peer.?);
    _ = try event_log.waitForKind(.retired, 1);
    try transport.finish();

    const final_snapshot = lifecycle.snapshotV1();
    try expectConcurrentSnapshotConservation(
        final_snapshot,
    );
    try testing.expectEqual(
        server_api.ManagedStateV1.stopped,
        final_snapshot.managed.state,
    );
    try testing.expectEqual(
        @as(u64, 2),
        final_snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        @as(u64, 0),
        final_snapshot.managed.completed_connections,
    );
    try testing.expectEqual(
        @as(u64, 2),
        final_snapshot.managed.failed_connections,
    );
    try testing.expectEqual(
        @as(u64, 2),
        final_snapshot.managed.drain_signaled_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot.queue_dispatched_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot.drain_cancelled_queued_connections,
    );
    try testing.expectEqual(
        @as(u8, 1),
        final_snapshot.queue_high_watermark,
    );
    try testing.expectEqual(
        @as(u8, 1),
        final_snapshot.running_high_watermark,
    );
    try testing.expectEqual(
        @as(usize, 1),
        try event_log.countKind(.dispatched),
    );
    try testing.expectEqual(
        @as(usize, 1),
        try event_log.countKind(.queued_drain),
    );
    try testing.expectEqual(
        final_snapshot.event_ordinal,
        @as(u64, @intCast(try event_log.totalCount())),
    );
    try expectModelOnlyServiceCleanup(
        &service_harness.service,
    );
    service_closed = true;
}

// Regression: timestamps remain ordinal-aligned when callback delivery inverts.
fn runConcurrentLinearizedTimestampScenario(
    binding: unary.ModelBindingV1,
) !void {
    var service_harness: ServiceHarness(1, 1) = .{};
    try service_harness.init(
        binding,
        0x4854_5450_4645,
    );
    var service_closed = false;
    defer if (!service_closed) {
        _ = service_harness.service.closeV1() catch {};
    };

    var runtime = try server.initV1(
        &service_harness.service,
        binding.binding_sha256,
    );
    var lifecycle =
        try server_api.ManagedConcurrentLifecycleV1.initV1(
            0x4645_0000_0000_0001,
            .{
                .worker_count = 1,
                .pending_connection_capacity = 1,
            },
        );
    try lifecycle.markReadyV1();
    var event_log: ConcurrentEventLog = .{
        .block_first_enqueued_until_dispatch = true,
    };
    var transport: ConcurrentServerHarness = .{};
    var models_call: ModelsCall = .{};
    try transport.start(
        &runtime,
        &lifecycle,
        .{},
        event_log.observer(),
    );
    defer {
        event_log.releaseInvertedCallbackBarrier();
        transport.deinit();
        models_call.deinit();
    }

    try models_call.start(transport.port());
    try event_log.waitForFirstEnqueuedCallback();
    try event_log.waitForFirstInvertedDispatch();
    try event_log.expectNoInvertedCallbackWaitFailure();
    try models_call.finish(&runtime.model_id);
    _ = try event_log.waitForKind(.retired, 1);
    try transport.drain();
    try transport.finish();

    const enqueued = try event_log.waitForKind(.enqueued, 1);
    const dispatched = try event_log.waitForKind(.dispatched, 1);
    try testing.expect(enqueued.ordinal < dispatched.ordinal);
    try testing.expectEqual(
        enqueued.lease.?.connection_sequence,
        dispatched.lease.?.connection_sequence,
    );
    try testing.expect(
        try event_log.firstIndexOfKind(.dispatched) <
            try event_log.firstIndexOfKind(.enqueued),
    );
    if (comptime builtin.os.tag == .windows or
        builtin.os.tag == .wasi or
        builtin.os.tag == .uefi)
    {
        try testing.expectEqual(
            @as(u64, 0),
            enqueued.linearized_monotonic_ns,
        );
        try testing.expectEqual(
            @as(u64, 0),
            dispatched.linearized_monotonic_ns,
        );
    } else {
        try testing.expect(
            enqueued.linearized_monotonic_ns != 0,
        );
        try testing.expect(
            dispatched.linearized_monotonic_ns != 0,
        );
        try testing.expect(
            enqueued.linearized_monotonic_ns <=
                dispatched.linearized_monotonic_ns,
        );
    }

    const final_snapshot = lifecycle.snapshotV1();
    try expectConcurrentSnapshotConservation(
        final_snapshot,
    );
    try testing.expectEqual(
        server_api.ManagedStateV1.stopped,
        final_snapshot.managed.state,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot.managed.accepted_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot.managed.completed_connections,
    );
    try testing.expectEqual(
        @as(u64, 0),
        final_snapshot.managed.failed_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot.queue_enqueued_connections,
    );
    try testing.expectEqual(
        @as(u64, 1),
        final_snapshot.queue_dispatched_connections,
    );
    try testing.expectEqual(
        final_snapshot.event_ordinal,
        @as(u64, @intCast(try event_log.totalCount())),
    );
    try expectModelOnlyServiceCleanup(
        &service_harness.service,
    );
    service_closed = true;
}

test "phase F1 bounded concurrent transport is deterministic over native loopback" {
    var fixture = try ModelFixture.init();
    defer fixture.deinit();
    const binding = try fixture.bind();

    runConcurrentSiblingLivenessScenario(binding) catch |err| {
        std.log.err("F1 scenario A failed", .{});
        return err;
    };
    runConcurrentFifoBackpressureScenario(binding) catch |err| {
        std.log.err("F1 scenario B failed", .{});
        return err;
    };
    runConcurrentQueuedTimeoutScenario(binding) catch |err| {
        std.log.err("F1 scenario C failed", .{});
        return err;
    };
    runConcurrentDrainScenario(binding) catch |err| {
        std.log.err("F1 scenario D failed", .{});
        return err;
    };
    runConcurrentLinearizedTimestampScenario(binding) catch |err| {
        std.log.err(
            "F1 callback-order timestamp regression failed",
            .{},
        );
        return err;
    };
}

test "managed unary HTTP observes exact admission rejections" {
    var fixture = try ModelFixture.init();
    defer fixture.deinit();
    const binding = try fixture.bind();
    const service_epoch: u64 = 0x4854_5450_5233;
    const process_generation: u64 =
        0x4854_5450_4f42_5331;

    var harness: ServiceHarness(1, 1) = .{};
    try harness.init(binding, service_epoch);
    var service_closed = false;
    defer if (!service_closed) {
        _ = harness.service.closeV1() catch {};
    };
    const initial = try harness.service.snapshotV1();
    var runtime = try server.initV1(
        &harness.service,
        binding.binding_sha256,
    );
    var lifecycle =
        try server_api.ManagedLifecycleV1.initV1(
            process_generation,
        );
    try lifecycle.markReadyV1();
    var observations: AdmissionObservationLogV1 = .{};
    var loopback: LoopbackServer = .{};
    try loopback.startManaged(
        &runtime,
        4,
        &lifecycle,
        observations.control(),
    );
    defer loopback.deinit();

    var client = try client_api.ClientV1.initLoopback(
        testing.allocator,
        "127.0.0.1",
        loopback.port(),
    );
    defer client.deinit();

    const scheduler_request: protocol.RequestV1 = .{
        .model_id = &runtime.model_id,
        .tenant_key = 73,
        .idempotency_key = "observer-scheduler",
        .prompt_utf8 = "http-probe-6",
        .max_new_tokens = 2,
        .deadline_tick = 1,
    };
    const scheduler_request_sha256 =
        try protocol.requestSha256V1(scheduler_request);
    const scheduler_error = try expectApiError(
        try client.completeV1(scheduler_request),
        .scheduler_rejected,
    );
    try testing.expectEqual(
        protocol.RetryDispositionV1.same_request_after_backoff,
        scheduler_error.retry,
    );
    try testing.expectEqual(
        scheduler_request_sha256,
        scheduler_error.request_sha256.?,
    );
    try observations.expectCounts(0, 1, 0);
    try testing.expectEqual(@as(u64, 0), runtime.next_work_sequence);

    const scheduler_observation =
        try observations.rejectionAt(0);
    try testing.expectEqual(
        scheduler_request_sha256,
        scheduler_observation.request_sha256,
    );
    try testing.expectEqualDeep(
        server.TransportOwnerTokenV1{
            .process_generation = process_generation,
            .connection_sequence = 1,
            .slot_index = 0,
            .slot_generation = 1,
        },
        scheduler_observation.transport_owner.?,
    );
    const scheduler_cause =
        switch (scheduler_observation.cause) {
            .scheduler => |cause| cause,
            .service_capacity => return error.TestUnexpectedResult,
        };
    try testing.expectEqual(
        engine.lane_weave_qos.event_abi,
        scheduler_cause.event_abi_version,
    );
    try testing.expectEqual(
        service_epoch ^ 0x5343_4844,
        scheduler_cause.scheduler_epoch,
    );
    try testing.expectEqual(
        initial.scheduler.?.next_event_sequence,
        scheduler_cause.event_sequence,
    );
    try testing.expectEqual(
        server.SchedulerAdmissionRejectionReasonV1
            .deadline_infeasible,
        scheduler_cause.reason,
    );
    const after_scheduler =
        try harness.service.snapshotV1();
    try testing.expectEqual(
        scheduler_cause.event_sha256,
        after_scheduler.scheduler.?.chain_head_sha256,
    );
    const zero_digest = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(
        u8,
        &zero_digest,
        &scheduler_cause.event_sha256,
    ));
    try testing.expectEqual(
        initial.next_request_identity + 1,
        after_scheduler.next_request_identity,
    );
    try testing.expectEqual(
        initial.scheduler.?.next_event_sequence + 1,
        after_scheduler.scheduler.?.next_event_sequence,
    );
    try testing.expectEqual(
        initial.scheduler.?.logical_tick,
        after_scheduler.scheduler.?.logical_tick,
    );
    try testing.expectEqual(
        initial.scheduler.?.active,
        after_scheduler.scheduler.?.active,
    );
    try testing.expectEqual(
        initial.scheduler.?.finished,
        after_scheduler.scheduler.?.finished,
    );
    try testing.expectEqualDeep(
        initial.bank.?,
        after_scheduler.bank.?,
    );
    try testing.expectEqual(@as(u32, 0), after_scheduler.active_requests);
    try testing.expectEqual(@as(u32, 0), after_scheduler.terminal_records);

    const success_request: protocol.RequestV1 = .{
        .model_id = &runtime.model_id,
        .tenant_key = 79,
        .idempotency_key = "observer-success",
        .prompt_utf8 = "http-probe-6",
        .max_new_tokens = 1,
    };
    _ = try expectCompletion(
        try client.completeV1(success_request),
    );
    try observations.expectCounts(1, 1, 1);
    try testing.expectEqual(@as(u64, 1), runtime.next_work_sequence);

    const before_capacity =
        try harness.service.snapshotV1();
    const capacity_request: protocol.RequestV1 = .{
        .model_id = &runtime.model_id,
        .tenant_key = 83,
        .idempotency_key = "observer-capacity",
        .prompt_utf8 = "http-probe-6",
        .max_new_tokens = 1,
    };
    const capacity_request_sha256 =
        try protocol.requestSha256V1(capacity_request);
    const capacity_error = try expectApiError(
        try client.completeV1(capacity_request),
        .service_capacity,
    );
    try testing.expectEqual(
        protocol.RetryDispositionV1.same_request_after_backoff,
        capacity_error.retry,
    );
    try testing.expectEqual(
        capacity_request_sha256,
        capacity_error.request_sha256.?,
    );
    try observations.expectCounts(1, 2, 1);
    try testing.expectEqual(@as(u64, 1), runtime.next_work_sequence);

    const capacity_observation =
        try observations.rejectionAt(1);
    try testing.expectEqual(
        capacity_request_sha256,
        capacity_observation.request_sha256,
    );
    try testing.expectEqualDeep(
        server.TransportOwnerTokenV1{
            .process_generation = process_generation,
            .connection_sequence = 3,
            .slot_index = 0,
            .slot_generation = 3,
        },
        capacity_observation.transport_owner.?,
    );
    switch (capacity_observation.cause) {
        .service_capacity => {},
        .scheduler => return error.TestUnexpectedResult,
    }
    try testing.expectEqualDeep(
        before_capacity,
        try harness.service.snapshotV1(),
    );

    const conflict_request: protocol.RequestV1 = .{
        .model_id = &runtime.model_id,
        .tenant_key = success_request.tenant_key,
        .idempotency_key = success_request.idempotency_key,
        .prompt_utf8 = "changed intent",
        .max_new_tokens = 1,
    };
    const conflict_request_sha256 =
        try protocol.requestSha256V1(conflict_request);
    const conflict_error = try expectApiError(
        try client.completeV1(conflict_request),
        .idempotency_conflict,
    );
    try testing.expectEqual(
        conflict_request_sha256,
        conflict_error.request_sha256.?,
    );
    try observations.expectCounts(1, 2, 1);
    try testing.expectEqual(@as(u64, 1), runtime.next_work_sequence);
    try testing.expectEqualDeep(
        before_capacity,
        try harness.service.snapshotV1(),
    );

    try loopback.finish();
    const lifecycle_snapshot = lifecycle.snapshotV1();
    try testing.expectEqual(
        server_api.ManagedStateV1.stopped,
        lifecycle_snapshot.state,
    );
    try testing.expectEqual(
        @as(u64, 4),
        lifecycle_snapshot.accepted_connections,
    );
    try testing.expectEqual(
        @as(u64, 4),
        lifecycle_snapshot.completed_connections,
    );
    try testing.expectEqual(
        @as(u64, 0),
        lifecycle_snapshot.failed_connections,
    );
    try testing.expectEqual(
        @as(u8, 0),
        lifecycle_snapshot.active_connections,
    );
    const final_snapshot =
        try harness.service.snapshotV1();
    try testing.expectEqual(
        @as(u32, 0),
        final_snapshot.active_requests,
    );
    try testing.expectEqual(
        @as(u32, 1),
        final_snapshot.terminal_records,
    );
    try testing.expect(final_snapshot.bank.?.used.isZero());
    const close = try harness.service.closeV1();
    service_closed = true;
    try testing.expectEqual(
        @as(u32, 1),
        close.terminal_records,
    );
    try testing.expect(close.bank_snapshot.used.isZero());
}

test "bounded unary HTTP uses one kernel over real loopback" {
    var fixture = try ModelFixture.init();
    defer fixture.deinit();
    const binding = try fixture.bind();
    const prompt = "http-probe-6";
    const oracle = try oracleTokens(
        &fixture,
        prompt,
        1,
    );
    defer testing.allocator.free(oracle);
    try testing.expectEqual(@as(usize, 1), oracle.len);
    const oracle_byte = std.math.cast(u8, oracle[0]) orelse
        return error.TestUnexpectedResult;
    try testing.expect(std.unicode.utf8ValidateSlice(
        &.{oracle_byte},
    ));

    var harness: ServiceHarness(1, 1) = .{};
    try harness.init(binding, 0x4854_5450_5231);
    const initial_snapshot = try harness.service.snapshotV1();

    const model_id = protocol.modelIdV1(
        binding.binding_sha256,
    );
    var valid_body: [protocol.request_body_max_bytes]u8 =
        undefined;
    const valid_request: protocol.RequestV1 = .{
        .model_id = &model_id,
        .tenant_key = 17,
        .idempotency_key = "http-key-a",
        .prompt_utf8 = prompt,
        .max_new_tokens = 1,
    };
    const valid_encoded = try protocol.encodeRequestV1(
        valid_request,
        &valid_body,
    );
    var borrowed_key: [10]u8 = undefined;
    @memcpy(&borrowed_key, "http-key-a");
    var owned_decode = try protocol.decodeRequestV1(
        testing.allocator,
        valid_encoded,
        .{
            .idempotency_key = &borrowed_key,
            .tenant_key = "17",
        },
        &model_id,
    );
    defer owned_decode.deinit();
    borrowed_key[0] = 'X';
    try testing.expectEqualStrings(
        "http-key-a",
        owned_decode.request.idempotency_key,
    );

    var malformed_storage: [protocol.request_body_max_bytes]u8 = undefined;
    const unknown_json = try std.fmt.bufPrint(
        &malformed_storage,
        "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"x\"}}],\"max_tokens\":1,\"stream\":false,\"unknown\":1}}",
        .{model_id},
    );
    try testing.expectError(
        protocol.Error.InvalidRequest,
        protocol.decodeRequestV1(
            testing.allocator,
            unknown_json,
            .{
                .idempotency_key = "http-key-a",
                .tenant_key = "17",
            },
            &model_id,
        ),
    );
    const duplicate_json = try std.fmt.bufPrint(
        &malformed_storage,
        "{{\"model\":\"{s}\",\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"x\"}}],\"max_tokens\":1,\"stream\":false}}",
        .{ model_id, model_id },
    );
    try testing.expectError(
        protocol.Error.InvalidRequest,
        protocol.decodeRequestV1(
            testing.allocator,
            duplicate_json,
            .{
                .idempotency_key = "http-key-a",
                .tenant_key = "17",
            },
            &model_id,
        ),
    );
    var oversized_prompt: [protocol.prompt_max_bytes + 1]u8 =
        [_]u8{'x'} ** (protocol.prompt_max_bytes + 1);
    try testing.expectError(
        protocol.Error.RequestTooLarge,
        protocol.encodeRequestV1(.{
            .model_id = &model_id,
            .tenant_key = 17,
            .idempotency_key = "http-key-a",
            .prompt_utf8 = &oversized_prompt,
            .max_new_tokens = 1,
        }, &valid_body),
    );
    try testing.expectEqualDeep(
        initial_snapshot,
        try harness.service.snapshotV1(),
    );

    const invalid_bytes = [_]u8{0xff};
    const invalid_tokens = [_]u32{0xff};
    var response_storage: [protocol.response_body_max_bytes]u8 = undefined;
    try testing.expectError(
        protocol.Error.NonUtf8Output,
        protocol.encodeCompletionV1(.{
            .model_id = &model_id,
            .content_utf8 = &invalid_bytes,
            .output_tokens = &invalid_tokens,
            .prompt_tokens = 1,
            .handle_sha256 = [_]u8{1} ** 32,
            .request_sha256 = [_]u8{2} ** 32,
            .response_sha256 = [_]u8{3} ** 32,
            .terminal_evidence_sha256 = [_]u8{4} ** 32,
            .output_sha256 = [_]u8{5} ** 32,
        }, &response_storage),
    );

    var wrong_binding = binding.binding_sha256;
    wrong_binding[0] ^= 1;
    try testing.expectError(
        protocol.Error.InvalidRequest,
        server.initV1(&harness.service, wrong_binding),
    );
    var runtime = try server.initV1(
        &harness.service,
        binding.binding_sha256,
    );
    var loopback: LoopbackServer = .{};
    try loopback.start(&runtime, 7);
    defer loopback.deinit();

    var forged_endpoint: client_api.EndpointV1 = .{
        .host_bytes = 8,
        .port = loopback.port(),
    };
    @memcpy(
        forged_endpoint.host_storage[0..8],
        "10.0.0.1",
    );
    try testing.expectError(
        client_api.Error.NonLoopbackEndpoint,
        client_api.ClientV1.init(
            testing.allocator,
            forged_endpoint,
        ),
    );
    forged_endpoint.host_bytes = std.math.maxInt(u8);
    try testing.expectError(
        client_api.Error.InvalidConfiguration,
        client_api.ClientV1.init(
            testing.allocator,
            forged_endpoint,
        ),
    );

    var client = try client_api.ClientV1.initLoopback(
        testing.allocator,
        "127.0.0.1",
        loopback.port(),
    );
    defer client.deinit();

    const malformed_address = try std.net.Address.parseIp(
        "127.0.0.1",
        loopback.port(),
    );
    const malformed = try std.net.tcpConnectToAddress(
        malformed_address,
    );
    malformed.close();

    const models = try expectModels(
        try client.listModelsV1(),
    );
    try testing.expectEqual(
        binding.binding_sha256,
        models.model_binding_sha256,
    );
    try testing.expectEqualSlices(
        u8,
        &runtime.model_id,
        &models.model_id,
    );

    const request: protocol.RequestV1 = .{
        .model_id = &models.model_id,
        .tenant_key = 17,
        .idempotency_key = "http-key-a",
        .prompt_utf8 = prompt,
        .max_new_tokens = 1,
    };
    const first = try expectCompletion(
        try client.completeV1(request),
    );
    try testing.expectEqualSlices(
        u32,
        oracle,
        first.outputSlice(),
    );
    try testing.expectEqual(
        oracle[0],
        first.output_tokens[0],
    );

    const replay = try expectCompletion(
        try client.completeV1(request),
    );
    try testing.expectEqualDeep(first, replay);

    const conflict = try expectApiError(
        try client.completeV1(.{
            .model_id = &models.model_id,
            .tenant_key = 17,
            .idempotency_key = "http-key-a",
            .prompt_utf8 = "changed intent",
            .max_new_tokens = 1,
        }),
        .idempotency_conflict,
    );
    try testing.expect(conflict.request_sha256 != null);

    const capacity = try expectApiError(
        try client.completeV1(.{
            .model_id = &models.model_id,
            .tenant_key = 17,
            .idempotency_key = "http-key-b",
            .prompt_utf8 = prompt,
            .max_new_tokens = 1,
        }),
        .service_capacity,
    );
    try testing.expect(capacity.request_sha256 != null);

    const retained_replay = try expectCompletion(
        try client.completeV1(request),
    );
    try testing.expectEqualDeep(first, retained_replay);

    try loopback.finish();
    const snapshot = try harness.service.snapshotV1();
    try testing.expectEqual(@as(u32, 0), snapshot.active_requests);
    try testing.expectEqual(@as(u32, 1), snapshot.terminal_records);
    try testing.expect(snapshot.bank.?.used.isZero());
    const close = try harness.service.closeV1();
    try testing.expect(close.bank_snapshot.used.isZero());
    try testing.expectEqual(@as(u32, 1), close.terminal_records);

    var closed_harness: ServiceHarness(1, 1) = .{};
    try closed_harness.init(binding, 0x4854_5450_5232);
    const closed_initial =
        try closed_harness.service.snapshotV1();
    var closed_runtime = try server.initV1(
        &closed_harness.service,
        binding.binding_sha256,
    );
    const first_drain = try server.beginDrainV1(
        &closed_runtime,
    );
    try testing.expect(first_drain.admission_was_open);
    try testing.expect(first_drain.active_work == null);
    try testing.expectEqual(
        server.DrainCancellationOutcomeV1.none,
        first_drain.cancellation,
    );
    const repeated_drain = try server.beginDrainV1(
        &closed_runtime,
    );
    try testing.expect(!repeated_drain.admission_was_open);
    try testing.expect(repeated_drain.active_work == null);
    try testing.expectEqual(
        server.DrainCancellationOutcomeV1.none,
        repeated_drain.cancellation,
    );

    var closed_loopback: LoopbackServer = .{};
    try closed_loopback.start(&closed_runtime, 1);
    defer closed_loopback.deinit();
    var closed_client = try client_api.ClientV1.initLoopback(
        testing.allocator,
        "127.0.0.1",
        closed_loopback.port(),
    );
    defer closed_client.deinit();
    const closed_error = try expectApiError(
        try closed_client.completeV1(.{
            .model_id = &closed_runtime.model_id,
            .tenant_key = 19,
            .idempotency_key = "http-closed-gate",
            .prompt_utf8 = prompt,
            .max_new_tokens = 1,
        }),
        .service_closed,
    );
    try testing.expect(closed_error.request_sha256 != null);
    try closed_loopback.finish();
    try testing.expectEqualDeep(
        closed_initial,
        try closed_harness.service.snapshotV1(),
    );
    const closed_receipt =
        try closed_harness.service.closeV1();
    try testing.expectEqual(
        @as(u32, 0),
        closed_receipt.terminal_records,
    );
    try testing.expect(
        closed_receipt.bank_snapshot.used.isZero(),
    );
}
