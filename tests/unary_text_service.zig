const std = @import("std");
const engine = @import("engine");

const testing = std.testing;
const unary = engine.prepared_text_unary_service;

const fixture_license = "Glacier unary text service synthetic fixture\n";
const fixture_config =
    \\{"hidden_size":32,"intermediate_size":64,"num_hidden_layers":1,
    \\"vocab_size":256,"num_attention_heads":4,"num_key_value_heads":4,
    \\"rms_norm_eps":0.00001,"rope_theta":500000,
    \\"tie_word_embeddings":false}
    \\
;

fn pathInTmp(tmp: *testing.TmpDir, basename: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    return std.fs.path.join(testing.allocator, &.{ root, basename });
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
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

        const source_path = try pathInTmp(&tmp, "unary.safetensors");
        errdefer testing.allocator.free(source_path);
        const portable_path = try pathInTmp(&tmp, "unary.glacier");
        errdefer testing.allocator.free(portable_path);
        const prepared_path = try pathInTmp(&tmp, "unary.glrt");
        errdefer testing.allocator.free(prepared_path);
        const package_path = try pathInTmp(&tmp, "unary.glpkg");
        errdefer testing.allocator.free(package_path);
        const config_path = try pathInTmp(&tmp, "unary-config.json");
        errdefer testing.allocator.free(config_path);
        const license_path = try pathInTmp(&tmp, "unary-license.txt");
        errdefer testing.allocator.free(license_path);

        try engine.fixture_gen.writeSafetensors(source_path, .{
            .dim = 32,
            .hidden_dim = 64,
            .num_layers = 1,
            .vocab_size = 256,
        });
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
                        .architecture = engine.model_package_producer.conversion_architecture_v1,
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
            engine.core.model_contract.sha256(fixture_license),
        );
    }
};

fn idempotencyKey(label: []const u8) [32]u8 {
    return engine.core.model_contract.sha256(label);
}

fn oracleTokens(
    fixture: *ModelFixture,
    prompt_utf8: []const u8,
    max_new_tokens: usize,
) ![]u32 {
    const manifest = try engine.tokenizer.makeUtf8ByteManifestV1(
        @intCast(fixture.model.config.vocab_size),
        engine.tokenizer.utf8_byte_max_input_bytes,
    );
    var tokenized = try engine.tokenizer.tokenizeUtf8BytesV1(
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

const AdoptionRecoveryFaultAllocator = struct {
    scheduler: *engine.lane_weave_qos.Scheduler,
    backing: std.mem.Allocator,
    enabled: bool = false,
    triggered: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.enabled and
            !self.triggered and
            self.scheduler.pending_publication_adoption != null)
        {
            self.triggered = true;
            self.scheduler.closed = true;
            return null;
        }
        return self.backing.rawAlloc(
            len,
            alignment,
            return_address,
        );
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.backing.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.backing.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.backing.rawFree(
            memory,
            alignment,
            return_address,
        );
    }
};

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
            binding: unary.ModelBindingV1,
            service_epoch: u64,
        ) !void {
            return self.initWithAllocator(
                binding,
                service_epoch,
                testing.allocator,
            );
        }

        fn initWithAllocator(
            self: *@This(),
            binding: unary.ModelBindingV1,
            service_epoch: u64,
            allocator: std.mem.Allocator,
        ) !void {
            self.bank = try engine.resource_bank.Bank.init(
                &self.bank_slots,
                .{},
                service_epoch ^ 0x4241_4e4b,
            );
            self.scheduler = try engine.lane_weave_qos.Scheduler.init(
                &self.bank,
                .{
                    .slots = &self.lane_slots,
                    .projection = &self.projection,
                },
                .{
                    .scheduler_epoch = service_epoch ^ 0x5343_4844,
                    .coordinator_id = service_epoch ^ 0x434f_4f52,
                    .challenge = engine.core.model_contract.sha256(
                        "unary text service scheduler challenge",
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

fn request(
    tenant_key: u64,
    idempotency_label: []const u8,
    prompt_utf8: []const u8,
    max_new_tokens: u16,
) unary.RequestV1 {
    return .{
        .tenant_key = tenant_key,
        .idempotency_key_sha256 = idempotencyKey(idempotency_label),
        .prompt_utf8 = prompt_utf8,
        .max_new_tokens = max_new_tokens,
    };
}

fn expectAccepted(
    decision: unary.AdmissionDecisionV1,
) !unary.AdmissionReceiptV1 {
    return switch (decision) {
        .accepted => |accepted| accepted,
        else => error.TestUnexpectedResult,
    };
}

fn expectExisting(
    decision: unary.AdmissionDecisionV1,
    expected_state: unary.ExistingStateV1,
) !unary.ExistingV1 {
    return switch (decision) {
        .existing => |existing| blk: {
            try testing.expectEqual(expected_state, existing.state);
            break :blk existing;
        },
        else => error.TestUnexpectedResult,
    };
}

fn expectDriveHandle(
    decision: unary.DriveDecisionV1,
    expected_terminal: bool,
) !unary.HandleV1 {
    return switch (decision) {
        .progressed => |progress| blk: {
            try testing.expect(!expected_terminal);
            break :blk progress.handle;
        },
        .completed => |completion| blk: {
            try testing.expect(expected_terminal);
            break :blk completion.handle;
        },
        else => error.TestUnexpectedResult,
    };
}

fn expectZeroOwnership(snapshot: unary.SnapshotV1) !void {
    try testing.expectEqual(@as(u32, 0), snapshot.active_requests);
    try testing.expectEqual(@as(u32, 0), snapshot.recovery_required);
    const scheduler = snapshot.scheduler orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), scheduler.active);
    try testing.expectEqual(@as(u32, 0), scheduler.finished);
    try testing.expect(scheduler.used.isZero());
    const bank = snapshot.bank orelse return error.TestUnexpectedResult;
    try testing.expect(bank.used.isZero());
    try testing.expectEqual(@as(usize, 0), bank.active_reservations);
    try testing.expectEqual(@as(usize, 0), bank.committed_receipts);
    try testing.expectEqual(bank.successful_commits, bank.releases);
}

test "bounded unary service interleaves, replays, and closes at zero" {
    var fixture = try ModelFixture.init();
    var fixture_live = true;
    defer if (fixture_live) fixture.deinit();
    const binding = try fixture.bind();

    var harness: ServiceHarness(2, 4) = .{};
    try harness.init(binding, 0x554e_4152_5901);

    const request_a = request(
        101,
        "unary-idempotency-a",
        "alpha",
        2,
    );
    const request_b = request(
        202,
        "unary-idempotency-b",
        "bravo",
        2,
    );
    const oracle_a = try oracleTokens(
        &fixture,
        request_a.prompt_utf8,
        request_a.max_new_tokens,
    );
    defer testing.allocator.free(oracle_a);
    const oracle_b = try oracleTokens(
        &fixture,
        request_b.prompt_utf8,
        request_b.max_new_tokens,
    );
    defer testing.allocator.free(oracle_b);

    const accepted_a =
        try expectAccepted(try harness.service.admitV1(request_a));
    const active_snapshot = try harness.service.snapshotV1();
    const replay_active = try expectExisting(
        try harness.service.admitV1(request_a),
        .active,
    );
    try testing.expectEqualDeep(
        accepted_a.handle,
        replay_active.handle,
    );
    try testing.expectEqualDeep(
        active_snapshot,
        try harness.service.snapshotV1(),
    );

    var conflicting = request_a;
    conflicting.prompt_utf8 = "changed-alpha";
    const conflict_snapshot = try harness.service.snapshotV1();
    switch (try harness.service.admitV1(conflicting)) {
        .conflict => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualDeep(
        conflict_snapshot,
        try harness.service.snapshotV1(),
    );

    const same_tenant = request(
        request_a.tenant_key,
        "unary-idempotency-same-tenant",
        "same-tenant",
        2,
    );
    const before_same_tenant =
        try harness.service.snapshotV1();
    switch (try harness.service.admitV1(same_tenant)) {
        .rejected => |rejection| switch (rejection) {
            .scheduler => |event| try testing.expectEqual(
                engine.lane_weave_qos.RejectionReason.duplicate_tenant,
                event.rejection_reason,
            ),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    const after_same_tenant =
        try harness.service.snapshotV1();
    try testing.expectEqualDeep(
        before_same_tenant.bank,
        after_same_tenant.bank,
    );
    try testing.expectEqual(
        before_same_tenant.active_requests,
        after_same_tenant.active_requests,
    );

    const accepted_b =
        try expectAccepted(try harness.service.admitV1(request_b));
    try testing.expect(
        accepted_a.start_event.resource_receipt.generation !=
            accepted_b.start_event.resource_receipt.generation,
    );

    const expected_handles = [_]unary.HandleV1{
        accepted_a.handle,
        accepted_b.handle,
        accepted_a.handle,
        accepted_b.handle,
    };
    for (expected_handles, 0..) |expected, index| {
        const actual = try expectDriveHandle(
            try harness.service.driveNextV1(),
            index >= 2,
        );
        try testing.expectEqualDeep(expected, actual);
    }
    switch (try harness.service.driveNextV1()) {
        .idle => {},
        else => return error.TestUnexpectedResult,
    }

    const response_a =
        try harness.service.responseV1(accepted_a.handle);
    const response_b =
        try harness.service.responseV1(accepted_b.handle);
    try testing.expectEqual(
        @as(u16, @intCast(oracle_a.len)),
        response_a.output_count,
    );
    try testing.expectEqualSlices(
        u32,
        oracle_a,
        response_a.output_tokens[0..response_a.output_count],
    );
    try testing.expectEqual(
        @as(u16, @intCast(oracle_b.len)),
        response_b.output_count,
    );
    try testing.expectEqualSlices(
        u32,
        oracle_b,
        response_b.output_tokens[0..response_b.output_count],
    );
    try testing.expectEqual(
        engine.lane_weave_qos.EventKind.retire,
        response_a.retire_event.kind,
    );
    try testing.expectEqual(
        engine.lane_weave_qos.EventKind.retire,
        response_b.retire_event.kind,
    );
    for ([_]unary.ResponseV1{ response_a, response_b }) |response| {
        try testing.expectEqual(
            response.output_count,
            response.private_prepare_calls,
        );
        try testing.expectEqual(
            response.output_count,
            response.private_commit_calls,
        );
        try testing.expectEqual(
            @as(u16, 0),
            response.private_abort_calls,
        );
        try testing.expect(
            !std.mem.allEqual(
                u8,
                &response.private_transcript_sha256,
                0,
            ),
        );
    }

    const completed_snapshot = try harness.service.snapshotV1();
    try expectZeroOwnership(completed_snapshot);
    try testing.expectEqual(
        @as(u32, 2),
        completed_snapshot.completed_records,
    );
    const replay_completed = try expectExisting(
        try harness.service.admitV1(request_a),
        .completed,
    );
    try testing.expectEqualDeep(
        accepted_a.handle,
        replay_completed.handle,
    );
    try testing.expectEqualDeep(
        response_a,
        try harness.service.responseV1(replay_completed.handle),
    );
    try testing.expectEqualDeep(
        completed_snapshot,
        try harness.service.snapshotV1(),
    );

    const close = try harness.service.closeV1();
    try testing.expectEqual(
        engine.lane_weave_qos.EventKind.close,
        close.scheduler_event.kind,
    );
    try testing.expect(close.bank_snapshot.used.isZero());
    try testing.expectEqual(@as(u32, 2), close.terminal_records);
    try testing.expectEqualDeep(
        response_a,
        try harness.service.responseV1(accepted_a.handle),
    );
    try testing.expectError(
        unary.Error.ServiceClosed,
        harness.service.evictTerminalV1(accepted_a.handle),
    );
    fixture.deinit();
    fixture_live = false;
    try testing.expectError(
        unary.Error.ServiceClosed,
        harness.service.evictTerminalV1(accepted_a.handle),
    );
    try testing.expectEqualDeep(
        response_a,
        try harness.service.responseV1(accepted_a.handle),
    );
    switch (try harness.service.statusV1(accepted_a.handle)) {
        .completed => |completed| try testing.expectEqualDeep(
            response_a.response_sha256,
            completed.response_sha256,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "bounded unary service rejects capacity before scheduler mutation" {
    var fixture = try ModelFixture.init();
    defer fixture.deinit();
    const binding = try fixture.bind();

    var harness: ServiceHarness(1, 2) = .{};
    try harness.init(binding, 0x554e_4152_5902);
    const first_request = request(
        303,
        "unary-idempotency-capacity-a",
        "capacity-a",
        2,
    );
    const second_request = request(
        404,
        "unary-idempotency-capacity-b",
        "capacity-b",
        2,
    );
    const first = try expectAccepted(
        try harness.service.admitV1(first_request),
    );
    const before = try harness.service.snapshotV1();
    const full_capacity_replay = try expectExisting(
        try harness.service.admitV1(first_request),
        .active,
    );
    try testing.expectEqualDeep(
        first.handle,
        full_capacity_replay.handle,
    );
    try testing.expectEqualDeep(
        before,
        try harness.service.snapshotV1(),
    );
    switch (try harness.service.admitV1(second_request)) {
        .rejected => |rejection| switch (rejection) {
            .service_capacity => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualDeep(
        before,
        try harness.service.snapshotV1(),
    );

    switch (try harness.service.cancelV1(first.handle)) {
        .cancelled => |cancelled| {
            try testing.expectEqual(
                @as(u16, 0),
                cancelled.externally_visible_tokens,
            );
            try testing.expectEqual(
                engine.lane_weave_qos.EventKind.cancel,
                cancelled.cancel_event.kind,
            );
        },
        else => return error.TestUnexpectedResult,
    }
    try expectZeroOwnership(try harness.service.snapshotV1());
    _ = try harness.service.closeV1();

    var drift_harness: ServiceHarness(1, 1) = .{};
    try drift_harness.init(binding, 0x554e_4152_5904);
    _ = try expectAccepted(try drift_harness.service.admitV1(
        request(
            707,
            "unary-idempotency-sink-drift",
            "sink-drift",
            2,
        ),
    ));
    var drift_cleaned = false;
    defer if (!drift_cleaned) {
        drift_harness.active[0].sink.prepared = false;
        drift_harness.active[0].sink.invalid = false;
        _ = drift_harness.active[0].session.cancel() catch {};
        drift_harness.active[0].session.deinit();
    };
    drift_harness.active[0].sink.prepared = true;
    try testing.expectError(
        unary.Error.FailStopRequired,
        drift_harness.service.driveNextV1(),
    );
    const drift_snapshot =
        try drift_harness.service.snapshotV1();
    try testing.expectEqual(
        unary.ServiceStateV1.fail_stop,
        drift_snapshot.state,
    );
    try testing.expectEqual(
        unary.ActivePhaseV1.publication_fail_stop,
        drift_harness.active[0].phase,
    );
    drift_harness.active[0].sink.prepared = false;
    drift_harness.active[0].sink.invalid = false;
    const cleanup_event =
        try drift_harness.active[0].session.cancel();
    try testing.expectEqual(
        engine.lane_weave_qos.EventKind.cancel,
        cleanup_event.kind,
    );
    drift_harness.active[0].session.deinit();
    drift_cleaned = true;
    try testing.expect(
        (try drift_harness.bank.snapshot()).used.isZero(),
    );
}

test "bounded unary cancellation keeps private prefix hidden and fences stale handles" {
    var fixture = try ModelFixture.init();
    defer fixture.deinit();
    const binding = try fixture.bind();

    var harness: ServiceHarness(1, 1) = .{};
    try harness.init(binding, 0x554e_4152_5903);
    const first_request = request(
        505,
        "unary-idempotency-cancel-a",
        "cancel-a",
        3,
    );
    const first = try expectAccepted(
        try harness.service.admitV1(first_request),
    );
    const progressed = try expectDriveHandle(
        try harness.service.driveNextV1(),
        false,
    );
    try testing.expectEqualDeep(first.handle, progressed);
    try testing.expectError(
        unary.Error.ResponseNotReady,
        harness.service.responseV1(first.handle),
    );
    switch (try harness.service.cancelV1(first.handle)) {
        .cancelled => |cancelled| {
            try testing.expectEqual(
                @as(u16, 1),
                cancelled.private_committed_tokens,
            );
            try testing.expectEqual(
                @as(u16, 0),
                cancelled.externally_visible_tokens,
            );
            try testing.expectEqual(
                engine.lane_weave_qos.EventKind.cancel,
                cancelled.cancel_event.kind,
            );
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectError(
        unary.Error.NoResponse,
        harness.service.responseV1(first.handle),
    );
    const cancelled_replay = try expectExisting(
        try harness.service.admitV1(first_request),
        .cancelled,
    );
    try testing.expectEqualDeep(
        first.handle,
        cancelled_replay.handle,
    );
    try expectZeroOwnership(try harness.service.snapshotV1());

    try harness.service.evictTerminalV1(first.handle);
    const second_request = request(
        606,
        "unary-idempotency-cancel-b",
        "cancel-b",
        2,
    );
    const second = try expectAccepted(
        try harness.service.admitV1(second_request),
    );
    try testing.expectEqual(
        first.handle.record_index,
        second.handle.record_index,
    );
    try testing.expect(
        first.handle.record_generation !=
            second.handle.record_generation,
    );
    const stable = try harness.service.snapshotV1();
    try testing.expectError(
        unary.Error.StaleHandle,
        harness.service.cancelV1(first.handle),
    );
    try testing.expectError(
        unary.Error.StaleHandle,
        harness.service.statusV1(first.handle),
    );
    try testing.expectEqualDeep(
        stable,
        try harness.service.snapshotV1(),
    );

    switch (try harness.service.cancelV1(second.handle)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }
    try harness.service.evictTerminalV1(second.handle);
    try expectZeroOwnership(try harness.service.snapshotV1());
    _ = try harness.service.closeV1();
}

test "bounded unary cancellation fences a recoverable start adoption" {
    var fixture = try ModelFixture.init();
    defer fixture.deinit();
    const binding = try fixture.bind();

    var harness: ServiceHarness(2, 2) = .{};
    var fault_allocator: AdoptionRecoveryFaultAllocator = .{
        .scheduler = &harness.scheduler,
        .backing = testing.allocator,
    };
    try harness.initWithAllocator(
        binding,
        0x554e_4152_5905,
        fault_allocator.allocator(),
    );
    defer {
        harness.scheduler.closed = false;
        for (&harness.active) |*active| switch (active.phase) {
            .start_adoption_recovery => {
                _ = active.session.recoverStartAdoption() catch {};
            },
            .running, .publication_fail_stop => {
                _ = active.session.cancel() catch {};
                active.session.deinit();
            },
            .empty => {},
        };
    }

    const running = try expectAccepted(
        try harness.service.admitV1(request(
            808,
            "unary-idempotency-running-before-recovery",
            "running-before-recovery",
            2,
        )),
    );
    fault_allocator.enabled = true;
    const recovery_handle = switch (try harness.service.admitV1(request(
        909,
        "unary-idempotency-start-recovery",
        "start-recovery",
        2,
    ))) {
        .recovery_required => |handle| handle,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(fault_allocator.triggered);
    try testing.expect(harness.scheduler.closed);
    const before_cancel = try harness.service.snapshotV1();
    switch (try harness.service.cancelV1(running.handle)) {
        .recovery_required => |notice| {
            try testing.expectEqualDeep(
                recovery_handle,
                notice.handle,
            );
            try testing.expectEqual(
                unary.ActivePhaseV1.start_adoption_recovery,
                notice.phase,
            );
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualDeep(
        before_cancel,
        try harness.service.snapshotV1(),
    );
    try testing.expectEqual(
        unary.ServiceStateV1.open,
        (try harness.service.snapshotV1()).state,
    );

    harness.scheduler.closed = false;
    switch (try harness.service.recoverV1(recovery_handle)) {
        .start_rolled_back => |event| try testing.expectEqual(
            engine.lane_weave_qos.EventKind.cancel,
            event.kind,
        ),
        else => return error.TestUnexpectedResult,
    }
    switch (try harness.service.cancelV1(running.handle)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }
    try expectZeroOwnership(try harness.service.snapshotV1());
    _ = try harness.service.closeV1();
}
