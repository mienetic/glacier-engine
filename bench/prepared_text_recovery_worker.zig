const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const core = engine.core;
const checkpoint_file = core.continuation_checkpoint_file;
const bank_api = engine.resource_bank;
const lane = engine.lane_weave_qos;
const publication = engine.lane_publication_txn;
const prepared = engine.prepared_text_session;
const checkpoint = engine.prepared_text_checkpoint;
const source_lease = engine.prepared_text_source_lease;
const successor = engine.prepared_text_successor;
const archive = engine.prepared_text_handoff_archive;
const durable = engine.prepared_text_durable_handoff;
const restart_manifest = engine.prepared_text_restart_manifest;
const restore = engine.prepared_text_restore_admission;
const terminal = engine.prepared_text_terminal_equivalence;
const result_sink = engine.prepared_text_result_sink;
const result_sink_file = engine.prepared_text_result_sink_file;
const source_recovery = engine.prepared_text_source_recovery;
const progress = engine.prepared_text_acknowledged_progress;
const acknowledged_restore =
    engine.prepared_text_acknowledged_restore;

const Digest = [32]u8;
const dim: usize = 64;
const hidden: usize = 64;
const vocab: usize = 64;
const num_layers: usize = 1;
const prompt = [_]u32{ 1, 2, 3 };
const options: prepared.OptionsV1 = .{ .max_new_tokens = 4 };
const sink_capacity: usize = options.max_new_tokens - 1;
const max_authority_bytes: usize = 1024 * 1024;
const max_result_ledger_bytes: usize =
    result_sink_file.ledger_header_bytes +
    sink_capacity * result_sink.acknowledgement_bytes +
    result_sink_file.ledger_footer_bytes;
const DurableResultSinkV1 =
    result_sink_file.ResultSinkFileV1(sink_capacity);

const storage_epoch: u64 = 0x5231_4953_0000_0001;
const sink_storage_epoch: u64 = 0x5231_4952_0000_0001;
const request_epoch: u64 = 0x5231_4951_0000_0001;
const source_bank_epoch: u64 = 0x5231_424b_0000_0001;
const source_scheduler_epoch: u64 = 0x5231_5343_0000_0001;
const source_coordinator_id: u64 = 0x5231_434f_0000_0001;
const target_bank_epoch_base: u64 = 0x5231_424b_0000_1000;
const target_scheduler_epoch_base: u64 = 0x5231_5343_0000_1000;
const target_coordinator_id_base: u64 = 0x5231_434f_0000_1000;
const target_key_base: u64 = 0x5231_4b59_0000_1000;
const challenge = [_]u8{0x7c} ** 32;
const zero_digest = [_]u8{0} ** 32;
const sink_implementation_sha256 = [_]u8{0x92} ** 32;
const sink_instance_sha256 = [_]u8{0x93} ** 32;

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

const CrashPoint = enum(u8) {
    bootstrap_checkpoint_archive_write,
    bootstrap_checkpoint_archive_sync,
    bootstrap_checkpoint_archive_directory_sync,
    bootstrap_checkpoint_selector_write,
    bootstrap_checkpoint_selector_sync,
    bootstrap_checkpoint_selector_rename,
    bootstrap_checkpoint_selector_directory_sync,

    source_after_recovery_admission,
    source_sink_ledger_body_write,
    source_sink_ledger_body_sync,
    source_sink_ledger_footer_write,
    source_sink_ledger_file_sync,
    source_sink_ledger_immutable_rename,
    source_sink_ledger_directory_sync,
    source_sink_selector_temp_write,
    source_sink_selector_temp_sync,
    source_sink_selector_replace,
    source_sink_selector_directory_sync,
    source_after_initial_sink,
    source_after_step,
    source_after_handoff_prepare,
    source_after_exit_commit,
    source_checkpoint_archive_write,
    source_checkpoint_archive_sync,
    source_checkpoint_archive_directory_sync,
    source_checkpoint_selector_write,
    source_checkpoint_selector_sync,
    source_checkpoint_selector_rename,
    source_checkpoint_selector_directory_sync,
    source_after_generation_two,

    after_step_before_sink,
    sink_ledger_body_write,
    sink_ledger_body_sync,
    sink_ledger_footer_write,
    sink_ledger_file_sync,
    sink_ledger_immutable_rename,
    sink_ledger_directory_sync,
    sink_selector_temp_write,
    sink_selector_temp_sync,
    sink_selector_replace,
    sink_selector_directory_sync,
    after_sink_before_selector,
    checkpoint_archive_write,
    checkpoint_archive_sync,
    checkpoint_archive_directory_sync,
    checkpoint_selector_write,
    checkpoint_selector_sync,
    checkpoint_selector_rename,
    checkpoint_selector_directory_sync,
};

const SinkDisposition = enum {
    none,
    applied,
    replayed,
};

const CrashController = struct {
    requested: ?CrashPoint,
    input_generation: u64,
    input_sequence: u64,
    sink_count: usize,
    sink_ledger_sha256: Digest,
    sink_selector_sha256: Digest,
    checkpoint_selector_sha256: Digest,
    successor_sink_count: usize = 0,
    successor_sink_ledger_sha256: Digest = zero_digest,
    successor_sink_selector_sha256: Digest = zero_digest,
    successor_checkpoint_selector_sha256: Digest = zero_digest,

    fn maybeCrash(
        self: *CrashController,
        point: CrashPoint,
    ) !void {
        if (self.requested == null or
            self.requested.? != point) return;
        try emitCrashReadyV1(self, point);
        try std.posix.raise(std.posix.SIG.KILL);
        unreachable;
    }

    fn afterSinkPhase(
        raw: *anyopaque,
        phase: result_sink_file.IoPhaseV1,
    ) result_sink_file.Error!void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        const point: CrashPoint = switch (phase) {
            .ledger_body_write => .sink_ledger_body_write,
            .ledger_body_sync => .sink_ledger_body_sync,
            .ledger_footer_write => .sink_ledger_footer_write,
            .ledger_file_sync => .sink_ledger_file_sync,
            .ledger_immutable_rename => .sink_ledger_immutable_rename,
            .ledger_directory_sync => .sink_ledger_directory_sync,
            .selector_temp_write => .sink_selector_temp_write,
            .selector_temp_sync => .sink_selector_temp_sync,
            .selector_replace => .sink_selector_replace,
            .selector_directory_sync => .sink_selector_directory_sync,
        };
        if (phase == .selector_replace or
            phase == .selector_directory_sync)
        {
            self.sink_count = self.successor_sink_count;
            self.sink_ledger_sha256 =
                self.successor_sink_ledger_sha256;
            self.sink_selector_sha256 =
                self.successor_sink_selector_sha256;
        }
        self.maybeCrash(point) catch
            return result_sink_file.Error.InjectedFault;
    }

    fn afterSourceSinkPhase(
        raw: *anyopaque,
        phase: result_sink_file.IoPhaseV1,
    ) result_sink_file.Error!void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        const point: CrashPoint = switch (phase) {
            .ledger_body_write => .source_sink_ledger_body_write,
            .ledger_body_sync => .source_sink_ledger_body_sync,
            .ledger_footer_write => .source_sink_ledger_footer_write,
            .ledger_file_sync => .source_sink_ledger_file_sync,
            .ledger_immutable_rename => .source_sink_ledger_immutable_rename,
            .ledger_directory_sync => .source_sink_ledger_directory_sync,
            .selector_temp_write => .source_sink_selector_temp_write,
            .selector_temp_sync => .source_sink_selector_temp_sync,
            .selector_replace => .source_sink_selector_replace,
            .selector_directory_sync => .source_sink_selector_directory_sync,
        };
        if (phase == .selector_replace or
            phase == .selector_directory_sync)
        {
            self.sink_count = self.successor_sink_count;
            self.sink_ledger_sha256 =
                self.successor_sink_ledger_sha256;
            self.sink_selector_sha256 =
                self.successor_sink_selector_sha256;
        }
        self.maybeCrash(point) catch
            return result_sink_file.Error.InjectedFault;
    }

    fn afterCheckpointPhase(
        raw: *anyopaque,
        phase: checkpoint_file.IoPhaseV1,
    ) checkpoint_file.Error!void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        const point: CrashPoint = switch (phase) {
            .archive_write => .checkpoint_archive_write,
            .archive_sync => .checkpoint_archive_sync,
            .archive_directory_sync => .checkpoint_archive_directory_sync,
            .selector_write => .checkpoint_selector_write,
            .selector_sync => .checkpoint_selector_sync,
            .selector_rename => .checkpoint_selector_rename,
            .selector_directory_sync => .checkpoint_selector_directory_sync,
        };
        if (phase == .selector_rename or
            phase == .selector_directory_sync)
        {
            self.checkpoint_selector_sha256 =
                self.successor_checkpoint_selector_sha256;
        }
        self.maybeCrash(point) catch
            return checkpoint_file.Error.PublicationMismatch;
    }

    fn afterBootstrapCheckpointPhase(
        raw: *anyopaque,
        phase: checkpoint_file.IoPhaseV1,
    ) checkpoint_file.Error!void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        const point: CrashPoint = switch (phase) {
            .archive_write => .bootstrap_checkpoint_archive_write,
            .archive_sync => .bootstrap_checkpoint_archive_sync,
            .archive_directory_sync => .bootstrap_checkpoint_archive_directory_sync,
            .selector_write => .bootstrap_checkpoint_selector_write,
            .selector_sync => .bootstrap_checkpoint_selector_sync,
            .selector_rename => .bootstrap_checkpoint_selector_rename,
            .selector_directory_sync => .bootstrap_checkpoint_selector_directory_sync,
        };
        if (phase == .selector_rename or
            phase == .selector_directory_sync)
        {
            self.checkpoint_selector_sha256 =
                self.successor_checkpoint_selector_sha256;
        }
        self.maybeCrash(point) catch
            return checkpoint_file.Error.PublicationMismatch;
    }

    fn afterSourceCheckpointPhase(
        raw: *anyopaque,
        phase: checkpoint_file.IoPhaseV1,
    ) checkpoint_file.Error!void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        const point: CrashPoint = switch (phase) {
            .archive_write => .source_checkpoint_archive_write,
            .archive_sync => .source_checkpoint_archive_sync,
            .archive_directory_sync => .source_checkpoint_archive_directory_sync,
            .selector_write => .source_checkpoint_selector_write,
            .selector_sync => .source_checkpoint_selector_sync,
            .selector_rename => .source_checkpoint_selector_rename,
            .selector_directory_sync => .source_checkpoint_selector_directory_sync,
        };
        if (phase == .selector_rename or
            phase == .selector_directory_sync)
        {
            self.checkpoint_selector_sha256 =
                self.successor_checkpoint_selector_sha256;
        }
        self.maybeCrash(point) catch
            return checkpoint_file.Error.PublicationMismatch;
    }
};

const ReceiptSink = struct {
    receipt: publication.CommitReceiptV1 = undefined,
    commit_calls: usize = 0,
    prepare_calls: usize = 0,
    abort_calls: usize = 0,

    fn interface(self: *ReceiptSink) publication.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        raw: *anyopaque,
        proposal: *const publication.ProposalV1,
        ack: *publication.PrepareAckV1,
    ) publication.SinkPrepareError!void {
        const self: *ReceiptSink =
            @ptrCast(@alignCast(raw));
        self.prepare_calls += 1;
        ack.* = .{
            .proposal_sha256 = publication.proposalSha256(proposal.*),
            .sink_epoch = 0x5231_5354_4550_0001,
            .reservation_id = self.prepare_calls,
        };
    }

    fn commit(
        raw: *anyopaque,
        receipt: *const publication.CommitReceiptV1,
    ) void {
        const self: *ReceiptSink =
            @ptrCast(@alignCast(raw));
        if (self.commit_calls != 0)
            @panic("one-token receipt sink overflow");
        self.receipt = receipt.*;
        self.commit_calls = 1;
    }

    fn abort(
        raw: *anyopaque,
        _: *const publication.ProposalV1,
        _: *const publication.PrepareAckV1,
    ) void {
        const self: *ReceiptSink =
            @ptrCast(@alignCast(raw));
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
        try self.initWithIdentity(.{
            .scheduler_epoch = source_scheduler_epoch,
            .coordinator_id = source_coordinator_id,
            .bank_epoch = source_bank_epoch,
        });
    }

    fn initWithIdentity(
        self: *SourceRuntime,
        identity: source_recovery.SourceRuntimeIdentityV1,
    ) !void {
        self.bank = try bank_api.Bank.init(
            &self.bank_slots,
            .{},
            identity.bank_epoch,
        );
        self.scheduler = try lane.Scheduler.init(
            &self.bank,
            .{
                .slots = &self.lane_slots,
                .projection = &self.projection_slots,
            },
            .{
                .scheduler_epoch = identity.scheduler_epoch,
                .coordinator_id = identity.coordinator_id,
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
        target: successor.TargetOwnershipV1,
    ) !void {
        const claim = target.request_claim;
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
            target.bank_epoch,
        );
        self.scheduler =
            try lane.Scheduler.initWithLeaseTree(
                &self.bank,
                .{
                    .slots = &self.lane_slots,
                    .projection = &self.projection_slots,
                },
                .{
                    .scheduler_epoch = target.scheduler_epoch,
                    .coordinator_id = target.coordinator_id,
                    .challenge = challenge,
                    .max_weight = 1,
                },
            );
        const identity = try self.scheduler.identityV1();
        if (identity.scheduler_epoch != target.scheduler_epoch or
            identity.coordinator_id != target.coordinator_id or
            identity.bank_epoch != target.bank_epoch)
            return error.TargetIdentityDrift;
    }
};

const SourceCheckpointV1 = struct {
    boundary: prepared.BoundarySnapshotV2,
    expected: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
};

const SelectedRestartV1 = struct {
    manifest: restart_manifest.DecodedV1,
    checkpoint: checkpoint.DecodedV1,
    artifacts: successor.ArtifactsV1,
    encoded_checkpoint: []const u8,
    encoded_plan: []const u8,
    encoded_residency: []const u8,
    encoded_segment: []const u8,
    predecessor_set: []const u8,
    predecessor_selector: []const u8,
    active_set: []const u8,
    active_selector: []const u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len < 3 or arguments.len > 4)
        return error.InvalidArguments;
    const directory = arguments[2];
    if (!std.fs.path.isAbsolute(directory))
        return error.DirectoryMustBeAbsolute;

    if (std.mem.eql(u8, arguments[1], "baseline")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runBaselineV1(allocator, directory);
    } else if (std.mem.eql(
        u8,
        arguments[1],
        "source-bootstrap",
    )) {
        const crash_point = if (arguments.len == 4)
            try parseCrashPointV1(arguments[3])
        else
            null;
        try runSourceBootstrapV1(
            allocator,
            directory,
            crash_point,
        );
    } else if (std.mem.eql(
        u8,
        arguments[1],
        "source-transition",
    )) {
        const crash_point = if (arguments.len == 4)
            try parseCrashPointV1(arguments[3])
        else
            null;
        try runSourceTransitionV1(
            allocator,
            directory,
            crash_point,
        );
    } else if (std.mem.eql(u8, arguments[1], "source")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runSourceV1(allocator, directory);
    } else if (std.mem.eql(u8, arguments[1], "target")) {
        const crash_point = if (arguments.len == 4)
            try parseCrashPointV1(arguments[3])
        else
            null;
        try runTargetV1(
            allocator,
            directory,
            crash_point,
        );
    } else if (std.mem.eql(u8, arguments[1], "audit")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runAuditV1(allocator, directory, "audit");
    } else return error.InvalidArguments;
}

fn parseCrashPointV1(
    encoded: []const u8,
) !?CrashPoint {
    inline for (std.meta.fields(CrashPoint)) |field| {
        if (std.mem.eql(u8, encoded, field.name))
            return @enumFromInt(field.value);
    }
    return error.InvalidCrashPoint;
}

fn crashPointNameV1(point: CrashPoint) []const u8 {
    return @tagName(point);
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
    var model =
        try engine.loader.loadPrepared(allocator, image_path);
    defer model.deinit();

    var runtime: SourceRuntime = .{};
    try runtime.init();
    var runtime_closed = false;
    defer {
        if (!runtime_closed)
            _ = runtime.scheduler.close() catch {};
    }
    const local_plan =
        try prepared.makePlanV1(model, &prompt, options);
    const bound_input = try boundInputV1();
    const bound_plan = try prepared.makeBoundPlanV1(
        model,
        &prompt,
        options,
        local_plan,
        scheduling,
        &runtime.scheduler,
        bound_input,
    );
    var session: prepared.SessionV3 = .{};
    defer session.deinit();
    try requireStartedV1(try session.start(
        allocator,
        &model,
        &prompt,
        options,
        local_plan,
        bound_input,
        bound_plan,
        scheduling,
        &runtime.scheduler,
        &runtime.bank,
    ));
    var sink: ReceiptSink = .{};
    while (!session.isFinished()) {
        sink.commit_calls = 0;
        _ = try session.step(
            try runtime.scheduler.prepareService(),
            sink.interface(),
        );
        if (sink.commit_calls != 1)
            return error.InvalidBaselineSequence;
    }
    _ = try session.sealTerminalResult();
    const boundary = try session.snapshotVerified();
    const semantic = try terminal.makeV1(
        boundary,
        session.inner.bound_plan,
        local_plan,
        session.outputTokens(),
        engine.lane_contiguous_publication
            .logicalKvPrefixSha256(
            &session.inner.inner.resources.cache,
            session.inner.inner.resources.cache.len,
        ),
    );
    var encoded_semantic: [terminal.semantic_bytes]u8 = undefined;
    _ = try terminal.encodeV1(
        semantic,
        &encoded_semantic,
    );
    var directory =
        try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();
    try writeSyncedFileV1(
        directory,
        terminal_semantic_name,
        &encoded_semantic,
    );
    const output_tokens = session.outputTokens();
    if (output_tokens.len != options.max_new_tokens)
        return error.InvalidBaselineSequence;
    var output_copy: [options.max_new_tokens]u32 = undefined;
    @memcpy(&output_copy, output_tokens);
    _ = try session.retire();
    try requireRuntimeZeroV1(
        &runtime.bank,
        &runtime.scheduler,
    );
    _ = try runtime.scheduler.close();
    runtime_closed = true;
    try emitResultV1(.{
        .mode = "baseline",
        .input_generation = 1,
        .input_sequence = 0,
        .output_generation = 1,
        .output_sequence = options.max_new_tokens,
        .sink_disposition = .none,
        .sink_count = 0,
        .sink_next_sequence = 1,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = zero_digest,
        .terminal = true,
        .ownership_zero = true,
        .output_tokens = &output_copy,
        .terminal_semantic_sha256 = semantic.semantic_sha256,
    });
}

fn runSourceBootstrapV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    requested_crash: ?CrashPoint,
) !void {
    const image_path = try modelPathV1(
        allocator,
        absolute_directory,
        model_image_name,
    );
    defer allocator.free(image_path);
    var model =
        try engine.loader.loadPrepared(allocator, image_path);
    defer model.deinit();
    var directory =
        try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();

    var runtime: SourceRuntime = .{};
    try runtime.init();
    var runtime_closed = false;
    defer {
        if (!runtime_closed)
            _ = runtime.scheduler.close() catch {};
    }
    const local_plan =
        try prepared.makePlanV1(model, &prompt, options);
    const bound_input = try boundInputV1();
    const bound_plan = try prepared.makeBoundPlanV1(
        model,
        &prompt,
        options,
        local_plan,
        scheduling,
        &runtime.scheduler,
        bound_input,
    );
    const target = try targetOwnershipForStageV1(
        2,
        bound_plan,
    );
    const runtime_identity: source_recovery.SourceRuntimeIdentityV1 = .{
        .scheduler_epoch = source_scheduler_epoch,
        .coordinator_id = source_coordinator_id,
        .bank_epoch = source_bank_epoch,
    };
    const contract_storage = try allocator.alloc(
        u8,
        try source_recovery.encodedBytesV1(prompt.len),
    );
    defer allocator.free(contract_storage);
    const encoded_contract = try source_recovery.encodeV1(
        .{
            .prompt = &prompt,
            .options = options,
            .scheduling = scheduling,
            .bound_plan_input = bound_input,
            .plan = local_plan,
            .bound_plan = bound_plan,
            .source_runtime = runtime_identity,
            .request_epoch = request_epoch,
            .publication_next_sequence = 1,
            .challenge_sha256 = challenge,
            .target = target,
            .sink_storage_epoch = sink_storage_epoch,
            .sink_capacity = sink_capacity,
            .sink_initial_sequence = 1,
            .sink_implementation_sha256 = sink_implementation_sha256,
            .sink_instance_sha256 = sink_instance_sha256,
        },
        contract_storage,
    );
    const live_storage = try allocator.alloc(
        u8,
        checkpoint_file.set_payload_offset +
            durable.source_live_marker.len +
            encoded_contract.bytes.len +
            checkpoint_file.set_footer_bytes,
    );
    defer allocator.free(live_storage);
    const live_set =
        try source_lease.encodeRecoverableSourceLiveSetV1(
            encoded_contract,
            live_storage,
        );
    const live_selector =
        try checkpoint_file.prepareInitialSelectorV1(live_set);
    const active_storage =
        try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(active_storage);
    var checkpoint_lock_storage: [1]u8 = undefined;
    var controller: CrashController = .{
        .requested = requested_crash,
        .input_generation = 0,
        .input_sequence = 0,
        .sink_count = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = zero_digest,
        .successor_checkpoint_selector_sha256 = live_selector.selector_sha256,
    };
    const initialization =
        try checkpoint_file.LeaseV1
            .createOrRecoverInitialObservedV1(
            directory,
            storage_epoch,
            challenge,
            live_set,
            live_selector,
            max_authority_bytes,
            &checkpoint_lock_storage,
            active_storage,
            .{
                .context = &controller,
                .after_phase_fn = CrashController
                    .afterBootstrapCheckpointPhase,
            },
        );
    var lease = initialization.lease;
    defer lease.close();
    if (!std.mem.eql(u8, lease.stream(), live_set.bytes) or
        lease.selector.generation != 1 or
        !digestEqual(
            lease.selector.selector_sha256,
            live_selector.selector_sha256,
        ))
        return error.InvalidSourceBootstrap;

    try requireRuntimeZeroV1(
        &runtime.bank,
        &runtime.scheduler,
    );
    _ = try runtime.scheduler.close();
    runtime_closed = true;
    const checkpoint_selector = lease.selector;
    lease.close();
    const no_tokens = [_]u32{};
    try emitResultV1(.{
        .mode = "source-bootstrap",
        .input_generation = 0,
        .input_sequence = 0,
        .output_generation = checkpoint_selector.generation,
        .output_sequence = checkpoint_selector.publication_next_sequence,
        .sink_disposition = .none,
        .sink_count = 0,
        .sink_next_sequence = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = checkpoint_selector.selector_sha256,
        .terminal = false,
        .ownership_zero = true,
        .output_tokens = &no_tokens,
        .terminal_semantic_sha256 = zero_digest,
    });
}

fn runSourceTransitionV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    requested_crash: ?CrashPoint,
) !void {
    var directory =
        try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();
    const active_storage =
        try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(active_storage);
    const retained_storage =
        try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(retained_storage);
    var checkpoint_lock_storage: [1]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        challenge,
        max_authority_bytes,
        &checkpoint_lock_storage,
        active_storage,
    );
    defer lease.close();
    const active_set = try lease.activeSet();
    if (active_set.metadata.generation ==
        durable.source_exited_set_generation)
    {
        try emitAlreadySelectedSourceTransitionV1(
            &lease,
            directory,
            retained_storage,
        );
        return;
    }
    if (active_set.metadata.generation !=
        source_lease.source_live_set_generation)
        return error.InvalidSourceRecoveryGeneration;
    const contract = try selectedSourceRecoveryContractV1(
        &lease,
    );
    const encoded_contract: source_recovery.EncodedV1 = .{
        .bytes = contract.encoded,
        .contract_sha256 = contract.contract_sha256,
    };

    const prompt_storage =
        try allocator.alloc(u32, contract.promptCount());
    defer allocator.free(prompt_storage);
    for (prompt_storage, 0..) |*token, index|
        token.* = try contract.promptToken(index);
    const image_path = try modelPathV1(
        allocator,
        absolute_directory,
        model_image_name,
    );
    defer allocator.free(image_path);
    var model =
        try engine.loader.loadPrepared(allocator, image_path);
    defer model.deinit();
    var runtime: SourceRuntime = .{};
    try runtime.initWithIdentity(contract.source_runtime);
    var runtime_closed = false;
    defer {
        if (!runtime_closed)
            _ = runtime.scheduler.close() catch {};
    }
    const local_plan = try prepared.makePlanV1(
        model,
        prompt_storage,
        contract.options,
    );
    const bound_plan = try prepared.makeBoundPlanV1(
        model,
        prompt_storage,
        contract.options,
        local_plan,
        contract.scheduling,
        &runtime.scheduler,
        contract.bound_plan_input,
    );
    const target = try targetOwnershipForStageV1(
        2,
        bound_plan,
    );
    try source_recovery.verifyContextV1(
        contract,
        .{
            .prompt = prompt_storage,
            .options = contract.options,
            .scheduling = contract.scheduling,
            .bound_plan_input = contract.bound_plan_input,
            .plan = local_plan,
            .bound_plan = bound_plan,
            .source_runtime = contract.source_runtime,
            .request_epoch = contract.request_epoch,
            .publication_next_sequence = contract.publication_next_sequence,
            .challenge_sha256 = contract.challenge_sha256,
            .target = target,
            .sink_storage_epoch = contract.sink.storage_epoch,
            .sink_capacity = std.math.cast(
                usize,
                contract.sink.capacity,
            ) orelse return error.InvalidSourceRecoveryContract,
            .sink_initial_sequence = contract.sink.initial_sequence,
            .sink_implementation_sha256 = contract.sink.implementation_sha256,
            .sink_instance_sha256 = contract.sink.instance_sha256,
        },
    );

    var live_grant: source_lease.SourceLiveGrantV1 = .{};
    try source_lease.initSourceLiveGrantV1(
        &live_grant,
        &lease,
    );
    defer if (live_grant.lease != null and
        (live_grant.phase == .ready or
            live_grant.phase == .bound))
    {
        source_lease.releaseSourceLiveGrantV1(
            &live_grant,
        ) catch {};
    };
    var controller: CrashController = .{
        .requested = requested_crash,
        .input_generation = source_lease.source_live_set_generation,
        .input_sequence = contract.publication_next_sequence,
        .sink_count = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = lease.selector.selector_sha256,
        .successor_sink_count = 0,
        .successor_sink_ledger_sha256 = contract.sink.empty_ledger_sha256,
        .successor_sink_selector_sha256 = contract.sink.empty_selector_sha256,
    };
    try controller.maybeCrash(
        .source_after_recovery_admission,
    );

    var sink_lock_storage: [1]u8 = undefined;
    const sink_initialization =
        try result_sink_file.ResultSinkFileV1(
            sink_capacity,
        ).createOrRecoverEmpty(
            directory,
            contract.sink.storage_epoch,
            local_plan.plan_sha256,
            contract.request_epoch,
            contract.sink.initial_sequence,
            contract.sink.implementation_sha256,
            contract.sink.instance_sha256,
            &sink_lock_storage,
            .{
                .context = &controller,
                .after_phase_fn = CrashController.afterSourceSinkPhase,
            },
        );
    var sink_store = sink_initialization.store;
    defer sink_store.close();
    try validateEmptySinkSelectionV1(
        sink_store.selector,
        contract,
    );
    controller.sink_ledger_sha256 =
        sink_store.selector.ledger_sha256;
    controller.sink_selector_sha256 =
        sink_store.selector.selector_sha256;
    try controller.maybeCrash(.source_after_initial_sink);

    var session: prepared.SessionV3 = .{};
    defer session.deinit();
    try requireStartedV1(try session.start(
        allocator,
        &model,
        prompt_storage,
        contract.options,
        local_plan,
        contract.bound_plan_input,
        bound_plan,
        contract.scheduling,
        &runtime.scheduler,
        &runtime.bank,
    ));
    var step_sink: ReceiptSink = .{};
    _ = try session.step(
        try runtime.scheduler.prepareService(),
        step_sink.interface(),
    );
    if (step_sink.commit_calls != 1 or
        session.outputTokens().len !=
            contract.publication_next_sequence)
        return error.InvalidSourceSequence;
    const source_output = [1]u32{
        session.outputTokens()[0],
    };
    try controller.maybeCrash(.source_after_step);
    try session.attachSourceLiveGrantV1(&live_grant);

    const encoded_checkpoint =
        try session.captureCheckpointV1(
            allocator,
            contract.challenge_sha256,
        );
    defer allocator.free(encoded_checkpoint);
    const context = try checkpointContextV1(
        &session,
        &model,
        bound_plan,
        local_plan,
    );
    if (context.boundary.base.publication.next_sequence !=
        contract.publication_next_sequence)
        return error.InvalidSourceSequence;
    const manifest_bytes =
        try restart_manifest.encodedBytesV1(
            prompt_storage.len,
        );
    const manifest_storage =
        try allocator.alloc(u8, manifest_bytes);
    defer allocator.free(manifest_storage);
    const encoded_manifest = try restart_manifest.encodeV1(
        .{
            .prompt = prompt_storage,
            .options = contract.options,
            .plan = local_plan,
            .bound_plan = bound_plan,
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
    const evidence_storage =
        try allocator.alloc(u8, evidence_bytes);
    defer allocator.free(evidence_storage);
    const evidence = try archive.encodeRestartArchiveV1(
        contract.publication_next_sequence,
        zero_digest,
        encoded_checkpoint,
        encoded_manifest.bytes,
        evidence_storage,
    );
    _ = try session.beginDurableHandoffV1(
        encoded_checkpoint,
        contract.challenge_sha256,
        target,
        evidence.set.checkpoint_sha256,
        lease.selectorRoot(),
    );
    try session.validateDurableHandoffV1();
    try controller.maybeCrash(
        .source_after_handoff_prepare,
    );
    const source_exit =
        try session.commitDurableHandoffV1();
    controller.maybeCrash(
        .source_after_exit_commit,
    ) catch failStopSourceTransitionV1();

    const authority_bytes =
        durable.encodedRecoverableSourceExitedSetBytesV1(
            evidence.set.bytes.len,
            encoded_contract.bytes.len,
        ) catch failStopSourceTransitionV1();
    const authority_storage =
        allocator.alloc(
            u8,
            authority_bytes,
        ) catch failStopSourceTransitionV1();
    defer allocator.free(authority_storage);
    const authority =
        durable.encodeRecoverableSourceExitedSetV1(
            evidence,
            source_exit,
            active_set.checkpoint_sha256,
            encoded_contract,
            authority_storage,
        ) catch failStopSourceTransitionV1();
    const checkpoint_publication =
        checkpoint_file.preparePublicationV1(
            &lease,
            authority,
        ) catch failStopSourceTransitionV1();
    controller.successor_checkpoint_selector_sha256 =
        checkpoint_publication.selector.selector_sha256;
    const checkpoint_applied = if (requested_crash != null)
        checkpoint_file.publishObservedV1(
            &lease,
            checkpoint_publication,
            .{
                .context = &controller,
                .after_phase_fn = CrashController.afterSourceCheckpointPhase,
            },
        ) catch failStopSourceTransitionV1()
    else
        checkpoint_file.recoverV1(
            &lease,
            checkpoint_publication,
        ) catch failStopSourceTransitionV1();
    session.completeDurableHandoffV1(.{
        .checkpoint_sha256 = checkpoint_applied.checkpoint_sha256,
        .selector_sha256 = checkpoint_applied.selector_sha256,
    }) catch failStopSourceTransitionV1();
    if (live_grant.phase != .completed)
        failStopSourceTransitionV1();
    requireRuntimeZeroV1(
        &runtime.bank,
        &runtime.scheduler,
    ) catch failStopSourceTransitionV1();
    _ = runtime.scheduler.close() catch
        failStopSourceTransitionV1();
    runtime_closed = true;
    controller.checkpoint_selector_sha256 =
        checkpoint_applied.selector_sha256;
    controller.maybeCrash(
        .source_after_generation_two,
    ) catch failStopSourceTransitionV1();

    const sink_selector = sink_store.selector;
    sink_store.close();
    const checkpoint_selector = lease.selector;
    lease.close();
    emitResultV1(.{
        .mode = "source-transition",
        .input_generation = source_lease.source_live_set_generation,
        .input_sequence = contract.publication_next_sequence,
        .output_generation = checkpoint_selector.generation,
        .output_sequence = checkpoint_selector.publication_next_sequence,
        .sink_disposition = .none,
        .sink_count = sink_selector.acknowledgement_count,
        .sink_next_sequence = sink_selector.next_sequence,
        .sink_ledger_sha256 = sink_selector.ledger_sha256,
        .sink_selector_sha256 = sink_selector.selector_sha256,
        .checkpoint_selector_sha256 = checkpoint_selector.selector_sha256,
        .terminal = false,
        .ownership_zero = true,
        .output_tokens = &source_output,
        .terminal_semantic_sha256 = zero_digest,
    }) catch failStopSourceTransitionV1();
}

fn selectedSourceRecoveryContractV1(
    lease: *checkpoint_file.LeaseV1,
) !source_recovery.DecodedV1 {
    const selected = try lease.activeSet();
    if (selected.object_count != 2 or
        selected.metadata.generation !=
            source_lease.source_live_set_generation or
        selected.metadata.request_epoch == 0 or
        selected.metadata.publication_next_sequence == 0 or
        !std.mem.allEqual(
            u8,
            &selected.metadata.parent_checkpoint_sha256,
            0,
        ))
        return error.InvalidSourceRecoveryContract;
    const marker = selected.objects[0];
    const contract_object = selected.objects[1];
    if (marker.kind != .extension or
        marker.ordinal !=
            source_lease.source_live_object_ordinal or
        marker.abi_version !=
            source_lease.source_live_marker_abi or
        !std.mem.eql(
            u8,
            marker.bytes,
            source_lease.source_live_marker,
        ) or contract_object.kind != .extension or
        contract_object.ordinal !=
            source_lease.source_recovery_object_ordinal or
        contract_object.abi_version !=
            source_recovery.contract_abi)
        return error.InvalidSourceRecoveryContract;
    const contract = try source_recovery.decodeV1(
        contract_object.bytes,
    );
    if (contract.request_epoch !=
        selected.metadata.request_epoch or
        contract.publication_next_sequence !=
            selected.metadata.publication_next_sequence or
        !digestEqual(
            contract.challenge_sha256,
            selected.metadata.challenge_sha256,
        ))
        return error.InvalidSourceRecoveryContract;
    return contract;
}

fn validateEmptySinkSelectionV1(
    selector: result_sink_file.DecodedSelectorV1,
    contract: source_recovery.DecodedV1,
) !void {
    if (contract.sink.capacity != sink_capacity or
        selector.generation != 1 or
        selector.acknowledgement_count != 0 or
        selector.initial_sequence !=
            contract.sink.initial_sequence or
        selector.next_sequence !=
            contract.sink.initial_sequence or
        selector.request_epoch != contract.request_epoch or
        !digestEqual(
            selector.request_sha256,
            contract.plan_sha256,
        ) or !digestEqual(
        selector.sink_implementation_sha256,
        contract.sink.implementation_sha256,
    ) or !digestEqual(
        selector.sink_instance_sha256,
        contract.sink.instance_sha256,
    ) or !digestEqual(
        selector.ledger_sha256,
        contract.sink.empty_ledger_sha256,
    ) or !digestEqual(
        selector.selector_sha256,
        contract.sink.empty_selector_sha256,
    ))
        return error.InvalidSourceSinkBootstrap;
}

/// Before recoverable G2 admission the durable sink may be either the exact
/// empty state named by the source contract or the single exact logical edge
/// left visible by a target that died before publishing G3. The latter remains
/// provisional until `apply` exact-replays the freshly recomputed delivery
/// while this same store keeps the file lease held.
fn validateRecoverableTargetSinkSelectionV1(
    store: *const DurableResultSinkV1,
    contract: source_recovery.DecodedV1,
    selected_sequence: u64,
) !void {
    if (selected_sequence != contract.sink.initial_sequence or
        contract.sink.capacity != sink_capacity)
        return error.InvalidSourceSinkBootstrap;
    if (store.selector.acknowledgement_count == 0) {
        try validateEmptySinkSelectionV1(
            store.selector,
            contract,
        );
        return;
    }

    const expected_next = std.math.add(
        u64,
        selected_sequence,
        1,
    ) catch return error.InvalidSourceSinkBootstrap;
    const acknowledgements =
        store.sink.acknowledgementSlice();
    if (store.selector.generation != 2 or
        store.selector.acknowledgement_count != 1 or
        store.selector.initial_sequence !=
            contract.sink.initial_sequence or
        store.selector.next_sequence != expected_next or
        store.selector.request_epoch != contract.request_epoch or
        !digestEqual(
            store.selector.request_sha256,
            contract.plan_sha256,
        ) or !digestEqual(
        store.selector.sink_implementation_sha256,
        contract.sink.implementation_sha256,
    ) or !digestEqual(
        store.selector.sink_instance_sha256,
        contract.sink.instance_sha256,
    ) or store.sink.applied_count != 1 or
        store.sink.next_sequence != expected_next or
        acknowledgements.len != 1)
        return error.InvalidSourceSinkBootstrap;

    const acknowledgement = acknowledgements[0];
    try result_sink.validateAcknowledgementV1(
        acknowledgement,
    );
    if (acknowledgement.request_epoch !=
        contract.request_epoch or
        acknowledgement.transaction_sequence !=
            selected_sequence or
        acknowledgement.application_ordinal != 1 or
        acknowledgement.application_count != 1 or
        !digestEqual(
            acknowledgement.request_sha256,
            contract.plan_sha256,
        ) or !digestEqual(
        acknowledgement.sink_implementation_sha256,
        contract.sink.implementation_sha256,
    ) or !digestEqual(
        acknowledgement.sink_instance_sha256,
        contract.sink.instance_sha256,
    ) or !durable
        .recoverableOneAheadSinkLineageValidV1(
        contract.sink.empty_selector_sha256,
        store.selector.previous_selector_sha256,
        acknowledgement
            .predecessor_acknowledgement_sha256,
        acknowledgement.predecessor_sink_prefix_sha256,
    ))
        return error.InvalidSourceSinkBootstrap;
}

fn emitAlreadySelectedSourceTransitionV1(
    lease: *checkpoint_file.LeaseV1,
    directory: std.fs.Dir,
    retained_storage: []u8,
) !void {
    const active = try lease.activeSet();
    const selected =
        try durable.decodeSourceExitedSetV1(
            lease.stream(),
            lease.selector,
            active.metadata.parent_checkpoint_sha256,
        );
    const contract =
        try durable.validateRecoverableSourcePredecessorV1(
            lease,
            selected,
            retained_storage,
        );
    if (contract.sink.capacity != sink_capacity)
        return error.InvalidSourceRecoveryContract;
    var sink_lock_storage: [1]u8 = undefined;
    var ledger_storage: [max_result_ledger_bytes]u8 =
        undefined;
    var sink_store =
        try result_sink_file.ResultSinkFileV1(
            sink_capacity,
        ).open(
            directory,
            contract.sink.storage_epoch,
            contract.plan_sha256,
            contract.request_epoch,
            contract.sink.initial_sequence,
            contract.sink.implementation_sha256,
            contract.sink.instance_sha256,
            &sink_lock_storage,
            &ledger_storage,
            null,
        );
    defer sink_store.close();
    try validateEmptySinkSelectionV1(
        sink_store.selector,
        contract,
    );
    const decoded_checkpoint = selected.evidence.checkpoint;
    if (decoded_checkpoint.output_count != 1 or
        decoded_checkpoint.canonical_output_u32_le.len !=
            @sizeOf(u32))
        return error.InvalidSourceSequence;
    const source_output = [1]u32{std.mem.readInt(
        u32,
        decoded_checkpoint.canonical_output_u32_le[0..4],
        .little,
    )};
    const sink_selector = sink_store.selector;
    try emitResultV1(.{
        .mode = "source-transition",
        .input_generation = source_lease.source_live_set_generation,
        .input_sequence = contract.publication_next_sequence,
        .output_generation = lease.selector.generation,
        .output_sequence = lease.selector.publication_next_sequence,
        .sink_disposition = .none,
        .sink_count = sink_selector.acknowledgement_count,
        .sink_next_sequence = sink_selector.next_sequence,
        .sink_ledger_sha256 = sink_selector.ledger_sha256,
        .sink_selector_sha256 = sink_selector.selector_sha256,
        .checkpoint_selector_sha256 = lease.selector.selector_sha256,
        .terminal = false,
        .ownership_zero = true,
        .output_tokens = &source_output,
        .terminal_semantic_sha256 = zero_digest,
    });
}

fn failStopSourceTransitionV1() noreturn {
    std.process.exit(74);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
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
    var model =
        try engine.loader.loadPrepared(allocator, image_path);
    defer model.deinit();
    var directory =
        try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();

    const active_storage =
        try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(active_storage);
    var checkpoint_lock_storage: [1]u8 = undefined;
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
        &checkpoint_lock_storage,
        active_storage,
    );
    defer lease.close();
    var live_grant: source_lease.SourceLiveGrantV1 = .{};
    try source_lease.initSourceLiveGrantV1(
        &live_grant,
        &lease,
    );
    defer if (live_grant.lease != null and
        (live_grant.phase == .ready or
            live_grant.phase == .bound))
    {
        source_lease.releaseSourceLiveGrantV1(
            &live_grant,
        ) catch {};
    };

    var runtime: SourceRuntime = .{};
    try runtime.init();
    var runtime_closed = false;
    defer {
        if (!runtime_closed)
            _ = runtime.scheduler.close() catch {};
    }
    const local_plan =
        try prepared.makePlanV1(model, &prompt, options);
    const bound_input = try boundInputV1();
    const bound_plan = try prepared.makeBoundPlanV1(
        model,
        &prompt,
        options,
        local_plan,
        scheduling,
        &runtime.scheduler,
        bound_input,
    );
    const target = try targetOwnershipForStageV1(
        2,
        bound_plan,
    );
    var session: prepared.SessionV3 = .{};
    defer session.deinit();
    try requireStartedV1(try session.start(
        allocator,
        &model,
        &prompt,
        options,
        local_plan,
        bound_input,
        bound_plan,
        scheduling,
        &runtime.scheduler,
        &runtime.bank,
    ));
    var step_sink: ReceiptSink = .{};
    _ = try session.step(
        try runtime.scheduler.prepareService(),
        step_sink.interface(),
    );
    if (step_sink.commit_calls != 1 or
        session.outputTokens().len != 1)
        return error.InvalidSourceSequence;
    const source_output = [1]u32{
        session.outputTokens()[0],
    };
    try session.attachSourceLiveGrantV1(&live_grant);

    const encoded_checkpoint =
        try session.captureCheckpointV1(
            allocator,
            challenge,
        );
    defer allocator.free(encoded_checkpoint);
    const context = try checkpointContextV1(
        &session,
        &model,
        bound_plan,
        local_plan,
    );
    if (context.boundary.base.publication.next_sequence != 1)
        return error.InvalidSourceSequence;
    const manifest_bytes =
        try restart_manifest.encodedBytesV1(prompt.len);
    const manifest_storage =
        try allocator.alloc(u8, manifest_bytes);
    defer allocator.free(manifest_storage);
    const encoded_manifest = try restart_manifest.encodeV1(
        .{
            .prompt = &prompt,
            .options = options,
            .plan = local_plan,
            .bound_plan = bound_plan,
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
    const evidence_storage =
        try allocator.alloc(u8, evidence_bytes);
    defer allocator.free(evidence_storage);
    const evidence = try archive.encodeRestartArchiveV1(
        1,
        zero_digest,
        encoded_checkpoint,
        encoded_manifest.bytes,
        evidence_storage,
    );
    _ = try session.beginDurableHandoffV1(
        encoded_checkpoint,
        challenge,
        target,
        evidence.set.checkpoint_sha256,
        lease.selectorRoot(),
    );
    try session.validateDurableHandoffV1();
    const source_exit =
        try session.commitDurableHandoffV1();
    const authority_bytes =
        durable.encodedSourceExitedSetBytesV1(
            evidence.set.bytes.len,
        ) catch failStopSourceTransitionV1();
    const authority_storage =
        allocator.alloc(
            u8,
            authority_bytes,
        ) catch failStopSourceTransitionV1();
    defer allocator.free(authority_storage);
    const authority =
        durable.encodeSourceExitedSetV1(
            evidence,
            source_exit,
            live_set.checkpoint_sha256,
            authority_storage,
        ) catch failStopSourceTransitionV1();
    const checkpoint_publication =
        checkpoint_file.preparePublicationV1(
            &lease,
            authority,
        ) catch failStopSourceTransitionV1();
    const checkpoint_applied =
        checkpoint_file.publishV1(
            &lease,
            checkpoint_publication,
        ) catch failStopSourceTransitionV1();
    if (checkpoint_applied.disposition != .applied)
        failStopSourceTransitionV1();
    session.completeDurableHandoffV1(.{
        .checkpoint_sha256 = checkpoint_applied.checkpoint_sha256,
        .selector_sha256 = checkpoint_applied.selector_sha256,
    }) catch failStopSourceTransitionV1();
    if (live_grant.phase != .completed)
        failStopSourceTransitionV1();

    var sink_lock_storage: [1]u8 = undefined;
    var sink_store =
        result_sink_file.ResultSinkFileV1(
            sink_capacity,
        ).create(
            directory,
            sink_storage_epoch,
            local_plan.plan_sha256,
            request_epoch,
            1,
            sink_implementation_sha256,
            sink_instance_sha256,
            &sink_lock_storage,
            null,
        ) catch failStopSourceTransitionV1();
    const sink_selector = sink_store.selector;
    sink_store.close();
    const checkpoint_selector = lease.selector;
    lease.close();

    requireRuntimeZeroV1(
        &runtime.bank,
        &runtime.scheduler,
    ) catch failStopSourceTransitionV1();
    _ = runtime.scheduler.close() catch
        failStopSourceTransitionV1();
    runtime_closed = true;
    emitResultV1(.{
        .mode = "source",
        .input_generation = 1,
        .input_sequence = 0,
        .output_generation = checkpoint_selector.generation,
        .output_sequence = checkpoint_selector.publication_next_sequence,
        .sink_disposition = .none,
        .sink_count = sink_selector.acknowledgement_count,
        .sink_next_sequence = sink_selector.next_sequence,
        .sink_ledger_sha256 = sink_selector.ledger_sha256,
        .sink_selector_sha256 = sink_selector.selector_sha256,
        .checkpoint_selector_sha256 = checkpoint_selector.selector_sha256,
        .terminal = false,
        .ownership_zero = true,
        .output_tokens = &source_output,
        .terminal_semantic_sha256 = zero_digest,
    }) catch failStopSourceTransitionV1();
}

fn runTargetV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    requested_crash: ?CrashPoint,
) !void {
    var directory =
        try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();
    const active_storage =
        try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(active_storage);
    const retained_storage =
        try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(retained_storage);
    var checkpoint_lock_storage: [1]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        challenge,
        max_authority_bytes,
        &checkpoint_lock_storage,
        active_storage,
    );
    var lease_open = true;
    defer if (lease_open) {
        if (lease.consumer_claim) |claim|
            lease.releaseConsumerClaimV1(claim) catch {};
        lease.close();
    };
    const input_generation = lease.selector.generation;
    const input_sequence =
        lease.selector.publication_next_sequence;
    const active_decoded = try lease.activeSet();
    if (active_decoded.object_count ==
        progress.terminal_object_count)
    {
        if (requested_crash != null)
            return error.CrashPointAfterTerminal;
        lease.close();
        lease_open = false;
        return runAuditV1(
            allocator,
            absolute_directory,
            "target",
        );
    }
    if (input_sequence >= options.max_new_tokens)
        return error.InvalidSelectedSequence;
    const selected_predecessor_storage =
        try allocator.dupe(u8, lease.stream());
    defer allocator.free(selected_predecessor_storage);

    var active_selector_wire: [checkpoint_file.selector_bytes]u8 = undefined;
    try readExactFileV1(
        directory,
        checkpoint_file.active_selector_name,
        &active_selector_wire,
    );
    const active_selector =
        try checkpoint_file.decodeSelectorV1(
            &active_selector_wire,
        );
    if (!std.meta.eql(active_selector, lease.selector))
        return error.ActiveSelectorDrift;
    const retained = try lease.loadRetainedSetV1(
        active_decoded.metadata.parent_checkpoint_sha256,
        retained_storage,
    );

    var activation_grant: restore.SelectedRestartGrantV1 = .{};
    var selected: SelectedRestartV1 = undefined;
    var source_sink_contract: ?source_recovery.DecodedV1 = null;
    var preactivation_sink_lock_storage: [1]u8 = undefined;
    var preactivation_sink_ledger_storage: [
        max_result_ledger_bytes
    ]u8 = undefined;
    var preactivation_sink: ?DurableResultSinkV1 = null;
    defer if (preactivation_sink) |*store| store.close();
    if (input_generation ==
        durable.source_exited_set_generation)
    {
        const decoded =
            try durable.decodeSourceExitedSetV1(
                lease.stream(),
                lease.selector,
                active_decoded.metadata
                    .parent_checkpoint_sha256,
            );
        if (decoded.source_recovery_contract) |_| {
            const contract =
                try durable
                    .validateRecoverableSourcePredecessorV1(
                    &lease,
                    decoded,
                    retained_storage,
                );
            preactivation_sink =
                try DurableResultSinkV1.open(
                    directory,
                    contract.sink.storage_epoch,
                    contract.plan_sha256,
                    contract.request_epoch,
                    contract.sink.initial_sequence,
                    contract.sink.implementation_sha256,
                    contract.sink.instance_sha256,
                    &preactivation_sink_lock_storage,
                    &preactivation_sink_ledger_storage,
                    null,
                );
            try validateRecoverableTargetSinkSelectionV1(
                &preactivation_sink.?,
                contract,
                input_sequence,
            );
            try durable
                .initSelectedRecoverableSourceExitGrantV1(
                &activation_grant,
                &lease,
                decoded,
                retained_storage,
            );
            source_sink_contract = contract;
        } else {
            const live_storage = try allocator.alloc(
                u8,
                checkpoint_file.set_payload_offset +
                    durable.source_live_marker.len +
                    checkpoint_file.set_footer_bytes,
            );
            defer allocator.free(live_storage);
            const expected_live =
                try durable.encodeSourceLiveSetV1(
                    request_epoch,
                    1,
                    challenge,
                    live_storage,
                );
            if (!std.mem.eql(
                u8,
                retained.bytes,
                expected_live.bytes,
            ))
                return error.RetainedSourceLiveDrift;
            try durable.initSelectedSourceExitGrantV1(
                &activation_grant,
                &lease,
                decoded,
            );
        }
        const encoded_plan =
            try decoded.evidence.archive.object(
                .extension,
                archive.successor_plan_object_ordinal,
            );
        const encoded_residency =
            try decoded.evidence.archive.object(
                .extension,
                archive.successor_residency_object_ordinal,
            );
        const encoded_segment =
            try decoded.evidence.archive.object(
                .extension,
                archive.successor_segment_object_ordinal,
            );
        selected = .{
            .manifest = decoded.evidence.manifest,
            .checkpoint = decoded.evidence.checkpoint,
            .artifacts = decoded.evidence.artifacts,
            .encoded_checkpoint = decoded.evidence.checkpoint.encoded,
            .encoded_plan = encoded_plan.bytes,
            .encoded_residency = encoded_residency.bytes,
            .encoded_segment = encoded_segment.bytes,
            .predecessor_set = retained.bytes,
            .predecessor_selector = &active_selector_wire,
            .active_set = selected_predecessor_storage,
            .active_selector = &active_selector_wire,
        };
    } else {
        if (active_decoded.object_count !=
            progress.nonterminal_object_count)
            return error.InvalidSelectedProgress;
        const embedded_selector =
            active_decoded.objects[0];
        if (embedded_selector.kind != .runtime_state or
            embedded_selector.ordinal !=
                progress
                    .nonterminal_predecessor_selector_object_ordinal or
            embedded_selector.abi_version !=
                checkpoint_file.selector_abi)
            return error.InvalidSelectedProgress;
        const decoded =
            try progress.decodeNonterminalV1(
                retained.bytes,
                embedded_selector.bytes,
                lease.stream(),
                &active_selector_wire,
            );
        try acknowledged_restore
            .initSelectedProgressGrantV1(
            &activation_grant,
            &lease,
            decoded,
        );
        selected = .{
            .manifest = decoded.manifest,
            .checkpoint = decoded.checkpoint,
            .artifacts = decoded.artifacts,
            .encoded_checkpoint = active_decoded.objects[1].bytes,
            .encoded_plan = active_decoded.objects[2].bytes,
            .encoded_residency = active_decoded.objects[3].bytes,
            .encoded_segment = active_decoded.objects[4].bytes,
            .predecessor_set = retained.bytes,
            .predecessor_selector = embedded_selector.bytes,
            .active_set = selected_predecessor_storage,
            .active_selector = &active_selector_wire,
        };
    }

    const image_path = try modelPathV1(
        allocator,
        absolute_directory,
        model_image_name,
    );
    defer allocator.free(image_path);
    var model =
        try engine.loader.loadPrepared(allocator, image_path);
    defer model.deinit();
    const recovered_prompt = try allocator.alloc(
        u32,
        selected.manifest.promptCount(),
    );
    defer allocator.free(recovered_prompt);
    for (recovered_prompt, 0..) |*token, index|
        token.* = try selected.manifest.promptToken(index);
    const local_plan = try prepared.makePlanV1(
        model,
        recovered_prompt,
        selected.manifest.options,
    );
    if (!std.meta.eql(local_plan, selected.manifest.plan))
        return error.RestartPlanDrift;
    try prepared.validateBoundPlanV1(
        selected.manifest.bound_plan,
    );

    var runtime: TargetRuntime = .{};
    try runtime.init(selected.manifest.target);
    var runtime_closed = false;
    defer {
        if (!runtime_closed)
            _ = runtime.scheduler.close() catch {};
    }
    const restore_evidence: restore.EvidenceV1 = .{
        .encoded_plan = selected.encoded_plan,
        .encoded_residency = selected.encoded_residency,
        .encoded_segment = selected.encoded_segment,
        .encoded_checkpoint = selected.encoded_checkpoint,
        .expected_checkpoint = selected.manifest.expected_checkpoint,
        .source = selected.manifest.source,
        .target = selected.manifest.target,
    };
    var restored_session: prepared.SessionV3 = .{};
    defer restored_session.deinit();
    const restore_decision =
        try restore.prepareRestoredAdmissionV1(
            &runtime.scheduler,
            &runtime.bank,
            restored_session
                .restoredPublicationSessionIdV1(),
            restore_evidence,
            &activation_grant,
        );
    var prepared_restore = switch (restore_decision) {
        .prepared => |value| value,
        .rejected => return error.TargetAdmissionRejected,
        .recovery_required => return error.TargetRecoveryRequired,
    };
    try restore.validatePreparedRestoredAdmissionV1(
        &prepared_restore,
        restore_evidence,
        &activation_grant,
    );
    try restored_session.startRestoredV1(
        allocator,
        &model,
        recovered_prompt,
        selected.manifest.options,
        local_plan,
        selected.manifest.bound_plan,
        &prepared_restore,
        restore_evidence,
        &activation_grant,
    );
    if (activation_grant.phase != .consumed)
        return error.ActivationGrantNotConsumed;

    var crash: CrashController = .{
        .requested = requested_crash,
        .input_generation = input_generation,
        .input_sequence = input_sequence,
        .sink_count = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = lease.selector.selector_sha256,
    };
    var sink_lock_storage: [1]u8 = undefined;
    var sink_ledger_storage: [max_result_ledger_bytes]u8 = undefined;
    var sink_store: DurableResultSinkV1 = undefined;
    if (preactivation_sink) |store| {
        sink_store = store;
        preactivation_sink = null;
    } else {
        sink_store = try DurableResultSinkV1.open(
            directory,
            if (source_sink_contract) |contract|
                contract.sink.storage_epoch
            else
                sink_storage_epoch,
            selected.manifest.plan.plan_sha256,
            if (source_sink_contract) |contract|
                contract.request_epoch
            else
                request_epoch,
            if (source_sink_contract) |contract|
                contract.sink.initial_sequence
            else
                1,
            if (source_sink_contract) |contract|
                contract.sink.implementation_sha256
            else
                sink_implementation_sha256,
            if (source_sink_contract) |contract|
                contract.sink.instance_sha256
            else
                sink_instance_sha256,
            &sink_lock_storage,
            &sink_ledger_storage,
            null,
        );
    }
    defer sink_store.close();
    sink_store.observer = .{
        .context = &crash,
        .after_phase_fn = CrashController.afterSinkPhase,
    };
    crash.sink_count =
        sink_store.selector.acknowledgement_count;
    crash.sink_ledger_sha256 =
        sink_store.selector.ledger_sha256;
    crash.sink_selector_sha256 =
        sink_store.selector.selector_sha256;
    if (sink_store.selector.next_sequence <
        input_sequence or
        sink_store.selector.next_sequence >
            input_sequence + 1)
        return error.ResultSinkSequenceDrift;

    var receipt_sink: ReceiptSink = .{};
    _ = try restored_session.step(
        try runtime.scheduler.prepareService(),
        receipt_sink.interface(),
    );
    if (receipt_sink.commit_calls != 1 or
        receipt_sink.abort_calls != 0)
        return error.InvalidRestoredStep;
    try crash.maybeCrash(.after_step_before_sink);
    const delivery =
        try result_sink.deliveryInputFromCommitReceiptV1(
            selected.manifest.plan.plan_sha256,
            receipt_sink.receipt,
        );
    if (delivery.transaction_sequence != input_sequence)
        return error.InvalidRestoredSequence;

    var preview_sink = sink_store.sink;
    const preview_result = try preview_sink.apply(delivery);
    if (preview_result.disposition == .applied) {
        var preview_ledger_storage: [max_result_ledger_bytes]u8 = undefined;
        const preview_ledger =
            try result_sink_file.encodeLedgerV1(
                preview_sink.request_sha256,
                preview_sink.request_epoch,
                preview_sink.initial_sequence,
                preview_sink.sink_implementation_sha256,
                preview_sink.sink_instance_sha256,
                preview_sink.acknowledgementSlice(),
                &preview_ledger_storage,
            );
        const preview_selector =
            try result_sink_file
                .prepareSuccessorSelectorV1(
                sink_store.selector,
                preview_ledger,
            );
        crash.successor_sink_count =
            preview_sink.applied_count;
        crash.successor_sink_ledger_sha256 =
            preview_ledger.ledger_sha256;
        crash.successor_sink_selector_sha256 =
            preview_selector.selector_sha256;
    } else {
        crash.successor_sink_count =
            sink_store.selector.acknowledgement_count;
        crash.successor_sink_ledger_sha256 =
            sink_store.selector.ledger_sha256;
        crash.successor_sink_selector_sha256 =
            sink_store.selector.selector_sha256;
    }
    const sink_apply = try sink_store.apply(
        delivery,
        &sink_ledger_storage,
    );
    const sink_disposition: SinkDisposition =
        switch (sink_apply.disposition) {
            .applied => .applied,
            .replayed => .replayed,
        };
    crash.sink_count =
        sink_store.selector.acknowledgement_count;
    crash.sink_ledger_sha256 =
        sink_store.selector.ledger_sha256;
    crash.sink_selector_sha256 =
        sink_store.selector.selector_sha256;
    try crash.maybeCrash(.after_sink_before_selector);

    var encoded_ack: [result_sink.acknowledgement_bytes]u8 = undefined;
    _ = try result_sink.encodeAcknowledgementV1(
        sink_apply.acknowledgement,
        &encoded_ack,
    );
    var output_copy: [options.max_new_tokens]u32 = undefined;
    const output_tokens = restored_session.outputTokens();
    if (output_tokens.len != input_sequence + 1 or
        output_tokens.len > output_copy.len)
        return error.InvalidRestoredSequence;
    @memcpy(output_copy[0..output_tokens.len], output_tokens);
    const output_generation =
        try std.math.add(u64, input_generation, 1);
    const output_sequence =
        try std.math.add(u64, input_sequence, 1);
    var terminal_semantic_sha256 = zero_digest;
    var terminal_selected = false;
    var selected_set: checkpoint_file.PreparedSetV1 =
        undefined;
    var selected_storage: ?[]u8 = null;
    defer if (selected_storage) |storage|
        allocator.free(storage);

    if (!restored_session.isFinished()) {
        const encoded_checkpoint =
            try restored_session.captureCheckpointV1(
                allocator,
                challenge,
            );
        defer allocator.free(encoded_checkpoint);
        const context = try checkpointContextV1(
            &restored_session,
            &model,
            restored_session.inner.bound_plan,
            local_plan,
        );
        if (context.boundary.base.publication.next_sequence !=
            output_sequence)
            return error.InvalidRestoredSequence;
        const next_target =
            try targetOwnershipForStageV1(
                output_generation,
                restored_session.inner.bound_plan,
            );
        const manifest_bytes =
            try restart_manifest.encodedBytesV1(
                recovered_prompt.len,
            );
        const manifest_storage =
            try allocator.alloc(u8, manifest_bytes);
        defer allocator.free(manifest_storage);
        const encoded_manifest =
            try restart_manifest.encodeV1(
                .{
                    .prompt = recovered_prompt,
                    .options = selected.manifest.options,
                    .plan = local_plan,
                    .bound_plan = restored_session.inner.bound_plan,
                    .expected_checkpoint = context.expected,
                    .source = context.source,
                    .target = next_target,
                },
                manifest_storage,
            );
        const restart_bytes =
            try archive.encodedRestartArchiveBytesV1(
                encoded_checkpoint.len,
                encoded_manifest.bytes.len,
            );
        const restart_storage =
            try allocator.alloc(u8, restart_bytes);
        defer allocator.free(restart_storage);
        _ = try archive.encodeRestartArchiveV1(
            output_generation,
            active_decoded.checkpoint_sha256,
            encoded_checkpoint,
            encoded_manifest.bytes,
            restart_storage,
        );
        const selected_bytes =
            try progress.encodedNonterminalBytesV1(
                restart_storage.len,
            );
        selected_storage =
            try allocator.alloc(u8, selected_bytes);
        const encoded_progress =
            try progress.encodeNonterminalV1(
                selected.active_set,
                selected.active_selector,
                restart_storage,
                &encoded_ack,
                selected_storage.?,
            );
        selected_set = encoded_progress.set;
    } else {
        const boundary =
            try restored_session.snapshotVerified();
        const semantic = try terminal.makeV1(
            boundary,
            restored_session.inner.bound_plan,
            local_plan,
            output_tokens,
            engine.lane_contiguous_publication
                .logicalKvPrefixSha256(
                &restored_session.inner.inner.resources.cache,
                restored_session.inner.inner.resources.cache.len,
            ),
        );
        var oracle_wire: [terminal.semantic_bytes]u8 = undefined;
        try readExactFileV1(
            directory,
            terminal_semantic_name,
            &oracle_wire,
        );
        const oracle = try terminal.decodeV1(&oracle_wire);
        if (!terminal.equivalentV1(oracle, semantic))
            return error.TerminalSemanticMismatch;
        var semantic_wire: [terminal.semantic_bytes]u8 = undefined;
        _ = try terminal.encodeV1(
            semantic,
            &semantic_wire,
        );
        var output_wire: [options.max_new_tokens * @sizeOf(u32)]u8 =
            undefined;
        encodeOutputTokensV1(
            output_tokens,
            &output_wire,
        );
        const selected_bytes =
            try progress.encodedTerminalBytesV1(
                selected.active_set.len,
                output_wire.len,
            );
        selected_storage =
            try allocator.alloc(u8, selected_bytes);
        const encoded_terminal =
            try progress.encodeTerminalV1(
                selected.active_set,
                selected.active_selector,
                &semantic_wire,
                &encoded_ack,
                &output_wire,
                selected_storage.?,
            );
        selected_set = encoded_terminal.set;
        terminal_semantic_sha256 =
            semantic.semantic_sha256;
        terminal_selected = true;
    }

    const checkpoint_publication =
        try checkpoint_file.preparePublicationV1(
            &lease,
            selected_set,
        );
    crash.successor_checkpoint_selector_sha256 =
        checkpoint_publication.selector.selector_sha256;
    const checkpoint_applied =
        if (requested_crash != null and
        isCheckpointCrashPointV1(requested_crash.?))
            try checkpoint_file.publishObservedV1(
                &lease,
                checkpoint_publication,
                .{
                    .context = &crash,
                    .after_phase_fn = CrashController.afterCheckpointPhase,
                },
            )
        else
            try checkpoint_file.recoverV1(
                &lease,
                checkpoint_publication,
            );
    if (checkpoint_applied.disposition != .applied and
        checkpoint_applied.disposition != .already_applied)
        return error.CheckpointPublicationFailed;

    if (terminal_selected) {
        const decoded = try progress.decodeTerminalV1(
            selected.active_set,
            selected.active_selector,
            selected_set.bytes,
            &checkpoint_publication.selector.bytes,
        );
        try acknowledged_restore.markTerminalSelectedV1(
            &activation_grant,
            decoded,
        );
        _ = try restored_session.retire();
    } else {
        const decoded = try progress.decodeNonterminalV1(
            selected.active_set,
            selected.active_selector,
            selected_set.bytes,
            &checkpoint_publication.selector.bytes,
        );
        try acknowledged_restore
            .markNonterminalSelectedV1(
            &activation_grant,
            decoded,
        );
        _ = try restored_session.cancel();
    }
    if (activation_grant.phase != .completed)
        return error.ActivationGrantNotCompleted;
    try requireRuntimeZeroV1(
        &runtime.bank,
        &runtime.scheduler,
    );
    _ = try runtime.scheduler.close();
    runtime_closed = true;
    const final_sink_selector = sink_store.selector;
    sink_store.close();
    const final_checkpoint_selector = lease.selector;
    lease.close();
    lease_open = false;
    try emitResultV1(.{
        .mode = "target",
        .input_generation = input_generation,
        .input_sequence = input_sequence,
        .output_generation = output_generation,
        .output_sequence = output_sequence,
        .sink_disposition = sink_disposition,
        .sink_count = final_sink_selector.acknowledgement_count,
        .sink_next_sequence = final_sink_selector.next_sequence,
        .sink_ledger_sha256 = final_sink_selector.ledger_sha256,
        .sink_selector_sha256 = final_sink_selector.selector_sha256,
        .checkpoint_selector_sha256 = final_checkpoint_selector.selector_sha256,
        .terminal = terminal_selected,
        .ownership_zero = true,
        .output_tokens = output_copy[0..@intCast(output_sequence)],
        .terminal_semantic_sha256 = terminal_semantic_sha256,
    });
}

const ResultFrameV1 = struct {
    mode: []const u8,
    input_generation: u64,
    input_sequence: u64,
    output_generation: u64,
    output_sequence: u64,
    sink_disposition: SinkDisposition,
    sink_count: usize,
    sink_next_sequence: u64,
    sink_ledger_sha256: Digest,
    sink_selector_sha256: Digest,
    checkpoint_selector_sha256: Digest,
    terminal: bool,
    ownership_zero: bool,
    output_tokens: []const u32,
    terminal_semantic_sha256: Digest,
};

fn emitResultV1(frame: ResultFrameV1) !void {
    if (frame.output_tokens.len > options.max_new_tokens)
        return error.InvalidResultFrame;
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"glacier.prepared-text-recovery/result-v1\"," ++
            "\"mode\":\"{s}\",\"pid\":{d}," ++
            "\"input_generation\":{d},\"input_sequence\":{d}," ++
            "\"output_generation\":{d},\"output_sequence\":{d}," ++
            "\"sink_disposition\":\"{s}\",\"sink_count\":{d}," ++
            "\"sink_next_sequence\":{d},\"sink_ledger_sha256\":\"",
        .{
            frame.mode,
            currentProcessId(),
            frame.input_generation,
            frame.input_sequence,
            frame.output_generation,
            frame.output_sequence,
            @tagName(frame.sink_disposition),
            frame.sink_count,
            frame.sink_next_sequence,
        },
    );
    try writeDigestV1(writer, frame.sink_ledger_sha256);
    try writer.writeAll("\",\"sink_selector_sha256\":\"");
    try writeDigestV1(writer, frame.sink_selector_sha256);
    try writer.writeAll(
        "\",\"checkpoint_selector_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.checkpoint_selector_sha256,
    );
    try writer.print(
        "\",\"terminal\":{s},\"ownership_zero\":{s}," ++
            "\"verified\":true,\"output_tokens\":[",
        .{
            booleanNameV1(frame.terminal),
            booleanNameV1(frame.ownership_zero),
        },
    );
    for (frame.output_tokens, 0..) |token, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{token});
    }
    try writer.writeAll(
        "],\"terminal_semantic_sha256\":",
    );
    if (std.mem.eql(
        u8,
        &frame.terminal_semantic_sha256,
        &zero_digest,
    )) {
        try writer.writeAll("null");
    } else {
        try writer.writeByte('"');
        try writeDigestV1(
            writer,
            frame.terminal_semantic_sha256,
        );
        try writer.writeByte('"');
    }
    try writer.writeAll("}\n");
    try writer.flush();
}

fn emitCrashReadyV1(
    controller: *const CrashController,
    point: CrashPoint,
) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":" ++
            "\"glacier.prepared-text-recovery/crash-ready-v1\"," ++
            "\"phase\":\"crash_ready\",\"pid\":{d}," ++
            "\"crash_point\":\"{s}\"," ++
            "\"input_generation\":{d},\"input_sequence\":{d}," ++
            "\"sink_count\":{d},\"sink_ledger_sha256\":\"",
        .{
            currentProcessId(),
            crashPointNameV1(point),
            controller.input_generation,
            controller.input_sequence,
            controller.sink_count,
        },
    );
    try writeDigestV1(
        writer,
        controller.sink_ledger_sha256,
    );
    try writer.writeAll("\",\"sink_selector_sha256\":\"");
    try writeDigestV1(
        writer,
        controller.sink_selector_sha256,
    );
    try writer.writeAll(
        "\",\"checkpoint_selector_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        controller.checkpoint_selector_sha256,
    );
    try writer.writeAll("\"}\n");
    try writer.flush();
}

fn runAuditV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    mode: []const u8,
) !void {
    var directory =
        try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();
    const active_storage =
        try allocator.alloc(u8, max_authority_bytes);
    defer allocator.free(active_storage);
    var checkpoint_lock_storage: [1]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        challenge,
        max_authority_bytes,
        &checkpoint_lock_storage,
        active_storage,
    );
    var lease_open = true;
    defer if (lease_open) lease.close();

    var selector_wire: [checkpoint_file.selector_bytes]u8 = undefined;
    try readExactFileV1(
        directory,
        checkpoint_file.active_selector_name,
        &selector_wire,
    );
    const selected_selector =
        try checkpoint_file.decodeSelectorV1(
            &selector_wire,
        );
    if (!std.meta.eql(selected_selector, lease.selector))
        return error.ActiveSelectorDrift;
    const selected_set = try lease.activeSet();
    if (selected_set.object_count !=
        progress.terminal_object_count)
        return error.TerminalNotSelected;
    const predecessor_selector_object =
        selected_set.objects[
            progress
                .terminal_predecessor_selector_object_ordinal
        ];
    const predecessor_set_object =
        selected_set.objects[
            progress
                .terminal_predecessor_set_object_ordinal
        ];
    const decoded = try progress.decodeTerminalV1(
        predecessor_set_object.bytes,
        predecessor_selector_object.bytes,
        lease.stream(),
        &selector_wire,
    );
    if (decoded.outputCount() != options.max_new_tokens or
        decoded.selected.selector.generation !=
            lease.selector.generation or
        decoded.selected.selector
            .publication_next_sequence !=
            options.max_new_tokens)
        return error.InvalidTerminalSelection;

    var oracle_wire: [terminal.semantic_bytes]u8 = undefined;
    try readExactFileV1(
        directory,
        terminal_semantic_name,
        &oracle_wire,
    );
    const oracle = try terminal.decodeV1(&oracle_wire);
    if (!terminal.equivalentV1(oracle, decoded.semantic))
        return error.TerminalSemanticMismatch;

    var output_tokens: [options.max_new_tokens]u32 = undefined;
    for (&output_tokens, 0..) |*token, index|
        token.* = try decoded.outputToken(index);

    var sink_lock_storage: [1]u8 = undefined;
    var sink_ledger_storage: [max_result_ledger_bytes]u8 = undefined;
    var sink_store =
        try result_sink_file.ResultSinkFileV1(
            sink_capacity,
        ).open(
            directory,
            sink_storage_epoch,
            decoded.semantic.local_plan_sha256,
            request_epoch,
            1,
            sink_implementation_sha256,
            sink_instance_sha256,
            &sink_lock_storage,
            &sink_ledger_storage,
            null,
        );
    var sink_open = true;
    defer if (sink_open) sink_store.close();
    if (sink_store.selector.acknowledgement_count !=
        sink_capacity or
        sink_store.selector.next_sequence !=
            options.max_new_tokens)
        return error.ResultSinkSequenceDrift;
    const acknowledgements =
        sink_store.sink.acknowledgementSlice();
    if (acknowledgements.len != sink_capacity or
        !std.meta.eql(
            acknowledgements[acknowledgements.len - 1],
            decoded.acknowledgement,
        ))
        return error.TerminalAcknowledgementDrift;
    for (acknowledgements, 0..) |acknowledgement, index| {
        if (acknowledgement.transaction_sequence !=
            index + 1 or
            acknowledgement.token_id !=
                output_tokens[index + 1] or
            !std.mem.eql(
                u8,
                &acknowledgement.request_sha256,
                &decoded.semantic.local_plan_sha256,
            ))
            return error.ResultSinkContentDrift;
    }

    const sink_selector = sink_store.selector;
    sink_store.close();
    sink_open = false;
    const checkpoint_selector = lease.selector;
    lease.close();
    lease_open = false;
    try emitResultV1(.{
        .mode = mode,
        .input_generation = checkpoint_selector.generation,
        .input_sequence = checkpoint_selector
            .publication_next_sequence,
        .output_generation = checkpoint_selector.generation,
        .output_sequence = checkpoint_selector
            .publication_next_sequence,
        .sink_disposition = .none,
        .sink_count = sink_selector.acknowledgement_count,
        .sink_next_sequence = sink_selector.next_sequence,
        .sink_ledger_sha256 = sink_selector.ledger_sha256,
        .sink_selector_sha256 = sink_selector.selector_sha256,
        .checkpoint_selector_sha256 = checkpoint_selector.selector_sha256,
        .terminal = true,
        .ownership_zero = true,
        .output_tokens = &output_tokens,
        .terminal_semantic_sha256 = decoded.semantic.semantic_sha256,
    });
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
        .state_commitment_sha256 = boundary.base.publication.state
            .commitment_sha256,
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

fn targetOwnershipForStageV1(
    stage: u64,
    source_bound_plan: prepared.BoundPlanV1,
) !successor.TargetOwnershipV1 {
    const generation = try std.math.add(
        u64,
        source_bound_plan.execution.generation,
        1,
    );
    if (stage != generation)
        return error.TargetStageDrift;
    const identity_offset =
        try std.math.mul(u64, stage, 0x100);
    const key_offset =
        try std.math.mul(u64, stage, 0x10);
    const key_base =
        try std.math.add(u64, target_key_base, key_offset);
    return .{
        .scheduler_epoch = try std.math.add(
            u64,
            target_scheduler_epoch_base,
            identity_offset,
        ),
        .coordinator_id = try std.math.add(
            u64,
            target_coordinator_id_base,
            identity_offset,
        ),
        .bank_epoch = try std.math.add(
            u64,
            target_bank_epoch_base,
            identity_offset,
        ),
        .request_generation = generation,
        .resource_owner_key = try std.math.add(u64, key_base, 1),
        .tree_key = try std.math.add(u64, key_base, 2),
        .authority_key = try std.math.add(u64, key_base, 3),
        .tenant_key = try std.math.add(u64, key_base, 4),
        .scope_key = try std.math.add(u64, key_base, 5),
        .cache_node_key = try std.math.add(u64, key_base, 6),
        .cache_binding_key = try std.math.add(u64, key_base, 7),
        .intent_generation = generation,
        .request_claim = source_bound_plan.residency.request_claim,
    };
}

fn requireRuntimeZeroV1(
    bank: *bank_api.Bank,
    scheduler: *lane.Scheduler,
) !void {
    const bank_snapshot = try bank.snapshotV3();
    const scheduler_snapshot = try scheduler.snapshot();
    if (!bank_snapshot.used.isZero() or
        bank_snapshot.active_lease_trees != 0 or
        bank_snapshot.active_lease_scopes != 0 or
        bank_snapshot.active_lease_nodes != 0 or
        bank_snapshot.live_allocations != 0 or
        scheduler_snapshot.active != 0)
        return error.RuntimeAuthorityLeak;
}

fn isCheckpointCrashPointV1(
    point: CrashPoint,
) bool {
    return switch (point) {
        .checkpoint_archive_write,
        .checkpoint_archive_sync,
        .checkpoint_archive_directory_sync,
        .checkpoint_selector_write,
        .checkpoint_selector_sync,
        .checkpoint_selector_rename,
        .checkpoint_selector_directory_sync,
        => true,
        else => false,
    };
}

fn encodeOutputTokensV1(
    tokens: []const u32,
    destination: []u8,
) void {
    std.debug.assert(
        destination.len == tokens.len * @sizeOf(u32),
    );
    for (tokens, 0..) |token, index| {
        const offset = index * @sizeOf(u32);
        std.mem.writeInt(
            u32,
            destination[offset..][0..4],
            token,
            .little,
        );
    }
}

fn writeDigestV1(
    writer: *std.Io.Writer,
    digest: Digest,
) !void {
    const encoded = std.fmt.bytesToHex(digest, .lower);
    try writer.writeAll(&encoded);
}

fn booleanNameV1(value: bool) []const u8 {
    return if (value) "true" else "false";
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

    try writeTinyModelSafetensorsV1(
        allocator,
        source_path,
    );
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
    var json_stream =
        std.io.fixedBufferStream(&json_storage);
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
            if (dimension_index != 0)
                try json.writeAll(",");
            try json.print("{d}", .{extent});
        }
        try json.print(
            "],\"data_offsets\":[{d},{d}]}}",
            .{ tensor.offset, tensor.offset + tensor.len },
        );
    }
    try json.writeAll(
        ",\"__metadata__\":{\"format\":\"pt\"}}",
    );
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
            const value =
                rng.random().floatNorm(f32) * scale;
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

fn requireStartedV1(
    decision: prepared.StartDecisionV1,
) !void {
    switch (decision) {
        .started => {},
        .rejected => return error.SourceAdmissionRejected,
    }
}

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}
