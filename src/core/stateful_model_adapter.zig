//! Shared transactional lifecycle for model operations that replace retained
//! state as part of publishing a typed result.
//!
//! Family adapters validate state meaning. This layer owns exact admission,
//! candidate isolation, state/result co-publication, abort scrubbing, and
//! release.

const std = @import("std");
const model = @import("model_contract.zig");
const stateless = @import("stateless_model_adapter.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const state_publication_abi: u64 = 0x4753_5450_0000_0001;
pub const state_publication_bytes: usize = 320;
pub const state_publication_body_bytes =
    state_publication_bytes - @sizeOf(Digest);
pub const allowed_flags: u64 = 0;

const state_magic = [8]u8{
    'G', 'S', 'T', 'A', 'T', 'E', '1', 0,
};
const state_domain = "glacier-stateful-model-publication-v1\x00";
const transition_domain = "glacier-stateful-model-transition-v1\x00";

pub const Error = model.Error || stateless.Error ||
    resource_bank.Error || error{
    InvalidStatePublication,
    InvalidBinding,
    InvalidState,
    BufferTooSmall,
    BackendFailed,
    CandidateInvalid,
    CandidateDrift,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
};

pub const StatePublicationV1 = struct {
    request_epoch: u64,
    current_step: u64,
    total_steps: u64,
    state_bytes: u64,
    artifact_sha256: Digest,
    current_state_sha256: Digest,
    previous_result_sha256: Digest,
    challenge_sha256: Digest,
    publication_sha256: Digest,
};

pub const AdapterDescriptorV1 = stateless.AdapterDescriptorV1;

pub const ExecuteFn = *const fn (
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    current_state: []const u8,
    candidate_output: []u8,
    candidate_state: []u8,
) anyerror!void;

pub const ValidateCandidateFn = *const fn (
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    current_state: []const u8,
    candidate_output: []const u8,
    candidate_state: []const u8,
) anyerror!void;

pub const AdapterV1 = struct {
    context: *anyopaque,
    descriptor: AdapterDescriptorV1,
    execute_fn: ExecuteFn,
    validate_candidate_fn: ValidateCandidateFn,
};

pub const Phase = enum {
    idle,
    prepared,
    published,
    closed,
    poisoned,
};

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    model_publication: *model.PublicationStateV1 = undefined,
    state_publication: *StatePublicationV1 = undefined,
    manifest: model.ArtifactManifestV1 = undefined,
    plan: model.ExecutionPlanV1 = undefined,
    adapter: AdapterV1 = undefined,
    support_records: []const model.SupportRecordV1 = &.{},
    receipt: resource_bank.Receipt = undefined,
    permit: ?resource_bank.PublicationPermit = null,
    prepared_result: ?model.ResultEnvelopeV1 = null,
    candidate_output: ?[]u8 = null,
    candidate_state: ?[]u8 = null,
    visible_output: ?[]u8 = null,
    current_state: ?[]const u8 = null,
    visible_next_state: ?[]u8 = null,
    expected_output_sha256: Digest = [_]u8{0} ** 32,
    expected_state_sha256: Digest = [_]u8{0} ** 32,
    expected_state_publication_sha256: Digest = [_]u8{0} ** 32,
    bound_model_publication_sha256: Digest = [_]u8{0} ** 32,
    bound_state_publication_sha256: Digest = [_]u8{0} ** 32,
    next_resource_sequence: u64 = 0,
    initialized: bool = false,
    phase: Phase = .idle,

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        model_publication: *model.PublicationStateV1,
        state_publication: *StatePublicationV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        adapter: AdapterV1,
        support_records: []const model.SupportRecordV1,
    ) Error!void {
        if (self.initialized or owner_key == 0 or
            support_records.len == 0)
            return Error.InvalidState;
        try validateAdapterForPlanV1(
            adapter,
            manifest,
            plan,
            support_records,
        );
        try validateStatePublicationV1(state_publication.*);
        const model_publication_sha256 =
            try model.publicationStateRootV1(model_publication.*);
        const expected_generation = std.math.add(
            u64,
            state_publication.current_step,
            1,
        ) catch return Error.InvalidBinding;
        if (state_publication.current_step >=
            state_publication.total_steps or
            plan.generation != expected_generation or
            plan.request_epoch != state_publication.request_epoch or
            model_publication.request_epoch != plan.request_epoch or
            model_publication.next_sequence !=
                plan.publication_next_sequence or
            !std.mem.eql(
                u8,
                &model_publication.artifact_sha256,
                &manifest.artifact_sha256,
            ) or
            !std.mem.eql(
                u8,
                &state_publication.artifact_sha256,
                &manifest.artifact_sha256,
            ) or
            !std.mem.eql(
                u8,
                &state_publication.previous_result_sha256,
                &model_publication.previous_result_sha256,
            ) or
            !std.mem.eql(
                u8,
                &state_publication.challenge_sha256,
                &plan.challenge_sha256,
            ) or
            !std.mem.eql(
                u8,
                &state_publication.publication_sha256,
                &plan.processor_state_sha256,
            ) or
            !std.mem.eql(
                u8,
                &state_publication.current_state_sha256,
                &plan.cache_payload_sha256,
            ))
            return Error.InvalidBinding;
        try validateExactClaimV1(plan, state_publication.state_bytes);
        const reservation = bank.reserve(owner_key, plan.claim) catch
            return Error.ResourceAdmissionFailed;
        const receipt = bank.commit(reservation) catch {
            bank.cancel(reservation) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceAdmissionFailed;
        };
        bank.bindPublicationSession(
            receipt,
            plan.request_epoch,
            @intFromPtr(self),
        ) catch {
            bank.release(receipt) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        self.* = .{
            .bank = bank,
            .model_publication = model_publication,
            .state_publication = state_publication,
            .manifest = manifest,
            .plan = plan,
            .adapter = adapter,
            .support_records = support_records,
            .receipt = receipt,
            .bound_model_publication_sha256 = model_publication_sha256,
            .bound_state_publication_sha256 = state_publication.publication_sha256,
            .initialized = true,
        };
    }

    pub fn prepareV1(
        self: *Session,
        weights: []const u8,
        input: []const u8,
        current_state: []const u8,
        candidate_output: []u8,
        candidate_state: []u8,
        visible_output: []u8,
        visible_next_state: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.initialized or self.phase != .idle or
            self.permit != null or self.prepared_result != null)
            return Error.InvalidState;
        try validateAdapterForPlanV1(
            self.adapter,
            self.manifest,
            self.plan,
            self.support_records,
        );
        try validateStatePublicationV1(self.state_publication.*);
        const model_publication_sha256 =
            try model.publicationStateRootV1(
                self.model_publication.*,
            );
        if (!std.mem.eql(
            u8,
            &model_publication_sha256,
            &self.bound_model_publication_sha256,
        ) or
            !std.mem.eql(
                u8,
                &self.state_publication.publication_sha256,
                &self.bound_state_publication_sha256,
            ))
            return Error.InvalidBinding;
        const state_bytes = std.math.cast(
            usize,
            self.state_publication.state_bytes,
        ) orelse return Error.InvalidBinding;
        const output_bytes = std.math.cast(
            usize,
            self.plan.output_bytes,
        ) orelse return Error.InvalidBinding;
        if (weights.len != self.manifest.weight_bytes or
            input.len != self.plan.input_bytes or
            current_state.len != state_bytes or
            candidate_state.len != state_bytes or
            candidate_output.len != output_bytes or
            visible_output.len != output_bytes or
            visible_next_state.len != state_bytes)
            return Error.BufferTooSmall;
        if (!std.mem.eql(
            u8,
            &model.sha256(weights),
            &self.manifest.weights_sha256,
        ) or
            !std.mem.eql(
                u8,
                &model.sha256(current_state),
                &self.state_publication.current_state_sha256,
            ))
            return Error.InvalidBinding;
        if (mutableBuffersOverlap(
            weights,
            input,
            current_state,
            candidate_output,
            candidate_state,
            visible_output,
            visible_next_state,
        ))
            return Error.InvalidBinding;
        @memset(candidate_output, 0);
        @memset(candidate_state, 0);
        const permit = self.bank.beginPublication(
            self.receipt,
            self.plan.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.adapter.execute_fn(
            self.adapter.context,
            &self.plan,
            weights,
            input,
            current_state,
            candidate_output,
            candidate_state,
        ) catch {
            @memset(candidate_output, 0);
            @memset(candidate_state, 0);
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.BackendFailed;
        };
        self.adapter.validate_candidate_fn(
            self.adapter.context,
            &self.plan,
            current_state,
            candidate_output,
            candidate_state,
        ) catch {
            @memset(candidate_output, 0);
            @memset(candidate_state, 0);
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.CandidateInvalid;
        };
        const output_sha256 = model.sha256(candidate_output);
        const state_sha256 = model.sha256(candidate_state);
        const transition_sha256 = try stateTransitionRootV1(
            self.state_publication.*,
            self.plan,
            output_sha256,
            state_sha256,
            self.adapter.descriptor.adapter_sha256,
        );
        const result = model.prepareResultEnvelopeV1(
            self.model_publication.*,
            self.plan,
            self.receipt,
            output_sha256,
            transition_sha256,
            self.adapter.descriptor.adapter_sha256,
        ) catch {
            @memset(candidate_output, 0);
            @memset(candidate_state, 0);
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.InvalidBinding;
        };
        self.permit = permit;
        self.prepared_result = result;
        self.candidate_output = candidate_output;
        self.candidate_state = candidate_state;
        self.visible_output = visible_output;
        self.current_state = current_state;
        self.visible_next_state = visible_next_state;
        self.expected_output_sha256 = output_sha256;
        self.expected_state_sha256 = state_sha256;
        self.expected_state_publication_sha256 =
            self.state_publication.publication_sha256;
        self.phase = .prepared;
        return result;
    }

    pub fn commitV1(self: *Session) Error!model.ResultEnvelopeV1 {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse return Error.InvalidState;
        const result = self.prepared_result orelse
            return Error.InvalidState;
        const candidate_output = self.candidate_output orelse
            return Error.InvalidState;
        const candidate_state = self.candidate_state orelse
            return Error.InvalidState;
        const visible_output = self.visible_output orelse
            return Error.InvalidState;
        const current_state = self.current_state orelse
            return Error.InvalidState;
        const visible_next_state = self.visible_next_state orelse
            return Error.InvalidState;
        self.bank.validatePublication(permit) catch {
            try self.rollbackV1(permit);
            return Error.ResourceReceiptInvalid;
        };
        const model_publication_sha256 =
            model.publicationStateRootV1(
                self.model_publication.*,
            ) catch {
                try self.rollbackV1(permit);
                return Error.CandidateDrift;
            };
        validateStatePublicationV1(self.state_publication.*) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.mem.eql(
            u8,
            &model_publication_sha256,
            &self.bound_model_publication_sha256,
        ) or
            !std.mem.eql(
                u8,
                &self.state_publication.publication_sha256,
                &self.expected_state_publication_sha256,
            ) or
            !std.mem.eql(
                u8,
                &model.sha256(current_state),
                &self.state_publication.current_state_sha256,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        self.adapter.validate_candidate_fn(
            self.adapter.context,
            &self.plan,
            current_state,
            candidate_output,
            candidate_state,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.mem.eql(
            u8,
            &model.sha256(candidate_output),
            &self.expected_output_sha256,
        ) or
            !std.mem.eql(
                u8,
                &model.sha256(candidate_state),
                &self.expected_state_sha256,
            ) or
            !std.mem.eql(
                u8,
                &self.expected_output_sha256,
                &result.output_sha256,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        const transition_sha256 = stateTransitionRootV1(
            self.state_publication.*,
            self.plan,
            self.expected_output_sha256,
            self.expected_state_sha256,
            self.adapter.descriptor.adapter_sha256,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.mem.eql(
            u8,
            &transition_sha256,
            &result.source_mapping_sha256,
        )) {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        var next_model_publication = self.model_publication.*;
        model.commitResultV1(
            &next_model_publication,
            result,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidBinding;
        };
        var next_state_publication = self.state_publication.*;
        next_state_publication.current_step = std.math.add(
            u64,
            next_state_publication.current_step,
            1,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidBinding;
        };
        next_state_publication.current_state_sha256 =
            self.expected_state_sha256;
        next_state_publication.previous_result_sha256 =
            result.result_sha256;
        next_state_publication.publication_sha256 =
            statePublicationRootV1(next_state_publication);
        validateStatePublicationV1(next_state_publication) catch {
            try self.rollbackV1(permit);
            return Error.InvalidBinding;
        };
        @memcpy(visible_output, candidate_output);
        @memcpy(visible_next_state, candidate_state);
        self.model_publication.* = next_model_publication;
        self.state_publication.* = next_state_publication;
        self.bank.commitPublicationAssumeValid(permit);
        self.next_resource_sequence = permit.sequence + 1;
        @memset(candidate_output, 0);
        @memset(candidate_state, 0);
        self.clearPreparedV1();
        self.phase = .published;
        return result;
    }

    pub fn abortV1(self: *Session) Error!void {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse return Error.InvalidState;
        try self.rollbackV1(permit);
    }

    pub fn closeAndRelease(self: *Session) Error!void {
        if (!self.initialized or self.phase == .closed or
            self.phase == .prepared or self.phase == .poisoned)
            return Error.InvalidState;
        self.bank.closePublicationSession(
            self.receipt,
            self.plan.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.bank.release(self.receipt) catch
            return Error.ResourceReceiptInvalid;
        self.phase = .closed;
        self.initialized = false;
    }

    fn rollbackV1(
        self: *Session,
        permit: resource_bank.PublicationPermit,
    ) Error!void {
        if (self.candidate_output) |candidate| @memset(candidate, 0);
        if (self.candidate_state) |candidate| @memset(candidate, 0);
        self.bank.abortPublication(permit) catch {
            self.phase = .poisoned;
            return Error.ResourceReceiptInvalid;
        };
        self.clearPreparedV1();
        self.phase = .idle;
    }

    fn clearPreparedV1(self: *Session) void {
        self.permit = null;
        self.prepared_result = null;
        self.candidate_output = null;
        self.candidate_state = null;
        self.visible_output = null;
        self.current_state = null;
        self.visible_next_state = null;
        self.expected_output_sha256 = [_]u8{0} ** 32;
        self.expected_state_sha256 = [_]u8{0} ** 32;
        self.expected_state_publication_sha256 = [_]u8{0} ** 32;
    }
};

pub fn initializeStatePublicationV1(
    request_epoch: u64,
    total_steps: u64,
    state_bytes: u64,
    artifact_sha256: Digest,
    current_state_sha256: Digest,
    challenge_sha256: Digest,
) Error!StatePublicationV1 {
    var state: StatePublicationV1 = .{
        .request_epoch = request_epoch,
        .current_step = 0,
        .total_steps = total_steps,
        .state_bytes = state_bytes,
        .artifact_sha256 = artifact_sha256,
        .current_state_sha256 = current_state_sha256,
        .previous_result_sha256 = [_]u8{0} ** 32,
        .challenge_sha256 = challenge_sha256,
        .publication_sha256 = [_]u8{0} ** 32,
    };
    state.publication_sha256 = statePublicationRootV1(state);
    try validateStatePublicationV1(state);
    return state;
}

pub fn encodeStatePublicationV1(
    state: StatePublicationV1,
    output: *[state_publication_bytes]u8,
) Error![]const u8 {
    try validateStatePublicationV1(state);
    writeStateBodyV1(state, output[0..state_publication_body_bytes]);
    @memcpy(
        output[state_publication_body_bytes..],
        &state.publication_sha256,
    );
    return output;
}

pub fn decodeStatePublicationV1(
    encoded: []const u8,
) Error!StatePublicationV1 {
    if (encoded.len != state_publication_bytes or
        !std.mem.eql(u8, encoded[0..8], &state_magic) or
        readU64(encoded, 8) != state_publication_abi or
        readU64(encoded, 16) != state_publication_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(
            u8,
            encoded[192..state_publication_body_bytes],
            0,
        ))
        return Error.InvalidStatePublication;
    const state: StatePublicationV1 = .{
        .request_epoch = readU64(encoded, 32),
        .current_step = readU64(encoded, 40),
        .total_steps = readU64(encoded, 48),
        .state_bytes = readU64(encoded, 56),
        .artifact_sha256 = encoded[64..96].*,
        .current_state_sha256 = encoded[96..128].*,
        .previous_result_sha256 = encoded[128..160].*,
        .challenge_sha256 = encoded[160..192].*,
        .publication_sha256 = encoded[state_publication_body_bytes..state_publication_bytes].*,
    };
    try validateStatePublicationV1(state);
    var canonical: [state_publication_bytes]u8 = undefined;
    _ = try encodeStatePublicationV1(state, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidStatePublication;
    return state;
}

pub fn validateStatePublicationV1(
    state: StatePublicationV1,
) Error!void {
    if (state.request_epoch == 0 or state.total_steps == 0 or
        state.current_step > state.total_steps or
        state.state_bytes == 0 or
        isZero(state.artifact_sha256) or
        isZero(state.current_state_sha256) or
        isZero(state.challenge_sha256) or
        (state.current_step == 0 and
            !isZero(state.previous_result_sha256)) or
        (state.current_step != 0 and
            isZero(state.previous_result_sha256)) or
        !std.mem.eql(
            u8,
            &statePublicationRootV1(state),
            &state.publication_sha256,
        ))
        return Error.InvalidStatePublication;
}

pub fn statePublicationRootV1(
    state: StatePublicationV1,
) Digest {
    var body: [state_publication_body_bytes]u8 = undefined;
    writeStateBodyV1(state, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(state_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn stateTransitionRootV1(
    state_before: StatePublicationV1,
    plan: model.ExecutionPlanV1,
    output_sha256: Digest,
    next_state_sha256: Digest,
    adapter_sha256: Digest,
) Error!Digest {
    try validateStatePublicationV1(state_before);
    try model.validateExecutionPlanV1(plan);
    const next_step = std.math.add(
        u64,
        state_before.current_step,
        1,
    ) catch return Error.InvalidBinding;
    if (next_step != plan.generation or
        plan.request_epoch != state_before.request_epoch or
        !std.mem.eql(
            u8,
            &plan.artifact_sha256,
            &state_before.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.challenge_sha256,
            &state_before.challenge_sha256,
        ) or
        isZero(output_sha256) or isZero(next_state_sha256) or
        isZero(adapter_sha256))
        return Error.InvalidBinding;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(transition_domain);
    hash.update(&state_before.publication_sha256);
    hash.update(&plan.plan_sha256);
    hash.update(&output_sha256);
    hash.update(&next_state_sha256);
    hash.update(&adapter_sha256);
    hash.update(&state_before.challenge_sha256);
    hashU64(&hash, next_step);
    return hash.finalResult();
}

pub fn makeAdapterDescriptorV1(
    adapter_abi: u64,
    manifest: model.ArtifactManifestV1,
    operation: model.OperationIdV1,
    allowed_capabilities: u64,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    return stateless.makeAdapterDescriptorV1(
        adapter_abi,
        manifest,
        operation,
        allowed_capabilities,
        implementation_sha256,
    );
}

pub fn validateAdapterForPlanV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    support_records: []const model.SupportRecordV1,
) Error!void {
    const stateless_adapter: stateless.AdapterV1 = .{
        .context = adapter.context,
        .descriptor = adapter.descriptor,
        .execute_fn = adapterDescriptorOnlyExecute,
        .validate_candidate_fn = adapterDescriptorOnlyValidate,
    };
    try stateless.validateAdapterForPlanV1(
        stateless_adapter,
        manifest,
        plan,
        support_records,
    );
}

fn adapterDescriptorOnlyExecute(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    candidate: []u8,
) anyerror!void {
    _ = context;
    _ = plan;
    _ = weights;
    _ = input;
    _ = candidate;
}

fn adapterDescriptorOnlyValidate(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
) anyerror!void {
    _ = context;
    _ = plan;
    _ = candidate;
}

fn validateExactClaimV1(
    plan: model.ExecutionPlanV1,
    state_bytes: u64,
) Error!void {
    const publication_bytes = std.math.add(
        u64,
        plan.output_bytes,
        state_bytes,
    ) catch return Error.InvalidBinding;
    if (plan.scratch_bytes != plan.output_bytes or
        plan.claim.capsule_bytes != plan.weight_bytes or
        plan.claim.activation_bytes != plan.input_bytes or
        plan.claim.partial_bytes != plan.output_bytes or
        plan.claim.output_journal_bytes != publication_bytes or
        plan.claim.staging_bytes != state_bytes or
        plan.claim.queue_slots != 1 or plan.claim.kv_bytes != 0 or
        plan.claim.logits_bytes != 0 or plan.claim.device_bytes != 0 or
        plan.claim.io_bytes != 0)
        return Error.InvalidBinding;
}

fn writeStateBodyV1(
    state: StatePublicationV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &state_magic);
    writeU64(output, 8, state_publication_abi);
    writeU64(output, 16, state_publication_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, state.request_epoch);
    writeU64(output, 40, state.current_step);
    writeU64(output, 48, state.total_steps);
    writeU64(output, 56, state.state_bytes);
    @memcpy(output[64..96], &state.artifact_sha256);
    @memcpy(output[96..128], &state.current_state_sha256);
    @memcpy(output[128..160], &state.previous_result_sha256);
    @memcpy(output[160..192], &state.challenge_sha256);
}

fn mutableBuffersOverlap(
    weights: []const u8,
    input: []const u8,
    current_state: []const u8,
    candidate_output: []const u8,
    candidate_state: []const u8,
    visible_output: []const u8,
    visible_next_state: []const u8,
) bool {
    const mutable = [_][]const u8{
        candidate_output,
        candidate_state,
        visible_output,
        visible_next_state,
    };
    for (mutable, 0..) |left, left_index| {
        for (mutable[left_index + 1 ..]) |right|
            if (slicesOverlap(left, right)) return true;
    }
    for (mutable) |buffer| {
        if (slicesOverlap(buffer, weights) or
            slicesOverlap(buffer, input) or
            slicesOverlap(buffer, current_state))
            return true;
    }
    return false;
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn hashU64(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, output[offset .. offset + 8][0..8], value, .little);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset .. offset + 8][0..8], .little);
}

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}
