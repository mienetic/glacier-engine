const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const core = engine.core;
const checkpoint_file = core.continuation_checkpoint_file;
const model_contract = core.model_contract;
const bank_api = engine.resource_bank;
const lane = engine.lane_weave_qos;
const publication = engine.lane_publication_txn;
const package_manifest = engine.model_package_manifest;
const prepared = engine.prepared_text_session;
const checkpoint = engine.prepared_text_checkpoint;
const input_archive = engine.prepared_text_input_archive;
const raw_input = engine.prepared_text_raw_input;
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
const durable_runtime = engine.prepared_text_durable_runtime;
const direct_terminal_output =
    engine.prepared_text_direct_terminal_output;
const progress = engine.prepared_text_acknowledged_progress;
const acknowledged_restore =
    engine.prepared_text_acknowledged_restore;
const tokenizer = engine.tokenizer;

const Digest = [32]u8;
const dim: usize = 64;
const hidden: usize = 64;
const vocab: usize = 256;
const num_layers: usize = 1;
const legacy_prompt = [_]u32{ 1, 2, 3 };
const raw_prompt = "Ice ❄";
const raw_prompt_max_bytes: u64 = 4096;
const artifact_license =
    "SPDX-License-Identifier: Apache-2.0\n" ++
    "Synthetic recovery fixture only.\n";
const options: prepared.OptionsV1 = .{ .max_new_tokens = 4 };
const direct_options: prepared.OptionsV1 = .{
    .max_new_tokens = 1,
};
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
const source_step_sink_epoch: u64 =
    0x5231_5354_4550_0001;
const source_step_reservation_id: u64 = 1;

const model_source_name = "prepared-text-fixture.safetensors";
const model_container_name = "prepared-text-fixture.glacier";
const model_image_name = "prepared-text-fixture.glrt";
const model_package_name = "prepared-text-fixture.glpkg";
const terminal_semantic_name = "prepared-text-terminal-semantic.bin";
const portable_format_abi_v1: u64 = 0x474c_4143_0000_0001;
const prepared_format_abi_v2: u64 = 0x474c_5254_0000_0002;

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

    direct_after_step,
    direct_after_retire,
    direct_checkpoint_selector_rename,
    direct_after_generation_two,
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

    fn observeBootstrapPlan(
        raw: *anyopaque,
        plan: durable_runtime.BootstrapPlanV1,
    ) void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        self.successor_checkpoint_selector_sha256 =
            plan.selector_sha256;
    }

    fn observeSourceAdvancePlan(
        raw: *anyopaque,
        plan: durable_runtime.AdvancePlanV1,
    ) void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        switch (plan) {
            .recovered => |recovered| {
                self.input_generation =
                    recovered.input_generation;
                self.input_sequence =
                    recovered.input_sequence;
                self.checkpoint_selector_sha256 =
                    recovered
                        .checkpoint_selector_sha256;
                self.successor_sink_count = 0;
                self.successor_sink_ledger_sha256 =
                    recovered
                        .empty_sink_ledger_sha256;
                self.successor_sink_selector_sha256 =
                    recovered
                        .empty_sink_selector_sha256;
            },
            .successor => |successor_plan| {
                self.successor_checkpoint_selector_sha256 =
                    successor_plan.selector_sha256;
            },
        }
    }

    fn afterSourceAdvanceProgress(
        raw: *anyopaque,
        progress_value: durable_runtime.AdvanceProgressV1,
    ) anyerror!void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        self.input_generation =
            progress_value.input_generation;
        self.input_sequence =
            progress_value.input_sequence;
        self.sink_count = progress_value.sink_count;
        self.sink_ledger_sha256 =
            progress_value.sink_ledger_sha256;
        self.sink_selector_sha256 =
            progress_value.sink_selector_sha256;
        self.checkpoint_selector_sha256 =
            progress_value.checkpoint_selector_sha256;
        const point: CrashPoint =
            switch (progress_value.phase) {
                .after_recovery_admission => .source_after_recovery_admission,
                .after_initial_sink => .source_after_initial_sink,
                .after_step => .source_after_step,
                .after_handoff_prepare => .source_after_handoff_prepare,
                .after_exit_commit => .source_after_exit_commit,
                .after_generation_two => .source_after_generation_two,
            };
        try self.maybeCrash(point);
    }

    fn resolveStageTwoTarget(
        raw: *anyopaque,
        bound_plan: prepared.BoundPlanV1,
    ) anyerror!successor.TargetOwnershipV1 {
        _ = raw;
        return targetOwnershipForStageV1(
            2,
            bound_plan,
        );
    }

    fn resolveNextTarget(
        raw: *anyopaque,
        bound_plan: prepared.BoundPlanV1,
    ) anyerror!successor.TargetOwnershipV1 {
        _ = raw;
        const next_generation = try std.math.add(
            u64,
            bound_plan.execution.generation,
            1,
        );
        return targetOwnershipForStageV1(
            next_generation,
            bound_plan,
        );
    }

    fn observeTargetPlan(
        raw: *anyopaque,
        plan: durable_runtime.TargetPlanV1,
    ) void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        switch (plan) {
            .sink => |sink_plan| {
                self.successor_sink_count =
                    sink_plan.acknowledgement_count;
                self.successor_sink_ledger_sha256 =
                    sink_plan.ledger_sha256;
                self.successor_sink_selector_sha256 =
                    sink_plan.selector_sha256;
            },
            .checkpoint => |checkpoint_plan| {
                self.successor_checkpoint_selector_sha256 =
                    checkpoint_plan.selector_sha256;
            },
        }
    }

    fn afterTargetProgress(
        raw: *anyopaque,
        progress_value: durable_runtime.TargetProgressV1,
    ) anyerror!void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        self.input_generation =
            progress_value.input_generation;
        self.input_sequence =
            progress_value.input_sequence;
        self.sink_count = progress_value.sink_count;
        self.sink_ledger_sha256 =
            progress_value.sink_ledger_sha256;
        self.sink_selector_sha256 =
            progress_value.sink_selector_sha256;
        self.checkpoint_selector_sha256 =
            progress_value.checkpoint_selector_sha256;
        const point: CrashPoint =
            switch (progress_value.phase) {
                .after_step_before_sink => .after_step_before_sink,
                .after_sink_before_selector => .after_sink_before_selector,
            };
        try self.maybeCrash(point);
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

    fn observeDirectTerminalPlan(
        raw: *anyopaque,
        plan: durable_runtime.DirectTerminalPlanV1,
    ) void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        switch (plan) {
            .recovered => |recovered| {
                self.input_generation =
                    recovered.input_generation;
                self.input_sequence =
                    recovered.input_sequence;
                self.checkpoint_selector_sha256 =
                    recovered.checkpoint_selector_sha256;
            },
            .successor => |successor_plan| {
                self.successor_checkpoint_selector_sha256 =
                    successor_plan.selector_sha256;
            },
        }
    }

    fn afterDirectTerminalProgress(
        raw: *anyopaque,
        progress_value: durable_runtime.DirectTerminalProgressV1,
    ) anyerror!void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        self.input_generation =
            progress_value.input_generation;
        self.input_sequence =
            progress_value.input_sequence;
        self.checkpoint_selector_sha256 =
            progress_value.checkpoint_selector_sha256;
        const point: ?CrashPoint =
            switch (progress_value.phase) {
                .after_step => .direct_after_step,
                .after_retire => .direct_after_retire,
                .after_generation_two => .direct_after_generation_two,
                .after_recovery_admission,
                .after_terminal_prepare,
                => null,
            };
        if (point) |selected|
            try self.maybeCrash(selected);
    }

    fn afterDirectTerminalCheckpointPhase(
        raw: *anyopaque,
        phase: checkpoint_file.IoPhaseV1,
    ) checkpoint_file.Error!void {
        const self: *CrashController =
            @ptrCast(@alignCast(raw));
        if (phase == .selector_rename or
            phase == .selector_directory_sync)
        {
            self.checkpoint_selector_sha256 =
                self.successor_checkpoint_selector_sha256;
        }
        if (phase != .selector_rename) return;
        self.maybeCrash(
            .direct_checkpoint_selector_rename,
        ) catch return checkpoint_file.Error.PublicationMismatch;
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
            .sink_epoch = source_step_sink_epoch,
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

fn initTargetRuntimeForAdvanceV1(
    raw: *anyopaque,
    target: successor.TargetOwnershipV1,
) anyerror!durable_runtime.TargetRuntimeV1 {
    const runtime: *TargetRuntime =
        @ptrCast(@alignCast(raw));
    try runtime.init(target);
    return .{
        .bank = &runtime.bank,
        .scheduler = &runtime.scheduler,
    };
}

fn verifyFixtureTerminalSemanticV1(
    raw: *anyopaque,
    semantic: terminal.TerminalSemanticV1,
) anyerror!void {
    const directory: *std.fs.Dir =
        @ptrCast(@alignCast(raw));
    var oracle_wire: [terminal.semantic_bytes]u8 =
        undefined;
    try readExactFileV1(
        directory.*,
        terminal_semantic_name,
        &oracle_wire,
    );
    const oracle = try terminal.decodeV1(&oracle_wire);
    if (!terminal.equivalentV1(oracle, semantic))
        return error.TerminalSemanticMismatch;
}

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
    const directory = arguments[2];
    if (!std.fs.path.isAbsolute(directory))
        return error.DirectoryMustBeAbsolute;

    if (std.mem.eql(u8, arguments[1], "baseline")) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runBaselineV1(allocator, directory);
    } else if (std.mem.eql(
        u8,
        arguments[1],
        "direct-baseline",
    )) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runDirectBaselineV1(allocator, directory);
    } else if (std.mem.eql(
        u8,
        arguments[1],
        "direct-bootstrap",
    )) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runDirectBootstrapV1(allocator, directory);
    } else if (std.mem.eql(
        u8,
        arguments[1],
        "direct-terminal",
    )) {
        const crash_point = if (arguments.len == 4)
            try parseDirectTerminalCrashPointV1(
                arguments[3],
            )
        else
            null;
        try runDirectTerminalV1(
            allocator,
            directory,
            crash_point,
            false,
        );
    } else if (std.mem.eql(
        u8,
        arguments[1],
        "direct-audit",
    )) {
        if (arguments.len != 3) return error.InvalidArguments;
        try runDirectTerminalV1(
            allocator,
            directory,
            null,
            true,
        );
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

fn parseDirectTerminalCrashPointV1(
    encoded: []const u8,
) !?CrashPoint {
    const point =
        (try parseCrashPointV1(encoded)) orelse
        return error.InvalidCrashPoint;
    if (!isDirectTerminalCrashPointV1(point))
        return error.InvalidCrashPoint;
    return point;
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
    const tokenizer_manifest =
        try fixtureTokenizerManifestV1();
    var tokenized = try tokenizer.tokenizeUtf8BytesV1(
        allocator,
        tokenizer_manifest,
        raw_prompt,
    );
    defer tokenized.deinit();
    const local_plan =
        try prepared.makePlanV1(
            model,
            tokenized.tokens,
            options,
        );
    const bound_input =
        try fixtureBoundInputV1(tokenizer_manifest);
    const bound_plan = try prepared.makeBoundPlanV1(
        model,
        tokenized.tokens,
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
        tokenized.tokens,
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

fn runDirectBaselineV1(
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
    const tokenizer_manifest =
        try fixtureTokenizerManifestV1();
    var tokenized = try tokenizer.tokenizeUtf8BytesV1(
        allocator,
        tokenizer_manifest,
        raw_prompt,
    );
    defer tokenized.deinit();
    const local_plan =
        try prepared.makePlanV1(
            model,
            tokenized.tokens,
            direct_options,
        );
    const bound_input =
        try fixtureBoundInputV1(tokenizer_manifest);
    const bound_plan = try prepared.makeBoundPlanV1(
        model,
        tokenized.tokens,
        direct_options,
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
        tokenized.tokens,
        direct_options,
        local_plan,
        bound_input,
        bound_plan,
        scheduling,
        &runtime.scheduler,
        &runtime.bank,
    ));
    var sink: ReceiptSink = .{};
    sink.commit_calls = 0;
    _ = try session.step(
        try runtime.scheduler.prepareService(),
        sink.interface(),
    );
    if (sink.commit_calls != 1 or
        !session.isFinished())
        return error.InvalidDirectBaselineSequence;

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
    var encoded_semantic: [terminal.semantic_bytes]u8 =
        undefined;
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
    if (output_tokens.len != direct_options.max_new_tokens)
        return error.InvalidDirectBaselineSequence;
    const output_copy = [1]u32{output_tokens[0]};
    _ = try session.retire();
    try requireRuntimeZeroV1(
        &runtime.bank,
        &runtime.scheduler,
    );
    _ = try runtime.scheduler.close();
    runtime_closed = true;
    try emitResultV1(.{
        .mode = "direct-baseline",
        .input_generation = 1,
        .input_sequence = 0,
        .output_generation = 1,
        .output_sequence = direct_options.max_new_tokens,
        .sink_disposition = .none,
        .sink_count = 0,
        .sink_next_sequence = 0,
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
    const package = try readPackageManifestV1(directory);
    const representation = try preparedRepresentationV1(
        package,
        &model,
    );
    const tokenizer_manifest =
        try fixtureTokenizerManifestV1();
    var tokenized = try tokenizer.tokenizeUtf8BytesV1(
        allocator,
        tokenizer_manifest,
        raw_prompt,
    );
    defer tokenized.deinit();
    const local_plan =
        try prepared.makePlanV1(
            model,
            tokenized.tokens,
            options,
        );
    const bound_input =
        try fixtureBoundInputV1(tokenizer_manifest);
    const bound_plan = try prepared.makeBoundPlanV1(
        model,
        tokenized.tokens,
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
    var controller: CrashController = .{
        .requested = requested_crash,
        .input_generation = 0,
        .input_sequence = 0,
        .sink_count = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = zero_digest,
    };
    const bootstrap = try durable_runtime.bootstrapFileV1(
        allocator,
        .{
            .model = &model,
            .package = package,
            .representation = representation,
            .raw_text = raw_prompt,
            .tokenizer_manifest = tokenizer_manifest,
            .options = options,
            .scheduling = scheduling,
            .bound_plan_input = bound_input,
            .source_runtime = runtime_identity,
            .scheduler = &runtime.scheduler,
            .target = target,
            .sink = .{
                .storage_epoch = sink_storage_epoch,
                .capacity = sink_capacity,
                .implementation_sha256 = sink_implementation_sha256,
                .instance_sha256 = sink_instance_sha256,
            },
            .file = .{
                .directory = directory,
                .storage_epoch = storage_epoch,
                .max_set_bytes = max_authority_bytes,
            },
            .plan_observer = .{
                .context = &controller,
                .observe_fn = CrashController.observeBootstrapPlan,
            },
            .observer = .{
                .context = &controller,
                .after_phase_fn = CrashController
                    .afterBootstrapCheckpointPhase,
            },
        },
    );
    if (bootstrap.generation != 1 or
        bootstrap.request_epoch != request_epoch or
        bootstrap.publication_next_sequence != 1 or
        !digestEqual(
            bootstrap.selector_sha256,
            controller.successor_checkpoint_selector_sha256,
        ))
        return error.InvalidSourceBootstrap;

    try requireRuntimeZeroV1(
        &runtime.bank,
        &runtime.scheduler,
    );
    _ = try runtime.scheduler.close();
    runtime_closed = true;
    const no_tokens = [_]u32{};
    try emitResultV1(.{
        .mode = "source-bootstrap",
        .input_generation = 0,
        .input_sequence = 0,
        .output_generation = bootstrap.generation,
        .output_sequence = bootstrap.publication_next_sequence,
        .sink_disposition = .none,
        .sink_count = 0,
        .sink_next_sequence = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = bootstrap.selector_sha256,
        .terminal = false,
        .ownership_zero = true,
        .output_tokens = &no_tokens,
        .terminal_semantic_sha256 = zero_digest,
    });
}

fn runDirectBootstrapV1(
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

    var runtime: SourceRuntime = .{};
    try runtime.init();
    var runtime_closed = false;
    defer {
        if (!runtime_closed)
            _ = runtime.scheduler.close() catch {};
    }
    const package = try readPackageManifestV1(directory);
    const representation = try preparedRepresentationV1(
        package,
        &model,
    );
    const tokenizer_manifest =
        try fixtureTokenizerManifestV1();
    const bound_input =
        try fixtureBoundInputV1(tokenizer_manifest);
    const runtime_identity: durable_runtime.TerminalSourceRuntimeIdentityV1 = .{
        .scheduler_epoch = source_scheduler_epoch,
        .coordinator_id = source_coordinator_id,
        .bank_epoch = source_bank_epoch,
    };
    const bootstrap =
        try durable_runtime.bootstrapDirectTerminalFileV1(
            allocator,
            .{
                .model = &model,
                .package = package,
                .representation = representation,
                .raw_text = raw_prompt,
                .tokenizer_manifest = tokenizer_manifest,
                .options = direct_options,
                .scheduling = scheduling,
                .bound_plan_input = bound_input,
                .source_runtime = runtime_identity,
                .scheduler = &runtime.scheduler,
                .file = .{
                    .directory = directory,
                    .storage_epoch = storage_epoch,
                    .max_set_bytes = max_authority_bytes,
                },
            },
        );
    if (bootstrap.generation != 1 or
        bootstrap.request_epoch != request_epoch or
        bootstrap.publication_next_sequence != 1 or
        digestEqual(
            bootstrap.selector_sha256,
            zero_digest,
        ))
        return error.InvalidDirectBootstrap;

    try requireRuntimeZeroV1(
        &runtime.bank,
        &runtime.scheduler,
    );
    _ = try runtime.scheduler.close();
    runtime_closed = true;
    const no_tokens = [_]u32{};
    try emitResultV1(.{
        .mode = "direct-bootstrap",
        .input_generation = 0,
        .input_sequence = 0,
        .output_generation = bootstrap.generation,
        .output_sequence = bootstrap.publication_next_sequence,
        .sink_disposition = .none,
        .sink_count = 0,
        .sink_next_sequence = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = bootstrap.selector_sha256,
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
    var controller: CrashController = .{
        .requested = requested_crash,
        .input_generation = 0,
        .input_sequence = 0,
        .sink_count = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = zero_digest,
    };
    const advanced =
        try durable_runtime.advanceSourceFileV1(
            sink_capacity,
            allocator,
            .{
                .model = &model,
                .runtime = .{
                    .bank = &runtime.bank,
                    .scheduler = &runtime.scheduler,
                },
                .target = .{
                    .context = &controller,
                    .resolve_fn = CrashController.resolveStageTwoTarget,
                },
                .step_sink = .{
                    .sink_epoch = source_step_sink_epoch,
                    .reservation_id = source_step_reservation_id,
                },
                .sink = .{
                    .storage_epoch = sink_storage_epoch,
                    .capacity = sink_capacity,
                    .implementation_sha256 = sink_implementation_sha256,
                    .instance_sha256 = sink_instance_sha256,
                },
                .file = .{
                    .directory = directory,
                    .storage_epoch = storage_epoch,
                    .max_set_bytes = max_authority_bytes,
                },
                .observers = .{
                    .plan = .{
                        .context = &controller,
                        .observe_fn = CrashController
                            .observeSourceAdvancePlan,
                    },
                    .progress = .{
                        .context = &controller,
                        .after_phase_fn = CrashController
                            .afterSourceAdvanceProgress,
                    },
                    .sink = .{
                        .context = &controller,
                        .after_phase_fn = CrashController
                            .afterSourceSinkPhase,
                    },
                    .checkpoint = if (requested_crash != null)
                        .{
                            .context = &controller,
                            .after_phase_fn = CrashController
                                .afterSourceCheckpointPhase,
                        }
                    else
                        null,
                },
                .fail_stop = .{
                    .context = &controller,
                    .invoke_fn = failStopSourceTransitionAdapterV1,
                },
            },
        );
    if (!advanced.ownership_closed or
        advanced.input_generation !=
            source_lease.source_live_set_generation or
        advanced.input_sequence != 1 or
        advanced.output_generation !=
            durable.source_exited_set_generation or
        advanced.output_sequence != 1 or
        advanced.sink_count != 0 or
        advanced.sink_next_sequence != 1)
        return error.InvalidSourceTransition;
    runtime_closed = true;
    const source_output = [1]u32{
        advanced.output_token,
    };
    try emitResultV1(.{
        .mode = "source-transition",
        .input_generation = advanced.input_generation,
        .input_sequence = advanced.input_sequence,
        .output_generation = advanced.output_generation,
        .output_sequence = advanced.output_sequence,
        .sink_disposition = .none,
        .sink_count = advanced.sink_count,
        .sink_next_sequence = advanced.sink_next_sequence,
        .sink_ledger_sha256 = advanced.sink_ledger_sha256,
        .sink_selector_sha256 = advanced.sink_selector_sha256,
        .checkpoint_selector_sha256 = advanced.checkpoint_selector_sha256,
        .terminal = false,
        .ownership_zero = advanced.ownership_closed,
        .output_tokens = &source_output,
        .terminal_semantic_sha256 = zero_digest,
    });
}

fn runDirectTerminalV1(
    allocator: std.mem.Allocator,
    absolute_directory: []const u8,
    requested_crash: ?CrashPoint,
    audit_only: bool,
) !void {
    if (audit_only and requested_crash != null)
        return error.InvalidArguments;
    if (requested_crash) |point| {
        if (!isDirectTerminalCrashPointV1(point))
            return error.InvalidCrashPoint;
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
    var controller: CrashController = .{
        .requested = requested_crash,
        .input_generation = 0,
        .input_sequence = 0,
        .sink_count = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = zero_digest,
    };
    const step_sink: durable_runtime.SourceStepSinkV1 =
        if (audit_only)
            .{
                .sink_epoch = 0,
                .reservation_id = 0,
            }
        else
            .{
                .sink_epoch = source_step_sink_epoch,
                .reservation_id = source_step_reservation_id,
            };
    const receipt =
        try durable_runtime.advanceDirectTerminalSourceFileV1(
            allocator,
            .{
                .model = &model,
                .runtime = .{
                    .bank = &runtime.bank,
                    .scheduler = &runtime.scheduler,
                },
                .step_sink = step_sink,
                .file = .{
                    .directory = directory,
                    .storage_epoch = storage_epoch,
                    .max_set_bytes = max_authority_bytes,
                },
                .terminal_verifier = .{
                    .context = &directory,
                    .verify_fn = verifyFixtureTerminalSemanticV1,
                },
                .observers = .{
                    .plan = if (requested_crash != null)
                        .{
                            .context = &controller,
                            .observe_fn = CrashController
                                .observeDirectTerminalPlan,
                        }
                    else
                        null,
                    .progress = if (requested_crash != null)
                        .{
                            .context = &controller,
                            .after_phase_fn = CrashController
                                .afterDirectTerminalProgress,
                        }
                    else
                        null,
                    .checkpoint = if (requested_crash ==
                        .direct_checkpoint_selector_rename)
                        .{
                            .context = &controller,
                            .after_phase_fn = CrashController
                                .afterDirectTerminalCheckpointPhase,
                        }
                    else
                        null,
                },
                .fail_stop = .{
                    .context = &controller,
                    .invoke_fn = failStopSourceTransitionAdapterV1,
                },
            },
        );
    runtime_closed = true;
    if (!receipt.ownership_closed or
        receipt.input_generation != 1 or
        receipt.input_sequence != 1 or
        receipt.output_generation != 2 or
        receipt.output_sequence != 1 or
        digestEqual(receipt.checkpoint_sha256, zero_digest) or
        digestEqual(
            receipt.checkpoint_selector_sha256,
            zero_digest,
        ) or
        digestEqual(
            receipt.terminal_source_contract_sha256,
            zero_digest,
        ) or
        digestEqual(
            receipt.terminal_semantic_sha256,
            zero_digest,
        ))
        return error.InvalidDirectTerminalReceipt;
    if (audit_only and
        receipt.disposition != .already_selected)
        return error.InvalidDirectAuditDisposition;

    const view = try direct_terminal_output.inspectDirectoryV1(
        allocator,
        directory,
        .{ .max_set_bytes = max_authority_bytes },
    );
    try emitDirectTerminalResultV1(.{
        .mode = if (audit_only)
            "direct-audit"
        else
            "direct-terminal",
        .receipt = receipt,
        .view = view,
    });
}

fn failStopSourceTransitionV1() noreturn {
    std.process.exit(74);
}

fn failStopSourceTransitionAdapterV1(
    _: *anyopaque,
) noreturn {
    failStopSourceTransitionV1();
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
        try prepared.makePlanV1(model, &legacy_prompt, options);
    const bound_input = try boundInputV1();
    const bound_plan = try prepared.makeBoundPlanV1(
        model,
        &legacy_prompt,
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
        &legacy_prompt,
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
        try restart_manifest.encodedBytesV1(
            legacy_prompt.len,
        );
    const manifest_storage =
        try allocator.alloc(u8, manifest_bytes);
    defer allocator.free(manifest_storage);
    const encoded_manifest = try restart_manifest.encodeV1(
        .{
            .prompt = &legacy_prompt,
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

    var runtime: TargetRuntime = .{};
    var crash: CrashController = .{
        .requested = requested_crash,
        .input_generation = 0,
        .input_sequence = 0,
        .sink_count = 0,
        .sink_ledger_sha256 = zero_digest,
        .sink_selector_sha256 = zero_digest,
        .checkpoint_selector_sha256 = zero_digest,
    };
    var output_storage: [options.max_new_tokens]u32 = undefined;
    const advanced =
        try durable_runtime.advanceTargetFileV1(
            sink_capacity,
            allocator,
            .{
                .model = &model,
                .runtime_factory = .{
                    .context = &runtime,
                    .init_fn = initTargetRuntimeForAdvanceV1,
                },
                .next_target = .{
                    .context = &crash,
                    .resolve_fn = CrashController.resolveNextTarget,
                },
                .step_sink = .{
                    .sink_epoch = source_step_sink_epoch,
                    .reservation_id = source_step_reservation_id,
                },
                .request_epoch = request_epoch,
                .sink_initial_sequence = 1,
                .challenge_sha256 = challenge,
                .sink = .{
                    .storage_epoch = sink_storage_epoch,
                    .capacity = sink_capacity,
                    .implementation_sha256 = sink_implementation_sha256,
                    .instance_sha256 = sink_instance_sha256,
                },
                .file = .{
                    .directory = directory,
                    .storage_epoch = storage_epoch,
                    .max_set_bytes = max_authority_bytes,
                },
                .output_storage = &output_storage,
                .terminal_verifier = .{
                    .context = &directory,
                    .verify_fn = verifyFixtureTerminalSemanticV1,
                },
                .observers = .{
                    .plan = .{
                        .context = &crash,
                        .observe_fn = CrashController.observeTargetPlan,
                    },
                    .progress = .{
                        .context = &crash,
                        .after_phase_fn = CrashController.afterTargetProgress,
                    },
                    .sink = .{
                        .context = &crash,
                        .after_phase_fn = CrashController.afterSinkPhase,
                    },
                    .checkpoint = if (requested_crash != null and
                        isCheckpointCrashPointV1(
                            requested_crash.?,
                        ))
                        .{
                            .context = &crash,
                            .after_phase_fn = CrashController
                                .afterCheckpointPhase,
                        }
                    else
                        null,
                },
                .fail_stop = .{
                    .context = &crash,
                    .invoke_fn = failStopSourceTransitionAdapterV1,
                },
            },
        );
    if (advanced.disposition == .already_terminal and
        requested_crash != null)
        return error.CrashPointAfterTerminal;
    if (!advanced.ownership_closed or
        advanced.output_sequence >
            options.max_new_tokens or
        advanced.output_tokens.len !=
            advanced.output_sequence)
        return error.InvalidTargetTransition;
    const sink_disposition: SinkDisposition =
        switch (advanced.sink_disposition) {
            .none => .none,
            .applied => .applied,
            .replayed => .replayed,
        };
    try emitResultV1(.{
        .mode = "target",
        .input_generation = advanced.input_generation,
        .input_sequence = advanced.input_sequence,
        .output_generation = advanced.output_generation,
        .output_sequence = advanced.output_sequence,
        .sink_disposition = sink_disposition,
        .sink_count = advanced.sink_count,
        .sink_next_sequence = advanced.sink_next_sequence,
        .sink_ledger_sha256 = advanced.sink_ledger_sha256,
        .sink_selector_sha256 = advanced.sink_selector_sha256,
        .checkpoint_selector_sha256 = advanced.checkpoint_selector_sha256,
        .terminal = advanced.terminal,
        .ownership_zero = advanced.ownership_closed,
        .output_tokens = advanced.output_tokens,
        .terminal_semantic_sha256 = advanced.terminal_semantic_sha256,
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

const DirectTerminalResultFrameV1 = struct {
    mode: []const u8,
    receipt: durable_runtime.AdvanceDirectTerminalSourceFileReceiptV1,
    view: direct_terminal_output.ViewV1,
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

fn emitDirectTerminalResultV1(
    frame: DirectTerminalResultFrameV1,
) !void {
    if (!frame.receipt.ownership_closed or
        !frame.view.terminal or
        frame.view.acknowledgement_count != 0 or
        frame.view.token_count != 1 or
        frame.receipt.output_generation !=
            frame.view.generation or
        frame.receipt.output_sequence !=
            frame.view.publication_next_sequence or
        frame.receipt.output_token !=
            frame.view.output_token or
        !digestEqual(
            frame.receipt.checkpoint_sha256,
            frame.view.selected_set_sha256,
        ) or
        !digestEqual(
            frame.receipt.checkpoint_selector_sha256,
            frame.view.selected_selector_sha256,
        ) or
        !digestEqual(
            frame.receipt
                .terminal_source_contract_sha256,
            frame.view.terminal_source_contract_sha256,
        ) or
        !digestEqual(
            frame.receipt.terminal_semantic_sha256,
            frame.view.terminal_semantic_sha256,
        ))
        return error.InvalidDirectTerminalResultFrame;

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":" ++
            "\"glacier.prepared-text-direct-terminal-recovery/result-v1\"," ++
            "\"mode\":\"{s}\",\"pid\":{d}," ++
            "\"disposition\":\"{s}\"," ++
            "\"receipt_input_generation\":{d}," ++
            "\"receipt_input_sequence\":{d}," ++
            "\"receipt_output_generation\":{d}," ++
            "\"receipt_output_sequence\":{d}," ++
            "\"receipt_output_token\":{d}," ++
            "\"receipt_checkpoint_sha256\":\"",
        .{
            frame.mode,
            currentProcessId(),
            @tagName(frame.receipt.disposition),
            frame.receipt.input_generation,
            frame.receipt.input_sequence,
            frame.receipt.output_generation,
            frame.receipt.output_sequence,
            frame.receipt.output_token,
        },
    );
    try writeDigestV1(
        writer,
        frame.receipt.checkpoint_sha256,
    );
    try writer.writeAll(
        "\",\"receipt_checkpoint_selector_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.receipt.checkpoint_selector_sha256,
    );
    try writer.writeAll(
        "\",\"receipt_terminal_source_contract_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.receipt.terminal_source_contract_sha256,
    );
    try writer.writeAll(
        "\",\"receipt_terminal_semantic_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.receipt.terminal_semantic_sha256,
    );
    try writer.print(
        "\",\"ownership_zero\":{s}," ++
            "\"view_abi\":{d},\"terminal\":{s}," ++
            "\"generation\":{d},\"request_epoch\":{d}," ++
            "\"publication_next_sequence\":{d}," ++
            "\"acknowledgement_count\":{d}," ++
            "\"token_count\":{d},\"output_token\":{d}," ++
            "\"package_sha256\":\"",
        .{
            booleanNameV1(frame.receipt.ownership_closed),
            frame.view.abi_version,
            booleanNameV1(frame.view.terminal),
            frame.view.generation,
            frame.view.request_epoch,
            frame.view.publication_next_sequence,
            frame.view.acknowledgement_count,
            frame.view.token_count,
            frame.view.output_token,
        },
    );
    try writeDigestV1(writer, frame.view.package_sha256);
    try writer.writeAll(
        "\",\"representation_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.representation_sha256,
    );
    try writer.writeAll(
        "\",\"input_archive_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.input_archive_sha256,
    );
    try writer.writeAll(
        "\",\"tokenizer_domain_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.tokenizer_domain_sha256,
    );
    try writer.writeAll(
        "\",\"tokenizer_behavior_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.tokenizer_behavior_sha256,
    );
    try writer.writeAll(
        "\",\"tokenizer_config_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.tokenizer_config_sha256,
    );
    try writer.writeAll(
        "\",\"local_plan_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.local_plan_sha256,
    );
    try writer.writeAll(
        "\",\"bound_plan_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.bound_plan_sha256,
    );
    try writer.writeAll(
        "\",\"terminal_source_contract_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.terminal_source_contract_sha256,
    );
    try writer.writeAll(
        "\",\"terminal_semantic_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.terminal_semantic_sha256,
    );
    try writer.writeAll(
        "\",\"terminal_output_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.terminal_output_sha256,
    );
    try writer.writeAll(
        "\",\"terminal_state_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.terminal_state_sha256,
    );
    try writer.writeAll(
        "\",\"selected_selector_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.selected_selector_sha256,
    );
    try writer.writeAll(
        "\",\"selected_set_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.selected_set_sha256,
    );
    try writer.writeAll(
        "\",\"predecessor_selector_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.predecessor_selector_sha256,
    );
    try writer.writeAll(
        "\",\"predecessor_set_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.predecessor_set_sha256,
    );
    try writer.writeAll(
        "\",\"challenge_sha256\":\"",
    );
    try writeDigestV1(
        writer,
        frame.view.challenge_sha256,
    );
    try writer.writeAll("\",\"view_sha256\":\"");
    try writeDigestV1(
        writer,
        frame.view.view_sha256,
    );
    try writer.writeAll("\"}\n");
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

fn isDirectTerminalCrashPointV1(
    point: CrashPoint,
) bool {
    return switch (point) {
        .direct_after_step,
        .direct_after_retire,
        .direct_checkpoint_selector_rename,
        .direct_after_generation_two,
        => true,
        else => false,
    };
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

fn readPackageManifestV1(
    directory: std.fs.Dir,
) !package_manifest.ManifestV1 {
    var encoded: [package_manifest.manifest_bytes]u8 =
        undefined;
    try readExactFileV1(
        directory,
        model_package_name,
        &encoded,
    );
    return package_manifest.decodeV1(&encoded);
}

fn preparedRepresentationV1(
    package: package_manifest.ManifestV1,
    model: *const engine.loader.LoadedModel,
) !package_manifest.PreparedRepresentationV1 {
    const expected_config = try packageConfigV1(model.config);
    if (!std.meta.eql(package.config, expected_config))
        return error.PackageModelConfigDrift;
    const image = if (model.prepared_image) |*value|
        value
    else
        return error.MissingPreparedImage;
    return package_manifest.makePreparedRepresentationV1(
        package,
        prepared_format_abi_v2,
        @intCast(engine.runtime_image.VERSION),
        image.identityV1(),
    );
}

fn packageConfigV1(
    config: engine.loader.ModelConfig,
) !package_manifest.ConfigV1 {
    return .{
        .dim = std.math.cast(u32, config.dim) orelse
            return error.InvalidFixtureConfig,
        .hidden_dim = std.math.cast(
            u32,
            config.hidden_dim,
        ) orelse return error.InvalidFixtureConfig,
        .layers = std.math.cast(
            u32,
            config.num_layers,
        ) orelse return error.InvalidFixtureConfig,
        .vocab = std.math.cast(
            u32,
            config.vocab_size,
        ) orelse return error.InvalidFixtureConfig,
        .heads = std.math.cast(
            u32,
            config.num_heads,
        ) orelse return error.InvalidFixtureConfig,
        .head_dim = std.math.cast(
            u32,
            config.head_dim,
        ) orelse return error.InvalidFixtureConfig,
        .kv_heads = std.math.cast(
            u32,
            config.num_kv_heads,
        ) orelse return error.InvalidFixtureConfig,
        .rms_eps = config.rms_eps,
        .rope_theta = config.rope_theta,
        .tie_embeddings = config.tie_word_embeddings,
    };
}

fn fixtureTokenizerManifestV1() !tokenizer.Utf8ByteManifestV1 {
    return tokenizer.makeUtf8ByteManifestV1(
        @intCast(vocab),
        raw_prompt_max_bytes,
    );
}

fn fixtureBoundInputV1(
    manifest: tokenizer.Utf8ByteManifestV1,
) !prepared.BoundPlanInputV1 {
    return raw_input.makeBoundPlanInputV1(
        request_epoch,
        manifest,
        model_contract.sha256(artifact_license),
    );
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
    const conversion =
        try engine.converter.convertSafetensors(
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
    const tokenizer_manifest =
        try fixtureTokenizerManifestV1();
    const package = try package_manifest.makeV1(.{
        .family = .autoregressive,
        .source_format = .safetensors,
        .portable_format_abi = portable_format_abi_v1,
        .conversion_profile_abi = engine.converter.conversion_profile_abi,
        .conversion_plan_abi = engine.converter.conversion_plan_abi,
        .tokenizer_manifest_abi = tokenizer.utf8_byte_manifest_abi,
        .tokenizer_manifest_bytes = tokenizer.utf8_byte_manifest_bytes,
        .source_bytes = conversion.source_bytes,
        .portable_bytes = conversion.output_bytes,
        .portable_page_count = conversion.num_pages,
        .license_bytes = artifact_license.len,
        .model_profile_id = @enumFromInt(255),
        .tensor_profile_abi = 1,
        .tensor_count = 1,
        .tensor_inventory_sha256 = [_]u8{0x25} ** 32,
        .config = try packageConfigV1(compact.config),
        .source_sha256 = conversion.source_sha256,
        .portable_artifact_sha256 = conversion.output_sha256,
        .conversion_profile_sha256 = conversion.conversion_profile_sha256,
        .conversion_plan_sha256 = conversion.conversion_plan_sha256,
        .model_content_sha256 = compact.source_fingerprint,
        .tokenizer_config_sha256 = tokenizer_manifest.config_sha256,
        .tokenizer_domain_sha256 = tokenizer_manifest.domain_sha256,
        .tokenizer_behavior_sha256 = tokenizer_manifest.behavior_sha256,
        .license_sha256 = model_contract.sha256(artifact_license),
    });
    var encoded_package: [package_manifest.manifest_bytes]u8 =
        undefined;
    _ = try package_manifest.encodeV1(
        package,
        &encoded_package,
    );
    var directory =
        try std.fs.openDirAbsolute(absolute_directory, .{});
    defer directory.close();
    try writeSyncedFileV1(
        directory,
        model_package_name,
        &encoded_package,
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
