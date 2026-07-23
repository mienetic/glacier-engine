//! Portable checkpoint and fresh-Bank restore for stateful model steps.
//!
//! The checkpoint binds the exact model/state publications after one committed
//! step. Restore charges retained-state ownership before caller-owned bytes
//! become visible, reconstructs both publications, and leaves the next family
//! adapter to publish the successor result and state.

const std = @import("std");
const model = @import("model_contract.zig");
const stateful = @import("stateful_model_adapter.zig");
const latent = @import("latent_step_adapter.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const checkpoint_abi: u64 = 0x4753_434b_0000_0001;
pub const checkpoint_bytes: usize = 512;
pub const checkpoint_body_bytes: usize =
    checkpoint_bytes - @sizeOf(Digest);
pub const allowed_flags: u64 = 0;

const checkpoint_magic = [8]u8{
    'G', 'S', 'C', 'H', 'K', 'P', '1', 0,
};
const checkpoint_domain =
    "glacier-stateful-model-checkpoint-v1\x00";

pub const Error = model.Error || stateful.Error ||
    resource_bank.Error || error{
    InvalidCheckpoint,
    InvalidState,
    InvalidMaterializedState,
    UnsafeBuffer,
    RestorePoisoned,
};

pub const RestorePlanV1 = struct {
    restore_bank_epoch: u64,
    restore_owner_key: u64,
    restore_tree_key: u64,
    restore_authority_key: u64,
    tenant_key: u64,
    scope_key: u64,
    allocation_key: u64,
    binding_key: u64,
};

pub const CheckpointV1 = struct {
    request_epoch: u64,
    current_step: u64,
    total_steps: u64,
    state_bytes: u64,
    source_bank_epoch: u64,
    restore_bank_epoch: u64,
    restore_owner_key: u64,
    restore_tree_key: u64,
    restore_authority_key: u64,
    tenant_key: u64,
    scope_key: u64,
    allocation_key: u64,
    binding_key: u64,
    publication_next_sequence: u64,
    visible_results: u64,
    artifact_sha256: Digest,
    model_publication_sha256: Digest,
    state_publication_sha256: Digest,
    previous_result_sha256: Digest,
    last_plan_sha256: Digest,
    last_output_sha256: Digest,
    current_state_sha256: Digest,
    challenge_sha256: Digest,
    checkpoint_sha256: Digest,
};

pub const RestorePhase = enum {
    idle,
    prepared,
    active,
    closed,
    poisoned,
};

pub const ResumeSession = struct {
    bank: *resource_bank.Bank = undefined,
    checkpoint: CheckpointV1 = undefined,
    model_publication: model.PublicationStateV1 = undefined,
    state_publication: stateful.StatePublicationV1 = undefined,
    receipt: resource_bank.Receipt = undefined,
    tree: resource_bank.LeaseTreeV1 = undefined,
    scope: resource_bank.LeaseNodeV1 = undefined,
    batch: resource_bank.LeaseAllocationBatchV1 = undefined,
    session_id: usize = 0,
    visible_state: ?[]u8 = null,
    phase: RestorePhase = .idle,

    pub fn prepareV1(
        self: *ResumeSession,
        bank: *resource_bank.Bank,
        checkpoint_wire: []const u8,
        state_publication_wire: []const u8,
    ) Error!void {
        if (self.phase != .idle) return Error.InvalidState;
        const checkpoint = try decodeCheckpointV1(
            checkpoint_wire,
        );
        const state_publication =
            try stateful.decodeStatePublicationV1(
                state_publication_wire,
            );
        const model_publication =
            try reconstructModelPublicationV1(
                checkpoint,
                state_publication,
            );
        if (bank.epoch != checkpoint.restore_bank_epoch or
            bank.epoch == checkpoint.source_bank_epoch)
            return Error.InvalidCheckpoint;
        const state_claim = try stateClaimV1(
            checkpoint.state_bytes,
        );
        const session_id = @intFromPtr(self);
        if (session_id == 0) return Error.InvalidState;

        var reservation: resource_bank.Reservation = undefined;
        var receipt: resource_bank.Receipt = undefined;
        var tree: resource_bank.LeaseTreeV1 = undefined;
        var scope: resource_bank.LeaseNodeV1 = undefined;
        var batch: resource_bank.LeaseAllocationBatchV1 =
            undefined;
        var stage: enum {
            none,
            reserved,
            committed,
            tree_open,
            session_bound,
            allocation_reserved,
        } = .none;
        errdefer switch (stage) {
            .none => {},
            .reserved => bank.cancel(reservation) catch {
                self.phase = .poisoned;
            },
            .committed => bank.release(receipt) catch {
                self.phase = .poisoned;
            },
            .tree_open => {
                bank.closeLeaseTree(tree) catch {
                    self.phase = .poisoned;
                };
                bank.release(receipt) catch {
                    self.phase = .poisoned;
                };
            },
            .session_bound => {
                bank.closePublicationSession(
                    receipt,
                    checkpoint.request_epoch,
                    session_id,
                    checkpoint.publication_next_sequence,
                ) catch {
                    self.phase = .poisoned;
                };
                bank.closeLeaseTree(tree) catch {
                    self.phase = .poisoned;
                };
                bank.release(receipt) catch {
                    self.phase = .poisoned;
                };
            },
            .allocation_reserved => {
                const empty_tree =
                    bank.abortAllocationsAfterFree(
                        batch,
                    ) catch blk: {
                        self.phase = .poisoned;
                        break :blk tree;
                    };
                bank.closePublicationSession(
                    receipt,
                    checkpoint.request_epoch,
                    session_id,
                    checkpoint.publication_next_sequence,
                ) catch {
                    self.phase = .poisoned;
                };
                bank.closeLeaseTree(empty_tree) catch {
                    self.phase = .poisoned;
                };
                bank.release(receipt) catch {
                    self.phase = .poisoned;
                };
            },
        };

        reservation = try bank.reserve(
            checkpoint.restore_owner_key,
            state_claim,
        );
        stage = .reserved;
        receipt = try bank.commit(reservation);
        stage = .committed;
        tree = try bank.openLeaseTree(
            receipt,
            checkpoint.restore_tree_key,
            checkpoint.restore_authority_key,
            state_claim,
        );
        stage = .tree_open;
        const opened = try bank.openLeaseScope(
            tree,
            checkpoint.scope_key,
            checkpoint.tenant_key,
            state_claim,
        );
        tree = opened.tree;
        scope = opened.scope;
        try bank.bindRestoredPublicationSessionWithLeaseTree(
            tree,
            checkpoint.source_bank_epoch,
            checkpoint.request_epoch,
            session_id,
            checkpoint.publication_next_sequence,
        );
        stage = .session_bound;
        var allocation: [1]resource_bank.LeaseNodeV1 =
            undefined;
        const specs = [_]resource_bank.LeaseAllocationSpecV1{
            .{
                .scope = scope,
                .node_key = checkpoint.allocation_key,
                .binding_key = checkpoint.binding_key,
                .claim = state_claim,
            },
        };
        const prepared =
            try bank.reserveAllocationsForSession(
                tree,
                checkpoint.request_epoch,
                session_id,
                checkpoint.publication_next_sequence,
                &specs,
                &allocation,
            );
        tree = prepared.tree;
        batch = prepared.batch;
        stage = .allocation_reserved;

        self.* = .{
            .bank = bank,
            .checkpoint = checkpoint,
            .model_publication = model_publication,
            .state_publication = state_publication,
            .receipt = receipt,
            .tree = tree,
            .scope = scope,
            .batch = batch,
            .session_id = session_id,
            .phase = .prepared,
        };
    }

    pub fn commitMaterializedV1(
        self: *ResumeSession,
        durable_state: []const u8,
        destination: []u8,
    ) Error!void {
        if (self.phase == .poisoned)
            return Error.RestorePoisoned;
        if (self.phase != .prepared)
            return Error.InvalidState;
        const state_bytes = std.math.cast(
            usize,
            self.checkpoint.state_bytes,
        ) orelse return Error.InvalidCheckpoint;
        if (durable_state.len != state_bytes or
            destination.len != state_bytes or
            !std.mem.eql(
                u8,
                &model.sha256(durable_state),
                &self.checkpoint.current_state_sha256,
            ))
            return Error.InvalidMaterializedState;
        if (slicesOverlap(durable_state, destination))
            return Error.UnsafeBuffer;

        @memset(destination, 0);
        @memcpy(destination, durable_state);
        if (!std.mem.eql(
            u8,
            &model.sha256(destination),
            &self.checkpoint.current_state_sha256,
        )) {
            @memset(destination, 0);
            return Error.InvalidMaterializedState;
        }
        self.tree = self.bank.commitAllocationsAfterAllocate(
            self.batch,
        ) catch {
            @memset(destination, 0);
            self.abortPreparedInternalV1() catch {
                self.phase = .poisoned;
            };
            return Error.RestorePoisoned;
        };
        self.visible_state = destination;
        self.phase = .active;
    }

    pub fn abortPreparedV1(
        self: *ResumeSession,
    ) Error!void {
        if (self.phase != .prepared)
            return Error.InvalidState;
        try self.abortPreparedInternalV1();
    }

    pub fn closeAndRelease(
        self: *ResumeSession,
    ) Error!void {
        if (self.phase == .poisoned)
            return Error.RestorePoisoned;
        if (self.phase != .active)
            return Error.InvalidState;
        const visible_state = self.visible_state orelse
            return Error.InvalidState;
        if (!std.mem.eql(
            u8,
            &model.sha256(visible_state),
            &self.checkpoint.current_state_sha256,
        ))
            return Error.InvalidMaterializedState;
        const retiring =
            try self.bank.beginRetireSubtreeForSession(
                self.tree,
                self.scope,
                self.checkpoint.request_epoch,
                self.session_id,
                self.checkpoint.publication_next_sequence,
            );
        const authorized = try self.bank.authorizeFree(
            retiring.ticket,
        );
        @memset(visible_state, 0);
        const empty_tree =
            self.bank.commitFreeAfterAllocatorFree(
                authorized.permit,
            ) catch {
                self.phase = .poisoned;
                return Error.RestorePoisoned;
            };
        try self.bank.closePublicationSession(
            self.receipt,
            self.checkpoint.request_epoch,
            self.session_id,
            self.checkpoint.publication_next_sequence,
        );
        try self.bank.closeLeaseTree(empty_tree);
        try self.bank.release(self.receipt);
        self.visible_state = null;
        self.phase = .closed;
    }

    fn abortPreparedInternalV1(
        self: *ResumeSession,
    ) Error!void {
        const empty_tree =
            try self.bank.abortAllocationsAfterFree(
                self.batch,
            );
        try self.bank.closePublicationSession(
            self.receipt,
            self.checkpoint.request_epoch,
            self.session_id,
            self.checkpoint.publication_next_sequence,
        );
        try self.bank.closeLeaseTree(empty_tree);
        try self.bank.release(self.receipt);
        self.phase = .closed;
    }
};

pub fn makeCheckpointV1(
    source_bank_epoch: u64,
    restore_plan: RestorePlanV1,
    model_publication: model.PublicationStateV1,
    state_publication: stateful.StatePublicationV1,
    last_result: model.ResultEnvelopeV1,
) Error!CheckpointV1 {
    try stateful.validateStatePublicationV1(
        state_publication,
    );
    try model.validateResultEnvelopeV1(last_result);
    const model_publication_sha256 =
        try model.publicationStateRootV1(
            model_publication,
        );
    const expected_sequence = std.math.sub(
        u64,
        state_publication.current_step,
        1,
    ) catch return Error.InvalidCheckpoint;
    if (state_publication.current_step == 0 or
        state_publication.current_step >=
            state_publication.total_steps or
        source_bank_epoch == 0 or
        source_bank_epoch != last_result.resource_bank_epoch or
        restore_plan.restore_bank_epoch == 0 or
        restore_plan.restore_bank_epoch == source_bank_epoch or
        restore_plan.restore_owner_key == 0 or
        restore_plan.restore_tree_key == 0 or
        restore_plan.restore_authority_key == 0 or
        restore_plan.tenant_key == 0 or
        restore_plan.scope_key == 0 or
        restore_plan.allocation_key == 0 or
        restore_plan.binding_key == 0 or
        model_publication.request_epoch !=
            state_publication.request_epoch or
        model_publication.next_sequence !=
            state_publication.current_step or
        model_publication.visible_results !=
            state_publication.current_step or
        last_result.request_epoch !=
            state_publication.request_epoch or
        last_result.generation !=
            state_publication.current_step or
        last_result.publication_sequence !=
            expected_sequence or
        !std.mem.eql(
            u8,
            &model_publication.artifact_sha256,
            &state_publication.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &last_result.artifact_sha256,
            &state_publication.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &model_publication.previous_result_sha256,
            &last_result.result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state_publication.previous_result_sha256,
            &last_result.result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &last_result.challenge_sha256,
            &state_publication.challenge_sha256,
        ))
        return Error.InvalidCheckpoint;
    var checkpoint: CheckpointV1 = .{
        .request_epoch = state_publication.request_epoch,
        .current_step = state_publication.current_step,
        .total_steps = state_publication.total_steps,
        .state_bytes = state_publication.state_bytes,
        .source_bank_epoch = source_bank_epoch,
        .restore_bank_epoch = restore_plan.restore_bank_epoch,
        .restore_owner_key = restore_plan.restore_owner_key,
        .restore_tree_key = restore_plan.restore_tree_key,
        .restore_authority_key = restore_plan.restore_authority_key,
        .tenant_key = restore_plan.tenant_key,
        .scope_key = restore_plan.scope_key,
        .allocation_key = restore_plan.allocation_key,
        .binding_key = restore_plan.binding_key,
        .publication_next_sequence = model_publication.next_sequence,
        .visible_results = model_publication.visible_results,
        .artifact_sha256 = state_publication.artifact_sha256,
        .model_publication_sha256 = model_publication_sha256,
        .state_publication_sha256 = state_publication.publication_sha256,
        .previous_result_sha256 = last_result.result_sha256,
        .last_plan_sha256 = last_result.plan_sha256,
        .last_output_sha256 = last_result.output_sha256,
        .current_state_sha256 = state_publication.current_state_sha256,
        .challenge_sha256 = state_publication.challenge_sha256,
        .checkpoint_sha256 = [_]u8{0} ** 32,
    };
    checkpoint.checkpoint_sha256 =
        checkpointRootV1(checkpoint);
    try validateCheckpointV1(checkpoint);
    return checkpoint;
}

pub fn encodeCheckpointV1(
    checkpoint: CheckpointV1,
    output: *[checkpoint_bytes]u8,
) Error![]const u8 {
    try validateCheckpointV1(checkpoint);
    writeCheckpointBodyV1(
        checkpoint,
        output[0..checkpoint_body_bytes],
    );
    @memcpy(
        output[checkpoint_body_bytes..],
        &checkpoint.checkpoint_sha256,
    );
    return output;
}

pub fn decodeCheckpointV1(
    encoded: []const u8,
) Error!CheckpointV1 {
    if (encoded.len != checkpoint_bytes or
        !std.mem.eql(u8, encoded[0..8], &checkpoint_magic) or
        readU64(encoded, 8) != checkpoint_abi or
        readU64(encoded, 16) != checkpoint_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(
            u8,
            encoded[416..checkpoint_body_bytes],
            0,
        ))
        return Error.InvalidCheckpoint;
    const checkpoint: CheckpointV1 = .{
        .request_epoch = readU64(encoded, 32),
        .current_step = readU64(encoded, 40),
        .total_steps = readU64(encoded, 48),
        .state_bytes = readU64(encoded, 56),
        .source_bank_epoch = readU64(encoded, 64),
        .restore_bank_epoch = readU64(encoded, 72),
        .restore_owner_key = readU64(encoded, 80),
        .restore_tree_key = readU64(encoded, 88),
        .restore_authority_key = readU64(encoded, 96),
        .tenant_key = readU64(encoded, 104),
        .scope_key = readU64(encoded, 112),
        .allocation_key = readU64(encoded, 120),
        .binding_key = readU64(encoded, 128),
        .publication_next_sequence = readU64(
            encoded,
            136,
        ),
        .visible_results = readU64(encoded, 144),
        .artifact_sha256 = encoded[160..192].*,
        .model_publication_sha256 = encoded[192..224].*,
        .state_publication_sha256 = encoded[224..256].*,
        .previous_result_sha256 = encoded[256..288].*,
        .last_plan_sha256 = encoded[288..320].*,
        .last_output_sha256 = encoded[320..352].*,
        .current_state_sha256 = encoded[352..384].*,
        .challenge_sha256 = encoded[384..416].*,
        .checkpoint_sha256 = encoded[checkpoint_body_bytes..checkpoint_bytes].*,
    };
    try validateCheckpointV1(checkpoint);
    var canonical: [checkpoint_bytes]u8 = undefined;
    _ = try encodeCheckpointV1(checkpoint, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidCheckpoint;
    return checkpoint;
}

pub fn validateCheckpointV1(
    checkpoint: CheckpointV1,
) Error!void {
    if (checkpoint.request_epoch == 0 or
        checkpoint.current_step == 0 or
        checkpoint.current_step >= checkpoint.total_steps or
        checkpoint.state_bytes == 0 or
        checkpoint.source_bank_epoch == 0 or
        checkpoint.restore_bank_epoch == 0 or
        checkpoint.source_bank_epoch ==
            checkpoint.restore_bank_epoch or
        checkpoint.restore_owner_key == 0 or
        checkpoint.restore_tree_key == 0 or
        checkpoint.restore_authority_key == 0 or
        checkpoint.tenant_key == 0 or
        checkpoint.scope_key == 0 or
        checkpoint.allocation_key == 0 or
        checkpoint.binding_key == 0 or
        checkpoint.publication_next_sequence !=
            checkpoint.current_step or
        checkpoint.visible_results !=
            checkpoint.current_step or
        isZero(checkpoint.artifact_sha256) or
        isZero(checkpoint.model_publication_sha256) or
        isZero(checkpoint.state_publication_sha256) or
        isZero(checkpoint.previous_result_sha256) or
        isZero(checkpoint.last_plan_sha256) or
        isZero(checkpoint.last_output_sha256) or
        isZero(checkpoint.current_state_sha256) or
        isZero(checkpoint.challenge_sha256) or
        !std.mem.eql(
            u8,
            &checkpointRootV1(checkpoint),
            &checkpoint.checkpoint_sha256,
        ))
        return Error.InvalidCheckpoint;
}

pub fn checkpointRootV1(
    checkpoint: CheckpointV1,
) Digest {
    var body: [checkpoint_body_bytes]u8 = undefined;
    writeCheckpointBodyV1(checkpoint, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(checkpoint_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn reconstructModelPublicationV1(
    checkpoint: CheckpointV1,
    state_publication: stateful.StatePublicationV1,
) Error!model.PublicationStateV1 {
    try validateCheckpointV1(checkpoint);
    try stateful.validateStatePublicationV1(
        state_publication,
    );
    if (state_publication.request_epoch !=
        checkpoint.request_epoch or
        state_publication.current_step !=
            checkpoint.current_step or
        state_publication.total_steps !=
            checkpoint.total_steps or
        state_publication.state_bytes !=
            checkpoint.state_bytes or
        !std.mem.eql(
            u8,
            &state_publication.artifact_sha256,
            &checkpoint.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state_publication.publication_sha256,
            &checkpoint.state_publication_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state_publication.previous_result_sha256,
            &checkpoint.previous_result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state_publication.current_state_sha256,
            &checkpoint.current_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state_publication.challenge_sha256,
            &checkpoint.challenge_sha256,
        ))
        return Error.InvalidCheckpoint;
    const publication: model.PublicationStateV1 = .{
        .request_epoch = checkpoint.request_epoch,
        .next_sequence = checkpoint.publication_next_sequence,
        .visible_results = checkpoint.visible_results,
        .artifact_sha256 = checkpoint.artifact_sha256,
        .previous_result_sha256 = checkpoint.previous_result_sha256,
    };
    if (!std.mem.eql(
        u8,
        &try model.publicationStateRootV1(publication),
        &checkpoint.model_publication_sha256,
    ))
        return Error.InvalidCheckpoint;
    return publication;
}

fn stateClaimV1(
    state_bytes: u64,
) Error!resource_bank.Claim {
    _ = std.math.cast(usize, state_bytes) orelse
        return Error.InvalidCheckpoint;
    return .{ .staging_bytes = state_bytes };
}

fn writeCheckpointBodyV1(
    checkpoint: CheckpointV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &checkpoint_magic);
    writeU64(output, 8, checkpoint_abi);
    writeU64(output, 16, checkpoint_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, checkpoint.request_epoch);
    writeU64(output, 40, checkpoint.current_step);
    writeU64(output, 48, checkpoint.total_steps);
    writeU64(output, 56, checkpoint.state_bytes);
    writeU64(output, 64, checkpoint.source_bank_epoch);
    writeU64(output, 72, checkpoint.restore_bank_epoch);
    writeU64(output, 80, checkpoint.restore_owner_key);
    writeU64(output, 88, checkpoint.restore_tree_key);
    writeU64(output, 96, checkpoint.restore_authority_key);
    writeU64(output, 104, checkpoint.tenant_key);
    writeU64(output, 112, checkpoint.scope_key);
    writeU64(output, 120, checkpoint.allocation_key);
    writeU64(output, 128, checkpoint.binding_key);
    writeU64(
        output,
        136,
        checkpoint.publication_next_sequence,
    );
    writeU64(output, 144, checkpoint.visible_results);
    @memcpy(output[160..192], &checkpoint.artifact_sha256);
    @memcpy(
        output[192..224],
        &checkpoint.model_publication_sha256,
    );
    @memcpy(
        output[224..256],
        &checkpoint.state_publication_sha256,
    );
    @memcpy(
        output[256..288],
        &checkpoint.previous_result_sha256,
    );
    @memcpy(output[288..320], &checkpoint.last_plan_sha256);
    @memcpy(
        output[320..352],
        &checkpoint.last_output_sha256,
    );
    @memcpy(
        output[352..384],
        &checkpoint.current_state_sha256,
    );
    @memcpy(output[384..416], &checkpoint.challenge_sha256);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(
        usize,
        a_start,
        a.len,
    ) catch return true;
    const b_end = std.math.add(
        usize,
        b_start,
        b.len,
    ) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(
        u64,
        output[offset .. offset + 8][0..8],
        value,
        .little,
    );
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

const TestStorage = struct {
    slots: [4]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 4,
    roots: [4]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 4,
    nodes: [8]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 8,
};

const SourceRun = struct {
    fixture: latent.ReferenceFixtureV1,
    result: model.ResultEnvelopeV1,
    state: [4]u8,
    checkpoint: CheckpointV1,
};

fn sourceRunV1(
    bank: *resource_bank.Bank,
) !SourceRun {
    var fixture = try latent.makeReferenceFixtureV1();
    var context: u8 = 1;
    const adapter = try latent.referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var session: latent.Session = .{};
    try session.initV1(
        bank,
        81_101,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate_output: [4]u8 = undefined;
    var candidate_state: [4]u8 = undefined;
    var visible_output: [4]u8 = undefined;
    var visible_state: [4]u8 = undefined;
    _ = try session.prepareV1(
        &latent.reference_weights,
        &latent.reference_conditioning,
        &latent.reference_initial_state,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    const result = try session.commitV1();
    const checkpoint = try makeCheckpointV1(
        bank.epoch,
        .{
            .restore_bank_epoch = 82_001,
            .restore_owner_key = 82_101,
            .restore_tree_key = 82_201,
            .restore_authority_key = 82_301,
            .tenant_key = 82_401,
            .scope_key = 82_501,
            .allocation_key = 82_601,
            .binding_key = 82_701,
        },
        fixture.model_publication,
        fixture.state_publication,
        result,
    );
    try session.closeAndRelease();
    return .{
        .fixture = fixture,
        .result = result,
        .state = visible_state,
        .checkpoint = checkpoint,
    };
}

test "stateful checkpoint wire is canonical and mutation complete" {
    var storage: TestStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        81_001,
    );
    const source = try sourceRunV1(&bank);
    var encoded: [checkpoint_bytes]u8 = undefined;
    _ = try encodeCheckpointV1(
        source.checkpoint,
        &encoded,
    );
    var expected_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_root,
        "e7c583987b17c0d13498e59a965b2106" ++
            "18ceb364f94acd541f0f7b44e6a4625d",
    );
    try std.testing.expectEqual(
        expected_root,
        source.checkpoint.checkpoint_sha256,
    );
    try std.testing.expectEqual(
        source.checkpoint,
        try decodeCheckpointV1(&encoded),
    );
    for (0..encoded.len) |index| {
        var mutated = encoded;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidCheckpoint,
            decodeCheckpointV1(&mutated),
        );
    }
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}

test "fresh Bank restores intermediate state and publishes terminal step" {
    var source_storage: TestStorage = .{};
    var source_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &source_storage.slots,
            &source_storage.roots,
            &source_storage.nodes,
            .{},
            81_001,
        );
    const source = try sourceRunV1(&source_bank);
    var checkpoint_wire: [checkpoint_bytes]u8 = undefined;
    _ = try encodeCheckpointV1(
        source.checkpoint,
        &checkpoint_wire,
    );
    var state_wire: [stateful.state_publication_bytes]u8 =
        undefined;
    _ = try stateful.encodeStatePublicationV1(
        source.fixture.state_publication,
        &state_wire,
    );

    var target_storage: TestStorage = .{};
    var target_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &target_storage.slots,
            &target_storage.roots,
            &target_storage.nodes,
            .{},
            source.checkpoint.restore_bank_epoch,
        );
    var resumed: ResumeSession = .{};
    try resumed.prepareV1(
        &target_bank,
        &checkpoint_wire,
        &state_wire,
    );
    const reserved = try target_bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 1),
        reserved.reserved_unmaterialized_allocations,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        reserved.live_allocations,
    );
    var restored_state = [_]u8{0xaa} ** 4;
    const foreign_state = [_]u8{ 8, 16, 24, 31 };
    try std.testing.expectError(
        Error.InvalidMaterializedState,
        resumed.commitMaterializedV1(
            &foreign_state,
            &restored_state,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{0xaa} ** 4,
        &restored_state,
    );
    var aliased_state = source.state;
    try std.testing.expectError(
        Error.UnsafeBuffer,
        resumed.commitMaterializedV1(
            &aliased_state,
            &aliased_state,
        ),
    );
    try resumed.commitMaterializedV1(
        &source.state,
        &restored_state,
    );
    const active = try target_bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 0),
        active.reserved_unmaterialized_allocations,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        active.live_allocations,
    );

    const second_plan = try latent.makeReferencePlanV1(
        source.fixture.manifest,
        resumed.model_publication,
        resumed.state_publication,
        source.checkpoint.last_plan_sha256,
    );
    var context: u8 = 1;
    const adapter = try latent.referenceAdapterV1(
        source.fixture.manifest,
        &context,
    );
    var terminal: latent.Session = .{};
    try terminal.initV1(
        &target_bank,
        83_001,
        &resumed.model_publication,
        &resumed.state_publication,
        source.fixture.manifest,
        second_plan,
        adapter,
    );
    var candidate_output: [4]u8 = undefined;
    var candidate_state: [4]u8 = undefined;
    var final_output: [4]u8 = undefined;
    var final_state: [4]u8 = undefined;
    _ = try terminal.prepareV1(
        &latent.reference_weights,
        &latent.reference_conditioning,
        &restored_state,
        &candidate_output,
        &candidate_state,
        &final_output,
        &final_state,
    );
    const terminal_result = try terminal.commitV1();
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 6, 12, 18, 24 },
        &final_output,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        resumed.model_publication.visible_results,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        resumed.state_publication.current_step,
    );
    try std.testing.expectEqual(
        resumed.state_publication.total_steps,
        resumed.state_publication.current_step,
    );
    try std.testing.expectEqual(
        terminal_result.result_sha256,
        resumed.state_publication.previous_result_sha256,
    );
    try resumed.closeAndRelease();
    try std.testing.expect(std.mem.allEqual(
        u8,
        &restored_state,
        0,
    ));
    try terminal.closeAndRelease();
    const final = try target_bank.snapshotV3();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(
        @as(u64, 0),
        final.live_allocations,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        final.active_lease_trees,
    );
}
