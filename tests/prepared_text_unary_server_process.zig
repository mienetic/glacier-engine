const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const unary = engine.prepared_text_unary_service;
const protocol = engine.prepared_text_unary_http_v1;
const http_server = engine.prepared_text_unary_http_server;
const http_client = engine.prepared_text_unary_http_client;
const server_api = engine.server_api;

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
const loopback_host = "127.0.0.1";
const drain_command = "drain\n";
const drain_head_command = "drain-head\n";
const drain_body_command = "drain-body\n";
const prompt = "http-probe-6";
const generation_a: u64 = 0x4753_5052_0000_0101;
const generation_partial_head: u64 = 0x4753_5052_0000_0102;
const generation_partial_body: u64 = 0x4753_5052_0000_0103;
const generation_b: u64 = 0x4753_5052_0000_0104;
const frame_max_bytes = 256;
const worker_timeout_ns = 15 * std.time.ns_per_s;
const watchdog_poll_ns = 10 * std.time.ns_per_ms;
const control_poll_limit: usize = 500;

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
    if (args.len != 6 or
        !std.mem.eql(u8, args[1], worker_mode))
    {
        return error.InvalidUsage;
    }
    const generation = try parseCanonicalInt(u64, args[5]);
    runWorker(
        allocator,
        args[2],
        args[3],
        args[4],
        generation,
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
    thread_error: ?anyerror = null,

    fn run(self: *ServeContext) void {
        server_api.serveManagedListenerV1(
            self.listener,
            .{},
            self.runtime,
            self.lifecycle,
        ) catch |err| {
            self.thread_error = err;
        };
    }
};

fn runWorker(
    allocator: std.mem.Allocator,
    prepared_path: []const u8,
    package_path: []const u8,
    license_path: []const u8,
    generation: u64,
) !void {
    var lifecycle =
        try server_api.ManagedLifecycleV1.initV1(generation);

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
    var serve_context: ServeContext = .{
        .listener = &listener,
        .runtime = &runtime,
        .lifecycle = &lifecycle,
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
    const drain_control =
        try readDrainControl(std.fs.File.stdin());
    if (drain_control.requestedPhase()) |phase| {
        try waitForActivePhase(&lifecycle, phase);
    }
    try server_api.requestDrainAndWakeV1(
        &lifecycle,
        &runtime,
        listen_address,
    );
    if (http_server.acceptingCompletionsV1(&runtime))
        return error.DrainAdmissionStillOpen;
    try waitForInactiveConnection(&lifecycle);
    const draining = lifecycle.snapshotV1();
    try validateDrainSignalReceipt(
        draining,
        drain_control.requestedPhase(),
    );
    try emitDraining(draining);

    serve_thread.join();
    joined = true;
    if (serve_context.thread_error) |err| return err;

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
    const service_snapshot = try harness.service.snapshotV1();
    if (service_snapshot.active_requests != 0 or
        service_snapshot.bank == null or
        !service_snapshot.bank.?.used.isZero())
    {
        return error.InvalidServiceReceipt;
    }
    const close_receipt = try harness.service.closeV1();
    if (!close_receipt.bank_snapshot.used.isZero())
        return error.InvalidServiceReceipt;
    try emitClosed(
        stopped,
        service_snapshot.active_requests,
        close_receipt.terminal_records,
    );
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
        _ = http_server.beginDrainV1(runtime);
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

    fn requestedPhase(
        self: DrainControl,
    ) ?server_api.ManagedConnectionPhaseV1 {
        return switch (self) {
            .immediate => null,
            .partial_head => .receiving_head,
            .partial_body => .request_head_received,
        };
    }
};

fn readDrainControl(stdin: std.fs.File) !DrainControl {
    var command: [drain_body_command.len + 1]u8 = undefined;
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

fn emitDraining(
    snapshot: server_api.ManagedSnapshotV1,
) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &storage,
        "DRAINING {d} {d} {d} {d} {d} {d} {d}\n",
        .{
            snapshot.process_generation,
            snapshot.accepted_connections,
            snapshot.completed_connections,
            snapshot.failed_connections,
            snapshot.active_connections,
            snapshot.drain_signaled_connections,
            @intFromEnum(snapshot.last_drain_signaled_phase),
        },
    );
    try std.fs.File.stdout().writeAll(frame);
}

fn emitClosed(
    snapshot: server_api.ManagedSnapshotV1,
    service_active: u32,
    terminal_records: u32,
) !void {
    var storage: [frame_max_bytes]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &storage,
        "CLOSED {d} {d} {d} {d} {d} {d} {d} {d} {d} 1\n",
        .{
            snapshot.process_generation,
            snapshot.accepted_connections,
            snapshot.completed_connections,
            snapshot.failed_connections,
            snapshot.active_connections,
            snapshot.drain_signaled_connections,
            @intFromEnum(snapshot.last_drain_signaled_phase),
            service_active,
            terminal_records,
        },
    );
    try std.fs.File.stdout().writeAll(frame);
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
};

const ClosedFrame = struct {
    activity: ActivityFrame,
    service_active: u32,
    terminal_records: u32,
    bank_zero: u8,
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
    );
    try validateActivity(
        closed.activity,
        generation,
        expected_accepted,
        expected_completed,
        expected_failed,
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
        },
        allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
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

fn require(condition: bool) !void {
    if (!condition) return error.TestUnexpectedResult;
}
