const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const core = engine.core;
const checkpoint_file = core.continuation_checkpoint_file;
const bank_api = engine.resource_bank;
const lane = engine.lane_weave_qos;
const prepared = engine.prepared_text_session;
const checkpoint = engine.prepared_text_checkpoint;
const source_lease = engine.prepared_text_source_lease;
const successor = engine.prepared_text_successor;
const archive = engine.prepared_text_handoff_archive;
const durable = engine.prepared_text_durable_handoff;
const restart_manifest = engine.prepared_text_restart_manifest;
const terminal = engine.prepared_text_terminal_equivalence;

const Digest = [32]u8;

const dim: usize = 64;
const hidden: usize = 64;
const vocab: usize = 64;
const num_layers: usize = 1;
const prompt = [_]u32{ 1, 2, 3 };
const options: prepared.OptionsV1 = .{ .max_new_tokens = 4 };

const source_bank_epoch: u64 = 0x5054_424b_0000_0001;
const source_scheduler_epoch: u64 = 0x5054_5343_0000_0001;
const source_coordinator_id: u64 = 0x5054_434f_0000_0001;
const target_bank_epoch: u64 = 0x5054_424b_0000_0002;
const target_scheduler_epoch: u64 = 0x5054_5343_0000_0002;
const target_coordinator_id: u64 = 0x5054_434f_0000_0002;
const storage_epoch: u64 = 0x5054_5354_0000_0001;
const request_epoch: u64 = 0x5054_5251_0000_0001;
const challenge = [_]u8{0x7c} ** 32;
const zero_digest = [_]u8{0} ** 32;
const max_authority_bytes: usize = 1024 * 1024;

const model_source_name = "prepared-text-fixture.safetensors";
const model_container_name = "prepared-text-fixture.glacier";
const model_image_name = "prepared-text-fixture.glrt";
const terminal_semantic_name = "prepared-text-terminal-semantic.bin";

const scheduling: prepared.SchedulingV1 = .{
    .tenant_key = 0x501,
    .request_key = 0x502,
    .request_generation = 1,
    .resource_owner_key = 0x503,
    .weight = 1,
};

const PreparedTextSink = struct {
    receipts: [options.max_new_tokens]engine.lane_publication_txn.CommitReceiptV1 =
        undefined,
    commit_calls: usize = 0,
    prepare_calls: usize = 0,
    abort_calls: usize = 0,

    fn interface(self: *PreparedTextSink) engine.lane_publication_txn.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        raw: *anyopaque,
        proposal: *const engine.lane_publication_txn.ProposalV1,
        ack: *engine.lane_publication_txn.PrepareAckV1,
    ) engine.lane_publication_txn.SinkPrepareError!void {
        const self: *PreparedTextSink = @ptrCast(@alignCast(raw));
        self.prepare_calls += 1;
        ack.* = .{
            .proposal_sha256 = engine.lane_publication_txn.proposalSha256(proposal.*),
            .sink_epoch = 0x5054_5349_4e4b_0001,
            .reservation_id = self.prepare_calls,
        };
    }

    fn commit(
        raw: *anyopaque,
        receipt: *const engine.lane_publication_txn.CommitReceiptV1,
    ) void {
        const self: *PreparedTextSink = @ptrCast(@alignCast(raw));
        if (self.commit_calls >= self.receipts.len)
            @panic("prepared-text fixture receipt capacity");
        self.receipts[self.commit_calls] = receipt.*;
        self.commit_calls += 1;
    }

    fn abort(
        raw: *anyopaque,
        _: *const engine.lane_publication_txn.ProposalV1,
        _: *const engine.lane_publication_txn.PrepareAckV1,
    ) void {
        const self: *PreparedTextSink = @ptrCast(@alignCast(raw));
        self.abort_calls += 1;
    }
};

const SourceRuntime = struct {
    bank_slots: [2]bank_api.Slot = undefined,
    lane_slots: [2]lane.Slot = undefined,
    projection_slots: [2]lane.ProjectionSlot = undefined,
    bank: bank_api.Bank = undefined,
    scheduler: lane.Scheduler = undefined,

    fn init(self: *SourceRuntime) !void {
        self.bank = try bank_api.Bank.init(
            &self.bank_slots,
            .{},
            source_bank_epoch,
        );
        self.scheduler = try lane.Scheduler.init(
            &self.bank,
            .{
                .slots = &self.lane_slots,
                .projection = &self.projection_slots,
            },
            .{
                .scheduler_epoch = source_scheduler_epoch,
                .coordinator_id = source_coordinator_id,
                .challenge = challenge,
                .max_weight = 1,
            },
        );
    }
};

const TargetRuntime = struct {
    bank_slots: [2]bank_api.Slot = undefined,
    tree_roots: [2]bank_api.LeaseTreeRootSlot = undefined,
    tree_nodes: [4]bank_api.LeaseNodeSlot = undefined,
    lane_slots: [2]lane.Slot = undefined,
    projection_slots: [2]lane.ProjectionSlot = undefined,
    bank: bank_api.Bank = undefined,
    scheduler: lane.Scheduler = undefined,

    fn init(
        self: *TargetRuntime,
        claim: bank_api.Claim,
    ) !void {
        self.bank = try bank_api.Bank.initWithLeaseTree(
            &self.bank_slots,
            &self.tree_roots,
            &self.tree_nodes,
            .{
                .host_bytes = try claim.hostBytes(),
                .capsule_bytes = claim.capsule_bytes,
                .kv_bytes = claim.kv_bytes,
                .activation_bytes = claim.activation_bytes,
                .partial_bytes = claim.partial_bytes,
                .logits_bytes = claim.logits_bytes,
                .output_journal_bytes = claim.output_journal_bytes,
                .staging_bytes = claim.staging_bytes,
                .device_bytes = claim.device_bytes,
                .io_bytes = claim.io_bytes,
                .queue_slots = claim.queue_slots,
            },
            target_bank_epoch,
        );
        self.scheduler = try lane.Scheduler.initWithLeaseTree(
            &self.bank,
            .{
                .slots = &self.lane_slots,
                .projection = &self.projection_slots,
            },
            .{
                .scheduler_epoch = target_scheduler_epoch,
                .coordinator_id = target_coordinator_id,
                .challenge = challenge,
                .max_weight = 1,
            },
        );
    }
};

const SourceCheckpointV1 = struct {
    boundary: prepared.BoundarySnapshotV2,
    expected: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len < 3 or arguments.len > 4)
        return error.InvalidArguments;

    if (std.mem.eql(u8, arguments[1], "baseline")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runBaselineV1(allocator, arguments[2]);
    } else if (std.mem.eql(u8, arguments[1], "source")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runSourceV1(allocator, arguments[2]);
    } else if (std.mem.eql(u8, arguments[1], "target")) {
        if (arguments.len != 4) return error.InvalidArguments;
        try runTargetV1(allocator, arguments[2], arguments[3]);
    } else if (std.mem.eql(u8, arguments[1], "probe-lock")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try probeLockV1(allocator, arguments[2]);
    } else return error.InvalidArguments;
}

fn runBaselineV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
) !void {
    try writePreparedFixtureV1(
        allocator,
        absolute_directory,
    );
    const image_path = try modelPathV1(
        allocator,
        absolute_directory,
        model_image_name,
    );
    defer allocator.free(image_path);
    var model = try engine.loader.loadPrepared(allocator, image_path);
    defer model.deinit();

    var runtime: SourceRuntime = .{};
    try runtime.init();
    var runtime_closed = false;
    defer if (!runtime_closed) {
        _ = runtime.scheduler.close() catch {};
    };
    const local_plan = try prepared.makePlanV1(model, &prompt, options);
    const source_bound_input = try boundInputV1();
    const source_bound_plan = try prepared.makeBoundPlanV1(
        model,
        &prompt,
        options,
        local_plan,
        scheduling,
        &runtime.scheduler,
        source_bound_input,
    );
    var session: prepared.SessionV3 = .{};
    defer session.deinit();
    try requireStartedV1(try session.start(
        allocator,
        &model,
        &prompt,
        options,
        local_plan,
        source_bound_input,
        source_bound_plan,
        scheduling,
        &runtime.scheduler,
        &runtime.bank,
    ));
    var sink: PreparedTextSink = .{};
    while (!session.isFinished()) {
        _ = try session.step(
            try runtime.scheduler.prepareService(),
            sink.interface(),
        );
    }
    if (sink.commit_calls != options.max_new_tokens)
        return error.InvalidBaselineSequence;
    _ = try session.sealTerminalResult();
    const boundary = try session.snapshotVerified();
    const semantic = try terminal.makeV1(
        boundary,
        session.inner.bound_plan,
        local_plan,
        session.outputTokens(),
        engine.lane_contiguous_publication.logicalKvPrefixSha256(
            &session.inner.inner.resources.cache,
            session.inner.inner.resources.cache.len,
        ),
    );
    var encoded_semantic: [terminal.semantic_bytes]u8 = undefined;
    _ = try terminal.encodeV1(semantic, &encoded_semantic);
    var directory = try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();
    try writeSyncedFileV1(
        directory,
        terminal_semantic_name,
        &encoded_semantic,
    );
    _ = try session.retire();
    const final_bank = try runtime.bank.snapshotV3();
    if (!final_bank.used.isZero() or
        final_bank.active_lease_trees != 0 or
        final_bank.active_lease_scopes != 0 or
        final_bank.active_lease_nodes != 0 or
        (try runtime.scheduler.snapshot()).active != 0)
        return error.BaselineAuthorityLeak;
    _ = try runtime.scheduler.close();
    runtime_closed = true;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.prepared-text-live-restart/" ++
            "baseline-v1\",\"phase\":\"baseline\",\"pid\":{d}," ++
            "\"terminal_next_sequence\":4,\"terminal_semantic\":true," ++
            "\"bank_zero\":true,\"scheduler_zero\":true," ++
            "\"verified\":true}}\n",
        .{currentProcessId()},
    );
    try stdout.flush();
}

fn runSourceV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
) !void {
    const image_path = try modelPathV1(
        allocator,
        absolute_directory,
        model_image_name,
    );
    defer allocator.free(image_path);
    var model = try engine.loader.loadPrepared(allocator, image_path);
    defer model.deinit();

    // The selector lease is acquired before the source becomes live. A target
    // can therefore never observe or claim this directory concurrently with
    // the live source authority.
    var directory = try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();
    const active_storage = try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(active_storage);
    var lock_storage: [1]u8 = undefined;
    const live_storage = try allocator.alloc(
        u8,
        checkpoint_file.set_payload_offset +
            durable.source_live_marker.len +
            checkpoint_file.set_footer_bytes,
    );
    defer allocator.free(live_storage);
    const live_set = try durable.encodeSourceLiveSetV1(
        request_epoch,
        1,
        challenge,
        live_storage,
    );
    const live_selector =
        try checkpoint_file.prepareInitialSelectorV1(live_set);
    var lease = try checkpoint_file.LeaseV1.create(
        directory,
        storage_epoch,
        challenge,
        live_set,
        live_selector,
        max_authority_bytes,
        &lock_storage,
        active_storage,
    );
    defer lease.close();
    var source_live_grant: source_lease.SourceLiveGrantV1 = .{};
    try source_lease.initSourceLiveGrantV1(
        &source_live_grant,
        &lease,
    );
    defer if (source_live_grant.lease != null and
        (source_live_grant.phase == .ready or
            source_live_grant.phase == .bound))
    {
        source_lease.releaseSourceLiveGrantV1(
            &source_live_grant,
        ) catch {};
    };

    var source_runtime: SourceRuntime = .{};
    try source_runtime.init();
    var source_closed = false;
    defer if (!source_closed) {
        _ = source_runtime.scheduler.close() catch {};
    };

    const local_plan = try prepared.makePlanV1(model, &prompt, options);
    const source_bound_input = try boundInputV1();
    const source_bound_plan = try prepared.makeBoundPlanV1(
        model,
        &prompt,
        options,
        local_plan,
        scheduling,
        &source_runtime.scheduler,
        source_bound_input,
    );

    // The target is the first and only Scheduler in its fresh process.
    const target = try targetOwnershipForCoordinatorV1(
        target_coordinator_id,
        source_bound_plan,
    );

    var session: prepared.SessionV3 = .{};
    defer session.deinit();
    const started = try session.start(
        allocator,
        &model,
        &prompt,
        options,
        local_plan,
        source_bound_input,
        source_bound_plan,
        scheduling,
        &source_runtime.scheduler,
        &source_runtime.bank,
    );
    try requireStartedV1(started);
    var sink: PreparedTextSink = .{};
    _ = try session.step(
        try source_runtime.scheduler.prepareService(),
        sink.interface(),
    );
    if (sink.commit_calls != 1) return error.InvalidSourceSequence;
    try session.attachSourceLiveGrantV1(
        &source_live_grant,
    );

    const encoded_checkpoint = try session.captureCheckpointV1(
        allocator,
        challenge,
    );
    defer allocator.free(encoded_checkpoint);
    const context = try checkpointContextV1(
        &session,
        &model,
        source_bound_plan,
        local_plan,
    );
    if (context.boundary.base.publication.next_sequence !=
        lease.selector.publication_next_sequence)
        return error.SourceSelectorDrift;
    const manifest_bytes = try restart_manifest.encodedBytesV1(
        prompt.len,
    );
    const manifest_storage = try allocator.alloc(
        u8,
        manifest_bytes,
    );
    defer allocator.free(manifest_storage);
    const encoded_manifest = try restart_manifest.encodeV1(
        .{
            .prompt = &prompt,
            .options = options,
            .plan = local_plan,
            .bound_plan = source_bound_plan,
            .expected_checkpoint = context.expected,
            .source = context.source,
            .target = target,
        },
        manifest_storage,
    );
    const evidence_bytes =
        try archive.encodedRestartArchiveBytesV1(
            encoded_checkpoint.len,
            encoded_manifest.bytes.len,
        );
    const evidence_storage = try allocator.alloc(
        u8,
        evidence_bytes,
    );
    defer allocator.free(evidence_storage);
    const evidence = try archive.encodeRestartArchiveV1(
        1,
        zero_digest,
        encoded_checkpoint,
        encoded_manifest.bytes,
        evidence_storage,
    );
    const predecessor_selector_sha256 = lease.selectorRoot();
    _ = try session.beginDurableHandoffV1(
        encoded_checkpoint,
        challenge,
        target,
        evidence.set.checkpoint_sha256,
        predecessor_selector_sha256,
    );
    try session.validateDurableHandoffV1();
    const source_exit = try session.commitDurableHandoffV1();

    const authority_bytes =
        try durable.encodedSourceExitedSetBytesV1(evidence.set.bytes.len);
    const authority_storage = try allocator.alloc(u8, authority_bytes);
    defer allocator.free(authority_storage);
    const authority = try durable.encodeSourceExitedSetV1(
        evidence,
        source_exit,
        live_set.checkpoint_sha256,
        authority_storage,
    );
    const publication =
        try checkpoint_file.preparePublicationV1(&lease, authority);
    const applied = try checkpoint_file.publishV1(&lease, publication);
    if (applied.disposition != .applied or
        !std.mem.eql(
            u8,
            &applied.checkpoint_sha256,
            &authority.checkpoint_sha256,
        ))
        return error.AuthorityPublicationFailed;
    try session.completeDurableHandoffV1(.{
        .checkpoint_sha256 = applied.checkpoint_sha256,
        .selector_sha256 = applied.selector_sha256,
    });
    if (source_live_grant.phase != .completed)
        return error.SourceGrantNotCompleted;

    const source_bank = try source_runtime.bank.snapshotV3();
    const source_scheduler = try source_runtime.scheduler.snapshot();
    if (!source_bank.used.isZero() or
        source_bank.active_lease_trees != 0 or
        source_bank.active_lease_scopes != 0 or
        source_bank.active_lease_nodes != 0 or
        source_scheduler.active != 0)
        return error.SourceAuthorityLeak;
    _ = try source_runtime.scheduler.close();
    source_closed = true;

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    const manifest_hex = std.fmt.bytesToHex(
        encoded_manifest.manifest_sha256,
        .lower,
    );
    try stdout.print(
        "{{\"schema\":\"glacier.prepared-text-live-restart/source-v1\"," ++
            "\"phase\":\"source\",\"pid\":{d},\"sequence\":{d}," ++
            "\"restart_manifest_sha256\":\"{s}\"," ++
            "\"source_bank_zero\":true,\"source_scheduler_zero\":true," ++
            "\"source_tree_zero\":true,\"selector_generation\":2," ++
            "\"verified\":true}}\n",
        .{
            currentProcessId(),
            context.boundary.base.publication.next_sequence,
            &manifest_hex,
        },
    );
    try stdout.flush();
}

fn runTargetV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    expected_manifest_hex: []const u8,
) !void {
    var directory = try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();
    const active_storage = try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(active_storage);
    var lock_storage: [1]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        challenge,
        max_authority_bytes,
        &lock_storage,
        active_storage,
    );
    defer {
        if (lease.consumer_claim) |claim| {
            lease.releaseConsumerClaimV1(claim) catch {};
        }
        lease.close();
    }
    if (lease.selector.generation != durable.source_exited_set_generation)
        return error.InvalidSelectedGeneration;
    try proveExclusiveLeaseV1(allocator, absolute_directory);

    const image_path = try modelPathV1(
        allocator,
        absolute_directory,
        model_image_name,
    );
    defer allocator.free(image_path);
    var model = try engine.loader.loadPrepared(allocator, image_path);
    defer model.deinit();

    // The parent transports the manifest root emitted by the retired source.
    // The manifest bytes themselves live inside the selector-selected archive;
    // no mutable context sidecar participates in target reconstruction.
    var expected_manifest_sha256: Digest = undefined;
    if (expected_manifest_hex.len !=
        expected_manifest_sha256.len * 2)
        return error.InvalidRestartManifestRoot;
    _ = std.fmt.hexToBytes(
        &expected_manifest_sha256,
        expected_manifest_hex,
    ) catch return error.InvalidRestartManifestRoot;

    const live_storage = try allocator.alloc(
        u8,
        checkpoint_file.set_payload_offset +
            durable.source_live_marker.len +
            checkpoint_file.set_footer_bytes,
    );
    defer allocator.free(live_storage);
    const expected_live = try durable.encodeSourceLiveSetV1(
        request_epoch,
        1,
        challenge,
        live_storage,
    );
    const decoded = try durable.decodeSourceExitedSetV1(
        lease.stream(),
        lease.selector,
        expected_live.checkpoint_sha256,
    );
    const recovered_manifest = decoded.evidence.manifest;
    if (!std.mem.eql(
        u8,
        &recovered_manifest.manifest_sha256,
        &expected_manifest_sha256,
    ))
        return error.InvalidRestartManifestRoot;
    const recovered_prompt = try allocator.alloc(
        u32,
        recovered_manifest.promptCount(),
    );
    defer allocator.free(recovered_prompt);
    for (recovered_prompt, 0..) |*token, index| {
        token.* = try recovered_manifest.promptToken(index);
    }
    const local_plan = try prepared.makePlanV1(
        model,
        recovered_prompt,
        recovered_manifest.options,
    );
    if (!std.meta.eql(local_plan, recovered_manifest.plan))
        return error.InvalidRestartManifest;
    try prepared.validateBoundPlanV1(
        recovered_manifest.bound_plan,
    );

    var encoded_oracle: [terminal.semantic_bytes]u8 = undefined;
    try readExactFileV1(
        directory,
        terminal_semantic_name,
        &encoded_oracle,
    );
    const oracle_semantic = try terminal.decodeV1(&encoded_oracle);

    var target_runtime: TargetRuntime = .{};
    try target_runtime.init(
        recovered_manifest.bound_plan.residency.request_claim,
    );
    var target_closed = false;
    defer if (!target_closed) {
        _ = target_runtime.scheduler.close() catch {};
    };
    const target = try targetOwnershipV1(
        &target_runtime.scheduler,
        recovered_manifest.bound_plan,
    );
    if (!std.meta.eql(target, recovered_manifest.target))
        return error.TargetOwnershipDrift;

    try activateSelectedSourceExitV1(
        allocator,
        &model,
        recovered_prompt,
        recovered_manifest.options,
        local_plan,
        recovered_manifest.bound_plan,
        recovered_manifest.expected_checkpoint,
        recovered_manifest.source,
        target,
        &target_runtime,
        &lease,
        decoded,
        oracle_semantic,
    );
    if (lease.selector.generation != durable.terminal_set_generation)
        return error.TerminalSelectionFailed;
    _ = try target_runtime.scheduler.close();
    target_closed = true;

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.prepared-text-live-restart/demo-v1\"," ++
            "\"phase\":\"target\",\"pid\":{d},\"process_restart\":true," ++
            "\"exclusive_lease\":true,\"sequence_base\":1," ++
            "\"terminal_next_sequence\":4,\"duplicate_sequences\":0," ++
            "\"source_resurrection\":false," ++
            "\"selector_generation\":3," ++
            "\"terminal_semantic_equal\":true,\"target_bank_zero\":true," ++
            "\"target_scheduler_zero\":true,\"target_tree_zero\":true," ++
            "\"verified\":true}}\n",
        .{currentProcessId()},
    );
    try stdout.flush();
}

fn activateSelectedSourceExitV1(
    allocator: std.mem.Allocator,
    model: *const engine.loader.LoadedModel,
    recovered_prompt: []const u32,
    recovered_options: prepared.OptionsV1,
    local_plan: prepared.PlanV1,
    source_bound_plan: prepared.BoundPlanV1,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
    target_runtime: *TargetRuntime,
    lease: *checkpoint_file.LeaseV1,
    decoded: durable.DecodedSourceExitedSetV1,
    oracle_semantic: terminal.TerminalSemanticV1,
) !void {
    const encoded_plan = try decoded.evidence.archive.object(
        .extension,
        archive.successor_plan_object_ordinal,
    );
    const encoded_residency = try decoded.evidence.archive.object(
        .extension,
        archive.successor_residency_object_ordinal,
    );
    const encoded_segment = try decoded.evidence.archive.object(
        .extension,
        archive.successor_segment_object_ordinal,
    );
    const restore_evidence: engine.prepared_text_restore_admission.EvidenceV1 = .{
        .encoded_plan = encoded_plan.bytes,
        .encoded_residency = encoded_residency.bytes,
        .encoded_segment = encoded_segment.bytes,
        .encoded_checkpoint = decoded.evidence.checkpoint.encoded,
        .expected_checkpoint = expected_checkpoint,
        .source = source,
        .target = target,
    };
    var activation_grant: engine.prepared_text_restore_admission.SelectedSourceExitGrantV1 = .{};
    try durable.initSelectedSourceExitGrantV1(
        &activation_grant,
        lease,
        decoded,
    );
    var competing_grant: engine.prepared_text_restore_admission.SelectedSourceExitGrantV1 = .{};
    if (durable.initSelectedSourceExitGrantV1(
        &competing_grant,
        lease,
        decoded,
    )) |_|
        return error.ConcurrentActivationGrantAccepted
    else |err| {
        if (err != durable.Error.InvalidActivationGrant)
            return err;
    }

    var restored_session: prepared.SessionV3 = .{};
    const decision = try engine.prepared_text_restore_admission
        .prepareRestoredAdmissionV1(
        &target_runtime.scheduler,
        &target_runtime.bank,
        restored_session.restoredPublicationSessionIdV1(),
        restore_evidence,
        &activation_grant,
    );
    var prepared_restore = switch (decision) {
        .prepared => |value| value,
        .rejected => return error.TargetAdmissionRejected,
        .recovery_required => return error.TargetRecoveryRequired,
    };
    try engine.prepared_text_restore_admission
        .validatePreparedRestoredAdmissionV1(
        &prepared_restore,
        restore_evidence,
        &activation_grant,
    );
    try restored_session.startRestoredV1(
        allocator,
        model,
        recovered_prompt,
        recovered_options,
        local_plan,
        source_bound_plan,
        &prepared_restore,
        restore_evidence,
        &activation_grant,
    );
    if (activation_grant.phase != .consumed)
        return error.ActivationGrantNotConsumed;

    var sink: PreparedTextSink = .{};
    while (!restored_session.isFinished()) {
        _ = try restored_session.step(
            try target_runtime.scheduler.prepareService(),
            sink.interface(),
        );
    }
    const sequence_base: usize = @intCast(
        expected_checkpoint.publication_next_sequence,
    );
    if (sink.commit_calls !=
        recovered_options.max_new_tokens - sequence_base)
        return error.InvalidRestoredSequence;
    for (sink.receipts[0..sink.commit_calls], 0..) |receipt, index| {
        const expected_sequence =
            expected_checkpoint.publication_next_sequence +
            @as(u64, @intCast(index));
        if (receipt.proposal.sequence_base !=
            expected_checkpoint.publication_next_sequence or
            receipt.proposal.transaction_sequence != expected_sequence)
            return error.DuplicateOrMissingSequence;
    }

    const terminal_boundary = try restored_session.snapshotVerified();
    if (terminal_boundary.base.publication.next_sequence !=
        @as(u64, @intCast(recovered_options.max_new_tokens)))
        return error.InvalidTerminalSequence;
    const restored_semantic = try terminal.makeV1(
        terminal_boundary,
        restored_session.inner.bound_plan,
        local_plan,
        restored_session.outputTokens(),
        engine.lane_contiguous_publication.logicalKvPrefixSha256(
            &restored_session.inner.inner.resources.cache,
            restored_session.inner.inner.resources.cache.len,
        ),
    );
    if (!terminal.equivalentV1(oracle_semantic, restored_semantic))
        return error.TerminalSemanticMismatch;

    var source_selector_bytes: [checkpoint_file.selector_bytes]u8 =
        undefined;
    try readExactFileV1(
        lease.directory,
        checkpoint_file.active_selector_name,
        &source_selector_bytes,
    );
    const source_selector_decoded =
        try checkpoint_file.decodeSelectorV1(&source_selector_bytes);
    if (!std.meta.eql(source_selector_decoded, lease.selector))
        return error.SourceSelectorDrift;
    const source_exited_set: checkpoint_file.PreparedSetV1 = .{
        .bytes = lease.stream(),
        .checkpoint_sha256 = decoded.authority_archive.checkpoint_sha256,
    };
    const source_exited_selector: checkpoint_file.PreparedSelectorV1 = .{
        .bytes = source_selector_bytes,
        .selector_sha256 = source_selector_decoded.selector_sha256,
    };
    const terminal_bytes = try durable.encodedTerminalSetBytesV1(
        source_exited_set.bytes.len,
    );
    const terminal_storage = try allocator.alloc(u8, terminal_bytes);
    defer allocator.free(terminal_storage);
    const terminal_set = try durable.encodeTerminalSetV1(
        source_exited_set,
        source_exited_selector,
        restored_semantic,
        terminal_storage,
    );
    const terminal_publication =
        try checkpoint_file.preparePublicationV1(
            lease,
            terminal_set,
        );
    const terminal_applied = try checkpoint_file.publishV1(
        lease,
        terminal_publication,
    );
    if (terminal_applied.disposition != .applied)
        return error.TerminalSelectionFailed;
    try durable.markTerminalSelectedV1(
        &activation_grant,
        restored_semantic,
    );
    _ = try restored_session.retire();
    if (activation_grant.phase != .completed)
        return error.ActivationGrantNotCompleted;

    const target_bank = try target_runtime.bank.snapshotV3();
    if (!target_bank.used.isZero() or
        target_bank.active_lease_trees != 0 or
        target_bank.active_lease_scopes != 0 or
        target_bank.active_lease_nodes != 0 or
        target_bank.live_allocations != 0 or
        (try target_runtime.scheduler.snapshot()).active != 0)
        return error.TargetAuthorityLeak;

    if (engine.prepared_text_restore_admission
        .prepareRestoredAdmissionV1(
        &target_runtime.scheduler,
        &target_runtime.bank,
        restored_session.restoredPublicationSessionIdV1(),
        restore_evidence,
        &activation_grant,
    )) |_|
        return error.ActivationGrantReplayAccepted
    else |err| {
        if (err != engine.prepared_text_restore_admission
            .Error.InvalidActivationGrant)
            return err;
    }
}

fn checkpointContextV1(
    session: *prepared.SessionV3,
    model: *const engine.loader.LoadedModel,
    bound_plan: prepared.BoundPlanV1,
    local_plan: prepared.PlanV1,
) !SourceCheckpointV1 {
    const boundary = try session.snapshotVerified();
    const cache = &session.inner.inner.resources.cache;
    const expected: checkpoint.ExpectedBindingsV1 = .{
        .local_plan_sha256 = local_plan.plan_sha256,
        .bound_plan_sha256 = bound_plan.bound_plan_sha256,
        .artifact_sha256 = bound_plan.artifact.artifact_sha256,
        .execution_plan_sha256 = bound_plan.execution.plan_sha256,
        .residency_binding_sha256 = bound_plan.residency.binding_sha256,
        .boundary_sha256 = boundary.boundary_sha256,
        .transcript_sha256 = boundary.base.publication.transcript_sha256,
        .state_commitment_sha256 = boundary.base.publication.state.commitment_sha256,
        .request_epoch = request_epoch,
        .publication_next_sequence = boundary.base.publication.next_sequence,
        .prompt_tokens = local_plan.prompt_tokens,
        .max_new_tokens = local_plan.max_new_tokens,
        .vocab_size = @intCast(model.config.vocab_size),
        .num_layers = @intCast(cache.num_layers),
        .kv_dim = @intCast(cache.dim),
        .max_kv_positions = @intCast(cache.max_seq),
        .kv_positions = @intCast(cache.len),
        .output_count = @intCast(session.outputTokens().len),
        .sampling_calls = session.inner.inner.sampling_calls,
        .challenge_sha256 = challenge,
    };
    return .{
        .boundary = boundary,
        .expected = expected,
        .source = .{
            .bound_plan_sha256 = bound_plan.bound_plan_sha256,
            .execution = bound_plan.execution,
            .residency = bound_plan.residency,
            .boundary_sha256 = boundary.boundary_sha256,
            .publication = boundary.base.publication,
            .receipt = session.result_receipt,
        },
    };
}

fn targetOwnershipV1(
    scheduler: *lane.Scheduler,
    source_bound_plan: prepared.BoundPlanV1,
) !successor.TargetOwnershipV1 {
    const identity = try scheduler.identityV1();
    if (identity.scheduler_epoch != target_scheduler_epoch or
        identity.coordinator_id != target_coordinator_id)
        return error.InvalidTargetIdentity;
    return targetOwnershipForCoordinatorV1(
        identity.coordinator_id,
        source_bound_plan,
    );
}

fn targetOwnershipForCoordinatorV1(
    coordinator_id: u64,
    source_bound_plan: prepared.BoundPlanV1,
) !successor.TargetOwnershipV1 {
    const generation = try std.math.add(
        u64,
        source_bound_plan.execution.generation,
        1,
    );
    return .{
        .scheduler_epoch = target_scheduler_epoch,
        .coordinator_id = coordinator_id,
        .bank_epoch = target_bank_epoch,
        .request_generation = generation,
        .resource_owner_key = 0x601,
        .tree_key = 0x602,
        .authority_key = 0x603,
        .tenant_key = 0x604,
        .scope_key = 0x605,
        .cache_node_key = 0x606,
        .cache_binding_key = 0x607,
        .intent_generation = generation,
        .request_claim = source_bound_plan.residency.request_claim,
    };
}

fn proveExclusiveLeaseV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
) !void {
    const executable_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable_path);
    const probe = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            executable_path,
            "probe-lock",
            absolute_directory,
        },
        .max_output_bytes = 4096,
    });
    defer allocator.free(probe.stdout);
    defer allocator.free(probe.stderr);
    try expectSuccessV1(probe.term);
    if (probe.stderr.len != 0 or
        std.mem.indexOf(
            u8,
            probe.stdout,
            "\"would_block\":true",
        ) == null)
        return error.InvalidLeaseProbe;
}

fn probeLockV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
) !void {
    var directory = try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();
    const active_storage = try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(active_storage);
    var lock_storage: [1]u8 = undefined;
    if (checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        challenge,
        max_authority_bytes,
        &lock_storage,
        active_storage,
    )) |lease_value| {
        var lease = lease_value;
        lease.close();
        return error.ExclusiveLeaseNotHeld;
    } else |err| {
        if (err != error.WouldBlock) return err;
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        "{\"phase\":\"probe-lock\",\"would_block\":true,\"verified\":true}\n",
    );
    try stdout.flush();
}

fn writeSyncedFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    const file = try directory.createFile(name, .{
        .read = true,
        .truncate = true,
        .exclusive = true,
        .mode = 0o600,
    });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

fn readExactFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    destination: []u8,
) !void {
    const file = try directory.openFile(name, .{});
    defer file.close();
    if (try file.readAll(destination) != destination.len)
        return error.TruncatedFixtureFile;
    var trailing: [1]u8 = undefined;
    if (try file.read(&trailing) != 0)
        return error.OversizedFixtureFile;
}

fn writePreparedFixtureV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
) !void {
    const source_path = try modelPathV1(
        allocator,
        absolute_directory,
        model_source_name,
    );
    defer allocator.free(source_path);
    const container_path = try modelPathV1(
        allocator,
        absolute_directory,
        model_container_name,
    );
    defer allocator.free(container_path);
    const image_path = try modelPathV1(
        allocator,
        absolute_directory,
        model_image_name,
    );
    defer allocator.free(image_path);

    try writeTinyModelSafetensorsV1(allocator, source_path);
    _ = try engine.converter.convertSafetensors(
        allocator,
        source_path,
        container_path,
        .{
            .quantize_int4 = true,
            .quant_group_size = 16,
            .page_size_bytes = 1 << 16,
        },
    );
    var reader = try engine.model.FileReader.open(
        allocator,
        container_path,
    );
    defer reader.close();
    var compact = try engine.loader.loadWithOptions(
        allocator,
        &reader,
        .{},
        .{ .compact_int4 = true },
    );
    defer compact.deinit();
    try engine.loader.writePrepared(
        allocator,
        &compact,
        image_path,
        compact.source_fingerprint,
    );
}

fn writeTinyModelSafetensorsV1(
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    var rng = std.Random.DefaultPrng.init(2024);
    const TensorEntry = struct {
        name: []const u8,
        dims: [4]usize,
        n_dims: u8,
        offset: u64,
        len: u64,
    };
    var tensors: std.ArrayList(TensorEntry) = .{};
    defer {
        for (tensors.items) |tensor| {
            if (std.mem.startsWith(
                u8,
                tensor.name,
                "model.layers.",
            )) allocator.free(tensor.name);
        }
        tensors.deinit(allocator);
    }
    var offset: u64 = 0;
    try tensors.append(allocator, .{
        .name = "model.embed_tokens.weight",
        .dims = .{ vocab, dim, 0, 0 },
        .n_dims = 2,
        .offset = offset,
        .len = vocab * dim * @sizeOf(f32),
    });
    offset += vocab * dim * @sizeOf(f32);

    const LayerSpec = struct {
        suffix: []const u8,
        dims: [4]usize,
        n_dims: u8,
    };
    const layer_specs = [_]LayerSpec{
        .{
            .suffix = "input_layernorm.weight",
            .dims = .{ dim, 0, 0, 0 },
            .n_dims = 1,
        },
        .{
            .suffix = "self_attn.q_proj.weight",
            .dims = .{ dim, dim, 0, 0 },
            .n_dims = 2,
        },
        .{
            .suffix = "self_attn.k_proj.weight",
            .dims = .{ dim, dim, 0, 0 },
            .n_dims = 2,
        },
        .{
            .suffix = "self_attn.v_proj.weight",
            .dims = .{ dim, dim, 0, 0 },
            .n_dims = 2,
        },
        .{
            .suffix = "self_attn.o_proj.weight",
            .dims = .{ dim, dim, 0, 0 },
            .n_dims = 2,
        },
        .{
            .suffix = "post_attention_layernorm.weight",
            .dims = .{ dim, 0, 0, 0 },
            .n_dims = 1,
        },
        .{
            .suffix = "mlp.gate_proj.weight",
            .dims = .{ hidden, dim, 0, 0 },
            .n_dims = 2,
        },
        .{
            .suffix = "mlp.up_proj.weight",
            .dims = .{ hidden, dim, 0, 0 },
            .n_dims = 2,
        },
        .{
            .suffix = "mlp.down_proj.weight",
            .dims = .{ dim, hidden, 0, 0 },
            .n_dims = 2,
        },
    };
    for (0..num_layers) |layer_index| {
        for (layer_specs) |spec| {
            var elements: usize = 1;
            for (spec.dims[0..spec.n_dims]) |extent|
                elements *= extent;
            const name = try std.fmt.allocPrint(
                allocator,
                "model.layers.{d}.{s}",
                .{ layer_index, spec.suffix },
            );
            try tensors.append(allocator, .{
                .name = name,
                .dims = spec.dims,
                .n_dims = spec.n_dims,
                .offset = offset,
                .len = elements * @sizeOf(f32),
            });
            offset += elements * @sizeOf(f32);
        }
    }
    try tensors.append(allocator, .{
        .name = "model.norm.weight",
        .dims = .{ dim, 0, 0, 0 },
        .n_dims = 1,
        .offset = offset,
        .len = dim * @sizeOf(f32),
    });
    offset += dim * @sizeOf(f32);
    try tensors.append(allocator, .{
        .name = "lm_head.weight",
        .dims = .{ vocab, dim, 0, 0 },
        .n_dims = 2,
        .offset = offset,
        .len = vocab * dim * @sizeOf(f32),
    });

    var json_storage: [16 * 1024]u8 = undefined;
    var json_stream = std.io.fixedBufferStream(&json_storage);
    const json = json_stream.writer();
    try json.writeAll("{");
    for (tensors.items, 0..) |tensor, tensor_index| {
        if (tensor_index != 0) try json.writeAll(",");
        try json.print(
            "\"{s}\":{{\"dtype\":\"F32\",\"shape\":[",
            .{tensor.name},
        );
        for (
            tensor.dims[0..tensor.n_dims],
            0..,
        ) |extent, dimension_index| {
            if (dimension_index != 0) try json.writeAll(",");
            try json.print("{d}", .{extent});
        }
        try json.print(
            "],\"data_offsets\":[{d},{d}]}}",
            .{ tensor.offset, tensor.offset + tensor.len },
        );
    }
    try json.writeAll(",\"__metadata__\":{\"format\":\"pt\"}}");
    const header = json_storage[0..json_stream.pos];

    const file = try std.fs.cwd().createFile(
        path,
        .{ .truncate = true },
    );
    defer file.close();
    var header_length: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &header_length,
        @intCast(header.len),
        .little,
    );
    try file.writeAll(&header_length);
    try file.writeAll(header);
    for (tensors.items) |tensor| {
        var elements: usize = 1;
        for (tensor.dims[0..tensor.n_dims]) |extent|
            elements *= extent;
        const scale: f32 = if (std.mem.indexOf(
            u8,
            tensor.name,
            "embed",
        ) != null or std.mem.indexOf(
            u8,
            tensor.name,
            "lm_head",
        ) != null)
            0.02
        else if (std.mem.indexOf(
            u8,
            tensor.name,
            "layernorm",
        ) != null)
            0.05
        else
            0.04;
        var encoded: [4]u8 = undefined;
        for (0..elements) |_| {
            const value = rng.random().floatNorm(f32) * scale;
            std.mem.writeInt(
                u32,
                &encoded,
                @bitCast(value),
                .little,
            );
            try file.writeAll(&encoded);
        }
    }
    try file.sync();
}

fn modelPathV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    basename: []const u8,
) ![]u8 {
    return std.fs.path.join(
        allocator,
        &.{ absolute_directory, basename },
    );
}

fn boundInputV1() !prepared.BoundPlanInputV1 {
    var token_domain_sha256: Digest = undefined;
    var token_domain_config_sha256: Digest = undefined;
    var artifact_license_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &token_domain_sha256,
        "5584ae387491b4341f88923c7f007941" ++
            "dfe66f9c9c454c95f3c223a537bc7b1e",
    );
    _ = try std.fmt.hexToBytes(
        &token_domain_config_sha256,
        "6a3978006201ad2f4b9a4fcaa1a1d73b" ++
            "2aa5537aa9478ee8dce3847ddfe8b867",
    );
    _ = try std.fmt.hexToBytes(
        &artifact_license_sha256,
        "b00a881ca2efe9ca1a7ecf22029e80d7" ++
            "1e70c7b802f81466c761aa3ed9626cef",
    );
    return .{
        .request_epoch = request_epoch,
        .token_domain_sha256 = token_domain_sha256,
        .token_domain_config_sha256 = token_domain_config_sha256,
        .artifact_license_sha256 = artifact_license_sha256,
    };
}

fn requireStartedV1(decision: prepared.StartDecisionV1) !void {
    switch (decision) {
        .started => {},
        .rejected => return error.SourceAdmissionRejected,
    }
}

fn expectSuccessV1(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| if (code != 0)
            return error.WorkerFailed,
        else => return error.WorkerFailed,
    }
}

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}
