//! Shared prepare/validate/publish lifecycle for stateless model adapters.
//!
//! Family-specific modules must validate their source/state/cache bindings
//! before entering this lifecycle. The backend receives only bounded slices.

const std = @import("std");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");
const qos = @import("lane_weave_qos.zig");

pub const Digest = [32]u8;
const descriptor_domain = "glacier-stateless-model-adapter-v1\x00";

pub const Error = model.Error || resource_bank.Error || error{
    InvalidAdapter,
    InvalidBinding,
    InvalidConfiguration,
    InvalidState,
    BufferTooSmall,
    BackendFailed,
    CandidateInvalid,
    CandidateDrift,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
};

pub const AdapterDescriptorV1 = struct {
    adapter_abi: u64,
    family: model.ModelFamilyIdV1,
    operation: model.OperationIdV1,
    input_kind: model.InputKindV1,
    output_kind: model.OutputKindV1,
    numerical_policy: model.NumericalPolicyV1,
    max_batch_items: u64,
    max_input_features: u64,
    max_output_dimensions: u64,
    allowed_capabilities: u64,
    implementation_sha256: Digest,
    adapter_sha256: Digest,
};

pub const ExecuteFn = *const fn (
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    candidate: []u8,
) anyerror!void;

pub const ValidateCandidateFn = *const fn (
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
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
    armed,
};

pub const ReceiptOwnerV1 = enum {
    session,
    scheduler,
};

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    publication_state: *model.PublicationStateV1 = undefined,
    manifest: model.ArtifactManifestV1 = undefined,
    plan: model.ExecutionPlanV1 = undefined,
    adapter: AdapterV1 = undefined,
    support_records: []const model.SupportRecordV1 = &.{},
    receipt: resource_bank.Receipt = undefined,
    permit: ?resource_bank.PublicationPermit = null,
    prepared_result: ?model.ResultEnvelopeV1 = null,
    candidate: ?[]u8 = null,
    visible_output: ?[]u8 = null,
    expected_candidate_sha256: Digest = [_]u8{0} ** 32,
    next_resource_sequence: u64 = 0,
    receipt_owner: ReceiptOwnerV1 = .session,
    scheduler: ?*qos.Scheduler = null,
    scheduled_handle: ?qos.Handle = null,
    initialized: bool = false,
    phase: Phase = .idle,

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        publication_state: *model.PublicationStateV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        adapter: AdapterV1,
        support_records: []const model.SupportRecordV1,
    ) Error!void {
        if (self.initialized or owner_key == 0 or support_records.len == 0)
            return Error.InvalidState;
        try validateAdapterForPlanV1(
            adapter,
            manifest,
            plan,
            support_records,
        );
        _ = try model.publicationStateRootV1(publication_state.*);
        if (publication_state.request_epoch != plan.request_epoch or
            publication_state.next_sequence !=
                plan.publication_next_sequence or
            !std.mem.eql(
                u8,
                &publication_state.artifact_sha256,
                &manifest.artifact_sha256,
            ))
            return Error.InvalidBinding;
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
            .publication_state = publication_state,
            .manifest = manifest,
            .plan = plan,
            .adapter = adapter,
            .support_records = support_records,
            .receipt = receipt,
            .receipt_owner = .session,
            .initialized = true,
        };
    }

    /// Adopt the exact committed receipt created by a current LaneWeave
    /// admission. The Session must already reside at its final address and
    /// must not move until `cancelScheduledV1` or `retireScheduledV1` returns.
    /// This path performs no ResourceBank reserve or commit.
    pub fn initScheduledV1(
        self: *Session,
        scheduler: *qos.Scheduler,
        admission: qos.Admission,
        publication_state: *model.PublicationStateV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        adapter: AdapterV1,
        support_records: []const model.SupportRecordV1,
    ) Error!void {
        if (self.initialized or support_records.len == 0)
            return Error.InvalidState;
        try validateAdapterForPlanV1(
            adapter,
            manifest,
            plan,
            support_records,
        );
        _ = try model.publicationStateRootV1(publication_state.*);
        if (publication_state.request_epoch != plan.request_epoch or
            publication_state.next_sequence !=
                plan.publication_next_sequence or
            !std.mem.eql(
                u8,
                &publication_state.artifact_sha256,
                &manifest.artifact_sha256,
            ))
            return Error.InvalidBinding;
        const event = admission.event;
        if (event.kind != .admission_accepted or
            event.rejection_reason != .none or
            !std.meta.eql(event.handle, admission.handle) or
            !std.meta.eql(event.spec.claim, plan.claim) or
            !std.meta.eql(event.resource_receipt.claim, plan.claim) or
            event.spec.resource_owner_key !=
                event.resource_receipt.owner_key)
            return Error.InvalidConfiguration;
        scheduler.bindFinalPublicationSession(
            admission,
            plan.request_epoch,
            @intFromPtr(self),
        ) catch |err| switch (err) {
            error.InvalidConfiguration => return Error.InvalidConfiguration,
            else => return Error.ResourceReceiptInvalid,
        };
        self.* = .{
            .bank = scheduler.bank,
            .publication_state = publication_state,
            .manifest = manifest,
            .plan = plan,
            .adapter = adapter,
            .support_records = support_records,
            .receipt = event.resource_receipt,
            .receipt_owner = .scheduler,
            .scheduler = scheduler,
            .scheduled_handle = admission.handle,
            .initialized = true,
        };
    }

    pub fn prepareV1(
        self: *Session,
        weights: []const u8,
        input: []const u8,
        source_mapping_sha256: Digest,
        candidate: []u8,
        visible_output: []u8,
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
        if (isZero(source_mapping_sha256) or
            weights.len != self.manifest.weight_bytes or
            input.len != self.plan.input_bytes or
            !std.mem.eql(
                u8,
                &model.sha256(weights),
                &self.manifest.weights_sha256,
            ))
            return Error.InvalidBinding;
        const candidate_bytes = std.math.cast(
            usize,
            self.plan.scratch_bytes,
        ) orelse return Error.InvalidBinding;
        const output_bytes = std.math.cast(
            usize,
            self.plan.output_bytes,
        ) orelse return Error.InvalidBinding;
        if (candidate_bytes != output_bytes or
            candidate.len < candidate_bytes or
            visible_output.len < output_bytes)
            return Error.BufferTooSmall;
        const candidate_slice = candidate[0..candidate_bytes];
        const visible_slice = visible_output[0..output_bytes];
        if (slicesOverlap(candidate_slice, visible_slice) or
            slicesOverlap(candidate_slice, weights) or
            slicesOverlap(candidate_slice, input) or
            slicesOverlap(visible_slice, weights) or
            slicesOverlap(visible_slice, input))
            return Error.InvalidBinding;
        @memset(candidate_slice, 0);
        @memset(visible_slice, 0);
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
            candidate_slice,
        ) catch {
            @memset(candidate_slice, 0);
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.BackendFailed;
        };
        self.adapter.validate_candidate_fn(
            self.adapter.context,
            &self.plan,
            candidate_slice,
        ) catch {
            @memset(candidate_slice, 0);
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.CandidateInvalid;
        };
        const candidate_sha256 = model.sha256(candidate_slice);
        const result = model.prepareResultEnvelopeV1(
            self.publication_state.*,
            self.plan,
            self.receipt,
            candidate_sha256,
            source_mapping_sha256,
            self.adapter.descriptor.adapter_sha256,
        ) catch {
            @memset(candidate_slice, 0);
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.InvalidBinding;
        };
        self.permit = permit;
        self.prepared_result = result;
        self.candidate = candidate_slice;
        self.visible_output = visible_slice;
        self.expected_candidate_sha256 = candidate_sha256;
        self.phase = .prepared;
        return result;
    }

    pub fn commitV1(self: *Session) Error!model.ResultEnvelopeV1 {
        if (!self.initialized or self.receipt_owner != .session or
            self.phase != .prepared)
            return Error.InvalidState;
        const candidate = try self.preflightCommitV1();
        self.finalizeCandidateAssumeValid(candidate);
        return candidate.result;
    }

    /// Freeze every fallible result-commit check against one already-armed
    /// LaneWeave final-service intent. The returned object must remain
    /// address-stable until its finalizer runs or `abort` is called. Session
    /// state and provisional buffers are immutable across that bounded
    /// interval; violating this contract is process-fatal in the V2 finalizer.
    pub fn armServiceV1(
        self: *Session,
        intent: qos.ServiceIntentV1,
    ) Error!ArmedScheduledResultV1 {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const scheduler = self.scheduler orelse
            return Error.InvalidState;
        const handle = self.scheduled_handle orelse
            return Error.InvalidState;
        if (self.receipt_owner != .scheduler or
            !qos.serviceIntentValidV1(intent) or
            intent.scheduler_epoch != scheduler.config.scheduler_epoch or
            !std.meta.eql(intent.handle, handle) or
            !std.meta.eql(intent.spec.claim, self.plan.claim) or
            !std.meta.eql(intent.resource_receipt, self.receipt) or
            intent.remaining_before != 1)
            return Error.InvalidConfiguration;
        const candidate = try self.preflightCommitV1();
        self.phase = .armed;
        return .{
            .session = self,
            .intent = intent,
            .candidate = candidate,
        };
    }

    pub fn abortV1(self: *Session) Error!void {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse return Error.InvalidState;
        try self.rollbackV1(permit);
    }

    pub fn closeAndRelease(self: *Session) Error!void {
        if (!self.initialized or self.receipt_owner != .session or
            self.phase == .closed or
            self.phase == .prepared or self.phase == .poisoned)
            return Error.InvalidState;
        self.bank.closePublicationSessionAndRelease(
            self.receipt,
            self.plan.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.phase = .closed;
        self.initialized = false;
    }

    /// Cancel scheduler-owned work that has not published a model result.
    /// Session close and receipt release are one Bank transition.
    pub fn cancelScheduledV1(self: *Session) Error!qos.EventV1 {
        if (!self.scheduledReadyToFinish(false))
            return Error.InvalidState;
        const scheduler = self.scheduler orelse return Error.InvalidState;
        const handle = self.scheduled_handle orelse return Error.InvalidState;
        const event = scheduler.cancelBoundPublication(
            handle,
            self.plan.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch |err| switch (err) {
            error.InvalidConfiguration => return Error.InvalidConfiguration,
            else => return Error.ResourceReceiptInvalid,
        };
        self.finishScheduledAssumeValid();
        return event;
    }

    /// Retire scheduler-owned work only after its one model result and final
    /// service transition have both committed.
    pub fn retireScheduledV1(self: *Session) Error!qos.EventV1 {
        if (!self.scheduledReadyToFinish(true))
            return Error.InvalidState;
        const scheduler = self.scheduler orelse return Error.InvalidState;
        const handle = self.scheduled_handle orelse return Error.InvalidState;
        const event = scheduler.retireBoundPublication(
            handle,
            self.plan.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch |err| switch (err) {
            error.InvalidConfiguration => return Error.InvalidConfiguration,
            else => return Error.ResourceReceiptInvalid,
        };
        self.finishScheduledAssumeValid();
        return event;
    }

    fn preflightCommitV1(self: *Session) Error!CommitCandidateV1 {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse return Error.InvalidState;
        const result = self.prepared_result orelse
            return Error.InvalidState;
        const candidate = self.candidate orelse
            return Error.InvalidState;
        const visible_output = self.visible_output orelse
            return Error.InvalidState;
        self.bank.validatePublication(permit) catch {
            try self.rollbackV1(permit);
            return Error.ResourceReceiptInvalid;
        };
        self.adapter.validate_candidate_fn(
            self.adapter.context,
            &self.plan,
            candidate,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.mem.eql(
            u8,
            &model.sha256(candidate),
            &self.expected_candidate_sha256,
        ) or
            !std.mem.eql(
                u8,
                &self.expected_candidate_sha256,
                &result.output_sha256,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        const state_before = self.publication_state.*;
        var next_state = state_before;
        model.commitResultV1(&next_state, result) catch {
            try self.rollbackV1(permit);
            return Error.InvalidBinding;
        };
        return .{
            .permit = permit,
            .result = result,
            .candidate = candidate,
            .visible_output = visible_output,
            .state_before = state_before,
            .state_after = next_state,
        };
    }

    fn finalizeCandidateAssumeValid(
        self: *Session,
        candidate: CommitCandidateV1,
    ) void {
        @memcpy(candidate.visible_output, candidate.candidate);
        self.publication_state.* = candidate.state_after;
        self.bank.commitPublicationAssumeValid(candidate.permit);
        self.next_resource_sequence = candidate.permit.sequence + 1;
        @memset(candidate.candidate, 0);
        self.clearPreparedV1();
        self.phase = .published;
    }

    fn rollbackV1(
        self: *Session,
        permit: resource_bank.PublicationPermit,
    ) Error!void {
        if (self.candidate) |candidate| @memset(candidate, 0);
        if (self.visible_output) |output| @memset(output, 0);
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
        self.candidate = null;
        self.visible_output = null;
        self.expected_candidate_sha256 = [_]u8{0} ** 32;
    }

    fn armedCandidateValidV1(
        self: *const Session,
        candidate: CommitCandidateV1,
    ) bool {
        if (!self.initialized or self.phase != .armed or
            self.receipt_owner != .scheduler)
            return false;
        const permit = self.permit orelse return false;
        const result = self.prepared_result orelse return false;
        const prepared_candidate = self.candidate orelse return false;
        const prepared_output = self.visible_output orelse return false;
        if (!std.meta.eql(permit, candidate.permit) or
            !std.meta.eql(result, candidate.result) or
            prepared_candidate.ptr != candidate.candidate.ptr or
            prepared_candidate.len != candidate.candidate.len or
            prepared_output.ptr != candidate.visible_output.ptr or
            prepared_output.len != candidate.visible_output.len or
            !std.meta.eql(self.publication_state.*, candidate.state_before))
            return false;
        const candidate_sha256 = model.sha256(candidate.candidate);
        if (!std.mem.eql(
            u8,
            &candidate_sha256,
            &self.expected_candidate_sha256,
        ) or
            !std.mem.eql(
                u8,
                &candidate_sha256,
                &candidate.result.output_sha256,
            ))
            return false;
        var expected_state = candidate.state_before;
        model.commitResultV1(
            &expected_state,
            candidate.result,
        ) catch return false;
        return std.meta.eql(expected_state, candidate.state_after);
    }

    fn scheduledReadyToFinish(
        self: *const Session,
        require_published: bool,
    ) bool {
        const expected_phase: Phase =
            if (require_published) .published else .idle;
        return self.initialized and self.receipt_owner == .scheduler and
            self.phase == expected_phase and self.permit == null and
            self.prepared_result == null and self.candidate == null and
            self.visible_output == null and self.scheduler != null and
            self.scheduled_handle != null;
    }

    fn finishScheduledAssumeValid(self: *Session) void {
        self.initialized = false;
        self.phase = .closed;
        self.scheduler = null;
        self.scheduled_handle = null;
    }
};

const CommitCandidateV1 = struct {
    permit: resource_bank.PublicationPermit,
    result: model.ResultEnvelopeV1,
    candidate: []u8,
    visible_output: []u8,
    state_before: model.PublicationStateV1,
    state_after: model.PublicationStateV1,
};

const ArmedScheduledStateV1 = enum {
    armed,
    committed,
    aborted,
};

pub const ArmedScheduledResultV1 = struct {
    session: *Session,
    intent: qos.ServiceIntentV1,
    candidate: CommitCandidateV1,
    state: ArmedScheduledStateV1 = .armed,
    committed_result: ?model.ResultEnvelopeV1 = null,
    service_event_sha256: Digest = [_]u8{0} ** 32,

    pub fn finalizer(self: *ArmedScheduledResultV1) qos.ServiceFinalizerV2 {
        return .{
            .publication_request_epoch = self.session.plan.request_epoch,
            .publication_session_id = @intFromPtr(self.session),
            .context = self,
            .finalize = finalize,
        };
    }

    pub fn resultV1(
        self: *const ArmedScheduledResultV1,
    ) Error!model.ResultEnvelopeV1 {
        if (self.state != .committed)
            return Error.InvalidState;
        return self.committed_result orelse Error.InvalidState;
    }

    /// Abort only the model publication permit and provisional buffers. The
    /// caller must separately consume the LaneWeave armed ticket with
    /// `abortArmedService`.
    pub fn abort(self: *ArmedScheduledResultV1) Error!void {
        if (self.state != .armed or self.session.phase != .armed)
            return Error.InvalidState;
        try self.session.rollbackV1(self.candidate.permit);
        self.state = .aborted;
    }

    fn finalize(
        context: *anyopaque,
        event: *const qos.EventV1,
    ) void {
        const self: *ArmedScheduledResultV1 =
            @ptrCast(@alignCast(context));
        if (self.state != .armed or self.session.phase != .armed or
            self.session.receipt_owner != .scheduler or
            event.remaining_after != 0 or
            !qos.eventMatchesServiceIntentV1(event.*, self.intent) or
            !self.session.armedCandidateValidV1(self.candidate))
            @panic("invalid armed stateless-model service finalization");
        self.session.finalizeCandidateAssumeValid(self.candidate);
        self.committed_result = self.candidate.result;
        self.service_event_sha256 = event.event_sha256;
        self.state = .committed;
    }
};

pub fn makeAdapterDescriptorV1(
    adapter_abi: u64,
    manifest: model.ArtifactManifestV1,
    operation: model.OperationIdV1,
    allowed_capabilities: u64,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    try model.validateArtifactManifestV1(manifest);
    if (adapter_abi == 0 or isZero(implementation_sha256))
        return Error.InvalidAdapter;
    var descriptor: AdapterDescriptorV1 = .{
        .adapter_abi = adapter_abi,
        .family = manifest.family,
        .operation = operation,
        .input_kind = manifest.input_kind,
        .output_kind = manifest.output_kind,
        .numerical_policy = manifest.numerical_policy,
        .max_batch_items = manifest.max_batch_items,
        .max_input_features = manifest.input_features,
        .max_output_dimensions = manifest.output_dimensions,
        .allowed_capabilities = allowed_capabilities,
        .implementation_sha256 = implementation_sha256,
        .adapter_sha256 = [_]u8{0} ** 32,
    };
    descriptor.adapter_sha256 = adapterDescriptorRootV1(descriptor);
    return descriptor;
}

pub fn validateAdapterForPlanV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    support_records: []const model.SupportRecordV1,
) Error!void {
    try model.validateArtifactManifestV1(manifest);
    try model.validateExecutionPlanV1(plan);
    try model.requireSupportV1(support_records, plan);
    const descriptor = adapter.descriptor;
    if (@intFromPtr(adapter.context) == 0 or descriptor.adapter_abi == 0 or
        isZero(descriptor.implementation_sha256) or
        !std.mem.eql(
            u8,
            &adapterDescriptorRootV1(descriptor),
            &descriptor.adapter_sha256,
        ) or
        descriptor.family != manifest.family or
        descriptor.operation != plan.operation or
        descriptor.input_kind != manifest.input_kind or
        descriptor.output_kind != manifest.output_kind or
        descriptor.numerical_policy != manifest.numerical_policy or
        plan.family != manifest.family or
        plan.input_kind != manifest.input_kind or
        plan.output_kind != manifest.output_kind or
        plan.numerical_policy != manifest.numerical_policy or
        plan.input_element_bytes != manifest.input_element_bytes or
        plan.output_element_bytes != manifest.output_element_bytes or
        plan.weight_bytes != manifest.weight_bytes or
        !std.mem.eql(
            u8,
            &plan.artifact_sha256,
            &manifest.artifact_sha256,
        ) or
        !std.mem.eql(u8, &plan.weights_sha256, &manifest.weights_sha256) or
        plan.batch_items > descriptor.max_batch_items or
        plan.input_features > descriptor.max_input_features or
        plan.output_dimensions > descriptor.max_output_dimensions or
        plan.required_capabilities & ~descriptor.allowed_capabilities != 0)
        return Error.InvalidAdapter;
}

pub fn adapterDescriptorRootV1(
    descriptor: AdapterDescriptorV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(descriptor_domain);
    inline for (.{
        descriptor.adapter_abi,
        @intFromEnum(descriptor.family),
        @intFromEnum(descriptor.operation),
        @intFromEnum(descriptor.input_kind),
        @intFromEnum(descriptor.output_kind),
        @intFromEnum(descriptor.numerical_policy),
        descriptor.max_batch_items,
        descriptor.max_input_features,
        descriptor.max_output_dimensions,
        descriptor.allowed_capabilities,
    }) |value|
        hashU64(&hash, value);
    hash.update(&descriptor.implementation_sha256);
    return hash.finalResult();
}

fn hashU64(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

const ScheduledTestContractV1 = struct {
    weights: [4]u8,
    input: [4]u8,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    publication_state: model.PublicationStateV1,
    support: [1]model.SupportRecordV1,

    fn init(request_epoch: u64) !ScheduledTestContractV1 {
        const weights = [_]u8{ 1, 2, 3, 4 };
        const input = [_]u8{ 5, 6, 7, 8 };
        const manifest = try model.makeArtifactManifestV1(
            .vision_understanding,
            0x5354_4154_454c_0001,
            .image_feature_u8,
            .embedding_i32,
            .exact_integer,
            1,
            4,
            1,
            1,
            4,
            1,
            &weights,
            model.sha256("scheduled stateless fixture metadata"),
            model.sha256("scheduled stateless fixture license"),
        );
        const plan = try model.makeExecutionPlanV1(
            manifest,
            .encode,
            .{
                .request_epoch = request_epoch,
                .generation = 1,
                .batch_items = 1,
                .publication_next_sequence = 0,
                .maximum_absolute_output = 1024,
                .claim = .{
                    .capsule_bytes = weights.len,
                    .activation_bytes = input.len,
                    .partial_bytes = 4,
                    .output_journal_bytes = 4,
                    .queue_slots = 1,
                },
                .media_object_sha256 = model.sha256(
                    "scheduled stateless media",
                ),
                .processor_state_sha256 = model.sha256(
                    "scheduled stateless processor state",
                ),
                .processor_bundle_sha256 = model.sha256(
                    "scheduled stateless processor bundle",
                ),
                .cache_bundle_sha256 = model.sha256(
                    "scheduled stateless cache bundle",
                ),
                .cache_payload_sha256 = model.sha256(
                    "scheduled stateless cache payload",
                ),
                .ownership_sha256 = model.sha256(
                    "scheduled stateless ownership",
                ),
                .challenge_sha256 = model.sha256(
                    "scheduled stateless challenge",
                ),
                .previous_plan_sha256 = model.sha256(
                    "scheduled stateless previous plan",
                ),
                .input_schema_sha256 = model.sha256(
                    "scheduled stateless input schema",
                ),
                .output_schema_sha256 = model.sha256(
                    "scheduled stateless output schema",
                ),
                .scratch_bytes = 4,
            },
        );
        return .{
            .weights = weights,
            .input = input,
            .manifest = manifest,
            .plan = plan,
            .publication_state = try model.initializePublicationStateV1(
                request_epoch,
                manifest.artifact_sha256,
            ),
            .support = .{.{
                .family = manifest.family,
                .operation = plan.operation,
                .input_kind = manifest.input_kind,
                .output_kind = manifest.output_kind,
                .numerical_policy = manifest.numerical_policy,
                .max_batch_items = manifest.max_batch_items,
                .max_input_features = manifest.input_features,
                .max_output_dimensions = manifest.output_dimensions,
                .allowed_capabilities = 0,
            }},
        };
    }
};

const ScheduledTestBackendV1 = struct {
    execute_calls: u64 = 0,
    validate_calls: u64 = 0,
    expected_output: i32 = 6,
};

fn scheduledTestExecuteV1(
    context_opaque: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    candidate: []u8,
) anyerror!void {
    const context: *ScheduledTestBackendV1 =
        @ptrCast(@alignCast(context_opaque));
    if (plan.output_bytes != 4 or weights.len != 4 or input.len != 4 or
        candidate.len != 4)
        return error.InvalidScheduledTestInput;
    context.execute_calls += 1;
    std.mem.writeInt(i32, candidate[0..4], context.expected_output, .little);
}

fn scheduledTestValidateV1(
    context_opaque: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
) anyerror!void {
    const context: *ScheduledTestBackendV1 =
        @ptrCast(@alignCast(context_opaque));
    context.validate_calls += 1;
    if (plan.output_bytes != 4 or candidate.len != 4 or
        std.mem.readInt(i32, candidate[0..4], .little) !=
            context.expected_output)
        return error.InvalidScheduledTestCandidate;
}

fn scheduledTestAdapterV1(
    context: *ScheduledTestBackendV1,
    manifest: model.ArtifactManifestV1,
) !AdapterV1 {
    return .{
        .context = context,
        .descriptor = try makeAdapterDescriptorV1(
            0x5354_4154_4144_0001,
            manifest,
            .encode,
            0,
            model.sha256("scheduled stateless test backend"),
        ),
        .execute_fn = scheduledTestExecuteV1,
        .validate_candidate_fn = scheduledTestValidateV1,
    };
}

fn scheduledTestAdmissionV1(
    decision: qos.AdmissionDecision,
) !qos.Admission {
    return switch (decision) {
        .admitted => |admission| admission,
        .rejected => error.UnexpectedScheduledTestRejection,
    };
}

fn scheduledTestSpecV1(
    contract: ScheduledTestContractV1,
    owner_key: u64,
    work_quanta: u64,
) qos.RequestSpec {
    return .{
        .tenant_key = 71,
        .request_key = contract.plan.request_epoch,
        .request_generation = contract.plan.generation,
        .resource_owner_key = owner_key,
        .weight = 1,
        .work_quanta = work_quanta,
        .deadline_tick = 0,
        .claim = contract.plan.claim,
    };
}

test "scheduled stateless result adopts one receipt and finalizes atomically" {
    var contract = try ScheduledTestContractV1.init(0x5150_0001);
    var backend: ScheduledTestBackendV1 = .{};
    const adapter = try scheduledTestAdapterV1(
        &backend,
        contract.manifest,
    );
    var bank_slots = [_]resource_bank.Slot{.{}} ** 4;
    var scheduler_slots = [_]qos.Slot{.{}} ** 4;
    var projection = [_]qos.ProjectionSlot{.{}} ** 4;
    var bank = try resource_bank.Bank.init(
        &bank_slots,
        .{ .host_bytes = 1024, .queue_slots = 4 },
        0x4241_4e4b_0001,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &scheduler_slots,
            .projection = &projection,
        },
        .{
            .scheduler_epoch = 0x5343_4845_4401,
            .challenge = model.sha256("scheduled stateless scheduler"),
            .max_weight = 4,
            .max_projection_quanta = 64,
            .max_projection_operations = 4096,
        },
    );
    const admission = try scheduledTestAdmissionV1(
        try scheduler.admit(scheduledTestSpecV1(contract, 9001, 2)),
    );
    const admitted_snapshot = try bank.snapshot();
    try std.testing.expectEqualDeep(
        contract.plan.claim,
        admitted_snapshot.used,
    );

    var session: Session = .{};
    try session.initScheduledV1(
        &scheduler,
        admission,
        &contract.publication_state,
        contract.manifest,
        contract.plan,
        adapter,
        &contract.support,
    );
    const bound_snapshot = try bank.snapshot();
    try std.testing.expectEqualDeep(
        admitted_snapshot.used,
        bound_snapshot.used,
    );
    try std.testing.expectEqual(
        admitted_snapshot.successful_commits,
        bound_snapshot.successful_commits,
    );
    try std.testing.expectEqualDeep(
        admission.event.resource_receipt,
        session.receipt,
    );
    try std.testing.expectError(
        Error.InvalidState,
        session.closeAndRelease(),
    );

    const first_permit = try scheduler.prepareService();
    try std.testing.expectEqual(@as(u64, 2), first_permit.remaining_before);
    const first_event = try scheduler.commitService(first_permit);
    try std.testing.expectEqual(qos.EventKind.service, first_event.kind);
    try std.testing.expectEqual(@as(u64, 1), first_event.remaining_after);
    try std.testing.expectEqual(
        @as(u64, 0),
        contract.publication_state.visible_results,
    );
    try std.testing.expectEqual(@as(u64, 0), backend.execute_calls);

    const final_permit = try scheduler.prepareService();
    try std.testing.expectEqual(@as(u64, 1), final_permit.remaining_before);
    var candidate = [_]u8{0xaa} ** 4;
    var visible_output = [_]u8{0xbb} ** 4;
    const source_mapping = model.sha256(
        "scheduled stateless source mapping",
    );
    const prepared_result = try session.prepareV1(
        &contract.weights,
        &contract.input,
        source_mapping,
        &candidate,
        &visible_output,
    );
    try std.testing.expect(std.mem.allEqual(u8, &visible_output, 0));
    try std.testing.expectEqual(@as(u64, 1), backend.execute_calls);
    try std.testing.expectError(Error.InvalidState, session.commitV1());
    try std.testing.expectEqual(Phase.prepared, session.phase);

    const armed_service = try scheduler.armServiceCommit(final_permit);
    var armed_result = try session.armServiceV1(armed_service.intent);
    try std.testing.expectEqual(Phase.armed, session.phase);
    try std.testing.expectEqual(
        @as(u64, 0),
        contract.publication_state.visible_results,
    );
    const final_event = try scheduler.commitArmedServiceV2(
        armed_service.ticket,
        armed_result.finalizer(),
    );
    const committed_result = try armed_result.resultV1();
    try std.testing.expectEqualDeep(prepared_result, committed_result);
    try std.testing.expectEqualSlices(
        u8,
        &final_event.event_sha256,
        &armed_result.service_event_sha256,
    );
    try std.testing.expectEqual(@as(u64, 0), final_event.remaining_after);
    try std.testing.expectEqual(Phase.published, session.phase);
    try std.testing.expectEqual(
        @as(u64, 1),
        contract.publication_state.visible_results,
    );
    try std.testing.expectEqual(@as(i32, 6), std.mem.readInt(
        i32,
        &visible_output,
        .little,
    ));
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expectEqual(@as(u64, 2), backend.validate_calls);
    try std.testing.expectEqual(
        admission.event.resource_receipt.bank_epoch,
        committed_result.resource_bank_epoch,
    );
    try std.testing.expectEqual(
        admission.event.resource_receipt.slot_index,
        committed_result.resource_slot_index,
    );
    try std.testing.expectEqual(
        admission.event.resource_receipt.generation,
        committed_result.resource_generation,
    );
    try std.testing.expectEqual(
        admission.event.resource_receipt.owner_key,
        committed_result.resource_owner_key,
    );
    try std.testing.expectEqualDeep(
        admission.event.resource_receipt.claim,
        committed_result.claim,
    );
    try std.testing.expectEqual(
        admission.event.resource_receipt.integrity,
        committed_result.resource_integrity,
    );

    const retire_event = try session.retireScheduledV1();
    try std.testing.expectEqual(qos.EventKind.retire, retire_event.kind);
    _ = try scheduler.close();
    const final_snapshot = try bank.snapshot();
    try std.testing.expect(final_snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), final_snapshot.committed_receipts);
}

test "scheduled stateless cancellation closes without backend execution" {
    var contract = try ScheduledTestContractV1.init(0x5150_0002);
    var backend: ScheduledTestBackendV1 = .{};
    const adapter = try scheduledTestAdapterV1(
        &backend,
        contract.manifest,
    );
    var bank_slots = [_]resource_bank.Slot{.{}} ** 2;
    var scheduler_slots = [_]qos.Slot{.{}} ** 2;
    var projection = [_]qos.ProjectionSlot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &bank_slots,
        .{ .host_bytes = 1024, .queue_slots = 2 },
        0x4241_4e4b_0002,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &scheduler_slots,
            .projection = &projection,
        },
        .{
            .scheduler_epoch = 0x5343_4845_4402,
            .challenge = model.sha256("scheduled stateless cancellation"),
            .max_weight = 2,
            .max_projection_quanta = 64,
            .max_projection_operations = 4096,
        },
    );
    const admission = try scheduledTestAdmissionV1(
        try scheduler.admit(scheduledTestSpecV1(contract, 9002, 3)),
    );
    var session: Session = .{};
    try session.initScheduledV1(
        &scheduler,
        admission,
        &contract.publication_state,
        contract.manifest,
        contract.plan,
        adapter,
        &contract.support,
    );
    const cancel_event = try session.cancelScheduledV1();
    try std.testing.expectEqual(qos.EventKind.cancel, cancel_event.kind);
    try std.testing.expectEqual(Phase.closed, session.phase);
    try std.testing.expectEqual(@as(u64, 0), backend.execute_calls);
    try std.testing.expectEqual(
        @as(u64, 0),
        contract.publication_state.visible_results,
    );
    try std.testing.expectError(
        Error.InvalidState,
        session.cancelScheduledV1(),
    );
    _ = try scheduler.close();
    const snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
}

test "scheduled stateless rejects claim drift and moved session address" {
    var contract = try ScheduledTestContractV1.init(0x5150_0004);
    var backend: ScheduledTestBackendV1 = .{};
    const adapter = try scheduledTestAdapterV1(
        &backend,
        contract.manifest,
    );
    var bank_slots = [_]resource_bank.Slot{.{}} ** 2;
    var scheduler_slots = [_]qos.Slot{.{}} ** 2;
    var projection = [_]qos.ProjectionSlot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &bank_slots,
        .{ .host_bytes = 1024, .queue_slots = 2 },
        0x4241_4e4b_0004,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &scheduler_slots,
            .projection = &projection,
        },
        .{
            .scheduler_epoch = 0x5343_4845_4404,
            .challenge = model.sha256("scheduled stateless binding"),
            .max_weight = 2,
            .max_projection_quanta = 64,
            .max_projection_operations = 4096,
        },
    );

    var drift_spec = scheduledTestSpecV1(contract, 9004, 1);
    drift_spec.claim.activation_bytes += 1;
    const drift_admission = try scheduledTestAdmissionV1(
        try scheduler.admit(drift_spec),
    );
    const publication_before = contract.publication_state;
    const drift_snapshot = try bank.snapshot();
    var rejected_session: Session = .{};
    try std.testing.expectError(
        Error.InvalidConfiguration,
        rejected_session.initScheduledV1(
            &scheduler,
            drift_admission,
            &contract.publication_state,
            contract.manifest,
            contract.plan,
            adapter,
            &contract.support,
        ),
    );
    try std.testing.expect(!rejected_session.initialized);
    try std.testing.expectEqualDeep(
        publication_before,
        contract.publication_state,
    );
    try std.testing.expectEqualDeep(drift_snapshot, try bank.snapshot());
    _ = try scheduler.cancel(drift_admission.handle);

    const admission = try scheduledTestAdmissionV1(
        try scheduler.admit(scheduledTestSpecV1(contract, 9005, 1)),
    );
    var session: Session = .{};
    try session.initScheduledV1(
        &scheduler,
        admission,
        &contract.publication_state,
        contract.manifest,
        contract.plan,
        adapter,
        &contract.support,
    );
    const bound_snapshot = try bank.snapshot();
    var moved = session;
    var candidate = [_]u8{0xaa} ** 4;
    var visible_output = [_]u8{0xbb} ** 4;
    try std.testing.expectError(
        Error.ResourceReceiptInvalid,
        moved.prepareV1(
            &contract.weights,
            &contract.input,
            model.sha256("scheduled moved-session mapping"),
            &candidate,
            &visible_output,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), backend.execute_calls);
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &visible_output, 0));
    try std.testing.expectEqualDeep(bound_snapshot, try bank.snapshot());
    try std.testing.expectEqualDeep(
        publication_before,
        contract.publication_state,
    );

    _ = try session.cancelScheduledV1();
    _ = try scheduler.close();
    const snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
}

test "scheduled stateless rejects nonfinal intent and scrubs candidate drift" {
    var contract = try ScheduledTestContractV1.init(0x5150_0003);
    var backend: ScheduledTestBackendV1 = .{};
    const adapter = try scheduledTestAdapterV1(
        &backend,
        contract.manifest,
    );
    var bank_slots = [_]resource_bank.Slot{.{}} ** 2;
    var scheduler_slots = [_]qos.Slot{.{}} ** 2;
    var projection = [_]qos.ProjectionSlot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &bank_slots,
        .{ .host_bytes = 1024, .queue_slots = 2 },
        0x4241_4e4b_0003,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &scheduler_slots,
            .projection = &projection,
        },
        .{
            .scheduler_epoch = 0x5343_4845_4403,
            .challenge = model.sha256("scheduled stateless failure"),
            .max_weight = 2,
            .max_projection_quanta = 64,
            .max_projection_operations = 4096,
        },
    );
    const admission = try scheduledTestAdmissionV1(
        try scheduler.admit(scheduledTestSpecV1(contract, 9003, 2)),
    );
    var session: Session = .{};
    try session.initScheduledV1(
        &scheduler,
        admission,
        &contract.publication_state,
        contract.manifest,
        contract.plan,
        adapter,
        &contract.support,
    );
    var candidate = [_]u8{0xaa} ** 4;
    var visible_output = [_]u8{0xbb} ** 4;
    const source_mapping = model.sha256(
        "scheduled stateless failure mapping",
    );

    const nonfinal_permit = try scheduler.prepareService();
    _ = try session.prepareV1(
        &contract.weights,
        &contract.input,
        source_mapping,
        &candidate,
        &visible_output,
    );
    const nonfinal_armed = try scheduler.armServiceCommit(nonfinal_permit);
    try std.testing.expectEqual(
        @as(u64, 2),
        nonfinal_armed.intent.remaining_before,
    );
    try std.testing.expectError(
        Error.InvalidConfiguration,
        session.armServiceV1(nonfinal_armed.intent),
    );
    try scheduler.abortArmedService(nonfinal_armed.ticket);
    try session.abortV1();
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &visible_output, 0));

    const retry_nonfinal = try scheduler.prepareService();
    _ = try scheduler.commitService(retry_nonfinal);
    const final_permit = try scheduler.prepareService();
    _ = try session.prepareV1(
        &contract.weights,
        &contract.input,
        source_mapping,
        &candidate,
        &visible_output,
    );
    const final_armed = try scheduler.armServiceCommit(final_permit);
    candidate[0] ^= 1;
    backend.expected_output = 7;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.armServiceV1(final_armed.intent),
    );
    try scheduler.abortArmedService(final_armed.ticket);
    try std.testing.expectEqual(Phase.idle, session.phase);
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &visible_output, 0));
    try std.testing.expectEqual(
        @as(u64, 0),
        contract.publication_state.visible_results,
    );

    const armed_drift_permit = try scheduler.prepareService();
    _ = try session.prepareV1(
        &contract.weights,
        &contract.input,
        source_mapping,
        &candidate,
        &visible_output,
    );
    const armed_drift_service =
        try scheduler.armServiceCommit(armed_drift_permit);
    var armed_drift = try session.armServiceV1(
        armed_drift_service.intent,
    );
    candidate[0] ^= 1;
    try std.testing.expect(
        !session.armedCandidateValidV1(armed_drift.candidate),
    );
    try armed_drift.abort();
    try scheduler.abortArmedService(armed_drift_service.ticket);
    try std.testing.expectEqual(Phase.idle, session.phase);
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &visible_output, 0));
    try std.testing.expectEqual(
        @as(u64, 0),
        contract.publication_state.visible_results,
    );

    const cancel_event = try session.cancelScheduledV1();
    try std.testing.expectEqual(qos.EventKind.cancel, cancel_event.kind);
    _ = try scheduler.close();
    const snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), snapshot.committed_receipts);
}
