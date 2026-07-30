const std = @import("std");
const engine = @import("engine");

const testing = std.testing;
const unary = engine.prepared_text_unary_service;
const protocol = engine.prepared_text_unary_http_v1;
const server = engine.prepared_text_unary_http_server;
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
    thread: ?std.Thread = null,
    thread_error: ?anyerror = null,
    listener_open: bool = false,

    fn start(
        self: *LoopbackServer,
        runtime: *server.RuntimeV1,
        request_count: u64,
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
        engine.server_api.serveListenerV1(
            &self.listener,
            .{ .stop_after_requests = self.request_count },
            self.runtime,
        ) catch |err| {
            self.thread_error = err;
        };
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
}
