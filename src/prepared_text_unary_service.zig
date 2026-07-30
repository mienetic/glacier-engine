//! Bounded, transport-neutral unary serving for one prepared text model.
//!
//! The service owns request lifecycle composition, while the loaded model,
//! Scheduler, ResourceBank, and fixed storage remain caller-owned. Accepted
//! output stays private until the terminal result is sealed and the exact
//! Scheduler/Bank ownership has retired. The service deliberately provides no
//! network transport, background thread, streaming output, or durable replay.

const std = @import("std");
const core = @import("core");
const loader = @import("loader.zig");
const package_manifest = @import("model/package_manifest.zig");
const package_producer = @import("model/package_producer.zig");
const publication = @import("lane_publication_txn.zig");
const raw_input = @import("prepared_text_raw_input.zig");
const prepared = @import("prepared_text_session.zig");
const tokenizer = @import("tokenizer.zig");

const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;

pub const Digest = [32]u8;
pub const maximum_prompt_bytes: u32 = 4096;
pub const maximum_output_tokens: usize = 64;
pub const no_slot: u32 = std.math.maxInt(u32);
pub const zero_digest: Digest = [_]u8{0} ** 32;

const binding_domain =
    "glacier-prepared-text-unary-model-binding-v1\x00";
const intent_domain =
    "glacier-prepared-text-unary-intent-v1\x00";
const handle_domain =
    "glacier-prepared-text-unary-handle-v1\x00";
const response_domain =
    "glacier-prepared-text-unary-response-v1\x00";
const cancellation_domain =
    "glacier-prepared-text-unary-cancellation-v1\x00";
const failure_domain =
    "glacier-prepared-text-unary-failure-v1\x00";

pub const Error = error{
    InvalidConfiguration,
    InvalidModelBinding,
    InvalidRequest,
    RequestTooLarge,
    OutOfMemory,
    SequenceExhausted,
    StaleHandle,
    ResponseNotReady,
    NoResponse,
    ActiveRequests,
    ServiceClosed,
    InvalidState,
    StateDrift,
    RuntimeUnavailable,
    RecoveryRequired,
    FailStopRequired,
};

pub const ModelBindingV1 = struct {
    model: *const loader.LoadedModel,
    bundle: package_manifest.AdmissionBundleV2,
    tokenizer_manifest: tokenizer.Utf8ByteManifestV1,
    artifact_license_bytes: u64,
    artifact_license_sha256: Digest,
    binding_sha256: Digest,
};

pub const ConfigV1 = struct {
    service_epoch: u64,
    first_request_identity: u64 = 1,
    /// Zero derives the Lane request key from the request identity.
    first_scheduling_request_key: u64 = 0,
    /// Zero derives the Lane request generation from the request identity.
    first_scheduling_request_generation: u64 = 0,
    /// Zero derives the ResourceBank owner key from the request identity.
    first_resource_owner_key: u64 = 0,
    /// Zero uses `service_epoch`; an explicit value preserves a retained sink
    /// identity when a caller migrates an existing process-local route.
    private_sink_epoch: u64 = 0,
    maximum_request_prompt_bytes: u32 = maximum_prompt_bytes,
    maximum_request_output_tokens: u16 = maximum_output_tokens,
};

pub const RequestV1 = struct {
    /// LaneWeave admits at most one active request for one tenant key.
    tenant_key: u64,
    idempotency_key_sha256: Digest,
    /// Borrowed only for the duration of `admitV1`.
    prompt_utf8: []const u8,
    max_new_tokens: u16,
    /// Absolute logical Scheduler tick. Zero disables the logical deadline.
    deadline_tick: u64 = 0,
};

pub const IntentV1 = struct {
    service_epoch: u64 = 0,
    model_binding_sha256: Digest = zero_digest,
    scheduler_epoch: u64 = 0,
    coordinator_id: u64 = 0,
    bank_epoch: u64 = 0,
    challenge_sha256: Digest = zero_digest,
    tenant_key: u64 = 0,
    idempotency_key_sha256: Digest = zero_digest,
    tokenizer_domain_sha256: Digest = zero_digest,
    tokenizer_config_sha256: Digest = zero_digest,
    raw_text_sha256: Digest = zero_digest,
    raw_text_bytes: u64 = 0,
    max_new_tokens: u16 = 0,
    deadline_tick: u64 = 0,
    intent_sha256: Digest = zero_digest,
};

pub const HandleV1 = struct {
    service_epoch: u64 = 0,
    record_index: u32 = no_slot,
    record_generation: u64 = 0,
    intent_sha256: Digest = zero_digest,
    handle_sha256: Digest = zero_digest,
};

pub const AdmissionReceiptV1 = struct {
    handle: HandleV1,
    intent: IntentV1,
    request_epoch: u64,
    scheduling: prepared.SchedulingV1,
    prompt_receipt: tokenizer.Utf8BytePromptReceiptV1,
    raw_input_binding: raw_input.BindingV1,
    local_plan_sha256: Digest,
    bound_plan_sha256: Digest,
    start_event: lane.EventV1,
};

pub const ResponseV1 = struct {
    handle: HandleV1,
    intent: IntentV1,
    admission: AdmissionReceiptV1,
    terminal: prepared.TerminalResultEvidenceV1,
    retire_event: lane.EventV1,
    output_count: u16,
    output_tokens: [maximum_output_tokens]u32,
    private_transcript_sha256: Digest,
    private_prepare_calls: u16,
    private_commit_calls: u16,
    private_abort_calls: u16,
    response_sha256: Digest,
};

pub const CancellationV1 = struct {
    handle: HandleV1,
    intent: IntentV1,
    admission: AdmissionReceiptV1,
    cancel_event: lane.EventV1,
    private_committed_tokens: u16,
    private_transcript_sha256: Digest,
    externally_visible_tokens: u16 = 0,
    cancellation_sha256: Digest,
};

pub const FailureReasonV1 = enum(u8) {
    execution_failed,
};

pub const FailureV1 = struct {
    handle: HandleV1,
    intent: IntentV1,
    admission: AdmissionReceiptV1,
    reason: FailureReasonV1,
    cancel_event: lane.EventV1,
    private_committed_tokens: u16,
    private_transcript_sha256: Digest,
    externally_visible_tokens: u16 = 0,
    failure_sha256: Digest,
};

pub const ServiceStateV1 = enum(u8) {
    empty,
    open,
    fail_stop,
    closed,
};

pub const RecordStateV1 = enum(u8) {
    empty,
    active,
    completed,
    cancelled,
    failed,
};

pub const ActivePhaseV1 = enum(u8) {
    empty,
    start_adoption_recovery,
    running,
    publication_fail_stop,
};

pub const CloseReasonV1 = enum(u8) {
    none,
    caller_cancel,
    execution_failed,
};

pub const ExistingStateV1 = enum(u8) {
    active,
    recovery_required,
    completed,
    cancelled,
    failed,
};

pub const ExistingV1 = struct {
    handle: HandleV1,
    state: ExistingStateV1,
};

pub const ConflictV1 = struct {
    existing_handle: HandleV1,
    existing_intent_sha256: Digest,
    supplied_intent_sha256: Digest,
};

pub const AdmissionRejectionV1 = union(enum) {
    service_capacity,
    scheduler: lane.EventV1,
};

pub const AdmissionDecisionV1 = union(enum) {
    accepted: AdmissionReceiptV1,
    existing: ExistingV1,
    rejected: AdmissionRejectionV1,
    conflict: ConflictV1,
    recovery_required: HandleV1,
};

pub const ProgressV1 = struct {
    handle: HandleV1,
    committed_tokens: u16,
};

pub const CompletionNoticeV1 = struct {
    handle: HandleV1,
    response_sha256: Digest,
};

pub const RecoveryNoticeV1 = struct {
    handle: HandleV1,
    phase: ActivePhaseV1,
};

pub const DriveDecisionV1 = union(enum) {
    idle,
    progressed: ProgressV1,
    completed: CompletionNoticeV1,
    request_failed: HandleV1,
    recovery_required: RecoveryNoticeV1,
};

pub const CancelDecisionV1 = union(enum) {
    cancelled: CancellationV1,
    already_cancelled: CancellationV1,
    already_terminal: ExistingV1,
    start_rolled_back: lane.EventV1,
    recovery_required: RecoveryNoticeV1,
};

pub const RecoveryDecisionV1 = union(enum) {
    start_rolled_back: lane.EventV1,
    still_required: RecoveryNoticeV1,
};

pub const ActiveStatusV1 = struct {
    handle: HandleV1,
    phase: ActivePhaseV1,
    committed_tokens: u16,
};

pub const StatusV1 = union(enum) {
    active: ActiveStatusV1,
    completed: CompletionNoticeV1,
    cancelled: CancellationV1,
    failed: FailureV1,
};

pub const SnapshotV1 = struct {
    state: ServiceStateV1,
    service_epoch: u64,
    next_request_identity: u64,
    active_requests: u32,
    terminal_records: u32,
    completed_records: u32,
    cancelled_records: u32,
    failed_records: u32,
    recovery_required: u32,
    scheduler: ?lane.SnapshotV1,
    bank: ?resource_bank.Snapshot,
};

pub const CloseReceiptV1 = struct {
    scheduler_event: lane.EventV1,
    bank_snapshot: resource_bank.Snapshot,
    terminal_records: u32,
};

pub const RecordSlotV1 = struct {
    generation: u64 = 0,
    state: RecordStateV1 = .empty,
    intent: IntentV1 = .{},
    handle: HandleV1 = .{},
    active_index: u32 = no_slot,
    active_generation: u64 = 0,
    response: ?ResponseV1 = null,
    cancellation: ?CancellationV1 = null,
    failure: ?FailureV1 = null,
};

/// Caller-owned fixed storage used only by the service's private publication
/// sink. Treat its fields as opaque after `ServiceV1.init`.
pub const PrivateSinkStorageV1 = struct {
    sink_epoch: u64 = 0,
    invalid: bool = false,
    prepared: bool = false,
    prepared_token: u32 = 0,
    prepared_proposal_sha256: Digest = zero_digest,
    prepared_reservation_id: u64 = 0,
    committed_count: u16 = 0,
    committed_tokens: [maximum_output_tokens]u32 =
        [_]u32{0} ** maximum_output_tokens,
    last_transcript_sha256: Digest = zero_digest,
    prepare_calls: u16 = 0,
    commit_calls: u16 = 0,
    abort_calls: u16 = 0,

    fn interface(self: *PrivateSinkStorageV1) publication.SinkV1 {
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
        acknowledgement: *publication.PrepareAckV1,
    ) publication.SinkPrepareError!void {
        const self: *PrivateSinkStorageV1 =
            @ptrCast(@alignCast(raw));
        if (self.invalid)
            return error.InvalidEvidence;
        if (self.sink_epoch == 0 or self.prepared or
            self.committed_count >= maximum_output_tokens or
            proposal.transaction_sequence != self.committed_count)
        {
            self.invalid = true;
            return error.CapacityExceeded;
        }
        if (!publication.proposalValidV1(proposal.*)) {
            self.invalid = true;
            return error.InvalidEvidence;
        }

        const proposal_sha256 =
            publication.proposalSha256(proposal.*);
        const reservation_id =
            @as(u64, self.committed_count) + 1;
        self.prepared = true;
        self.prepared_token = proposal.transition.token_id;
        self.prepared_proposal_sha256 = proposal_sha256;
        self.prepared_reservation_id = reservation_id;
        self.prepare_calls += 1;
        acknowledgement.* = .{
            .proposal_sha256 = proposal_sha256,
            .sink_epoch = self.sink_epoch,
            .reservation_id = reservation_id,
        };
    }

    fn commit(
        raw: *anyopaque,
        receipt: *const publication.CommitReceiptV1,
    ) void {
        const self: *PrivateSinkStorageV1 =
            @ptrCast(@alignCast(raw));
        if (!self.prepared or
            !publication.commitReceiptValidV1(receipt.*) or
            !digestEqual(
                self.prepared_proposal_sha256,
                receipt.proposal_sha256,
            ) or
            receipt.prepare_ack.sink_epoch != self.sink_epoch or
            receipt.prepare_ack.reservation_id !=
                self.prepared_reservation_id or
            receipt.proposal.transition.token_id !=
                self.prepared_token or
            self.committed_count >= maximum_output_tokens)
        {
            self.invalid = true;
            self.clearPrepared();
            return;
        }

        const index: usize = self.committed_count;
        self.committed_tokens[index] = self.prepared_token;
        self.committed_count += 1;
        self.commit_calls += 1;
        self.last_transcript_sha256 =
            receipt.transcript_sha256;
        self.clearPrepared();
    }

    fn abort(
        raw: *anyopaque,
        proposal: *const publication.ProposalV1,
        acknowledgement: *const publication.PrepareAckV1,
    ) void {
        const self: *PrivateSinkStorageV1 =
            @ptrCast(@alignCast(raw));
        if (!self.prepared or
            !digestEqual(
                self.prepared_proposal_sha256,
                acknowledgement.proposal_sha256,
            ) or
            acknowledgement.sink_epoch != self.sink_epoch or
            acknowledgement.reservation_id !=
                self.prepared_reservation_id or
            !digestEqual(
                self.prepared_proposal_sha256,
                publication.proposalSha256(proposal.*),
            ))
        {
            self.invalid = true;
            self.clearPrepared();
            return;
        }
        self.abort_calls += 1;
        self.clearPrepared();
    }

    fn clearPrepared(self: *PrivateSinkStorageV1) void {
        self.prepared = false;
        self.prepared_token = 0;
        self.prepared_proposal_sha256 = zero_digest;
        self.prepared_reservation_id = 0;
    }
};

/// Address-stable caller-owned storage for one accepted request. Treat every
/// field as private after `ServiceV1.init`.
pub const ActiveSlotV1 = struct {
    generation: u64 = 0,
    record_index: u32 = no_slot,
    phase: ActivePhaseV1 = .empty,
    close_reason: CloseReasonV1 = .none,
    session: prepared.SessionV3 = .{},
    sink: PrivateSinkStorageV1 = .{},
    admission: ?AdmissionReceiptV1 = null,
    sealed: ?prepared.TerminalResultEvidenceV1 = null,
    provisional_output_count: u16 = 0,
    provisional_output: [maximum_output_tokens]u32 =
        [_]u32{0} ** maximum_output_tokens,
};

const TerminalCloseV1 = union(enum) {
    cancelled: CancellationV1,
    failed: FailureV1,
};

pub fn bindModelV1(
    model: *const loader.LoadedModel,
    bundle: package_manifest.AdmissionBundleV2,
    artifact_license_bytes: u64,
    artifact_license_sha256: Digest,
) Error!ModelBindingV1 {
    if (artifact_license_bytes == 0 or
        isZeroDigest(artifact_license_sha256) or
        bundle.package.license_bytes != artifact_license_bytes or
        !digestEqual(
            bundle.package.license_sha256,
            artifact_license_sha256,
        ))
        return Error.InvalidModelBinding;

    const manifest =
        package_producer.validateSupportedPackageV1(
            bundle.package,
        ) catch return Error.InvalidModelBinding;
    const representation =
        package_producer.preparedRepresentationForModelV1(
            bundle.package,
            model,
        ) catch return Error.InvalidModelBinding;
    if (!std.meta.eql(representation, bundle.representation))
        return Error.InvalidModelBinding;

    var result: ModelBindingV1 = .{
        .model = model,
        .bundle = bundle,
        .tokenizer_manifest = manifest,
        .artifact_license_bytes = artifact_license_bytes,
        .artifact_license_sha256 = artifact_license_sha256,
        .binding_sha256 = undefined,
    };
    result.binding_sha256 = modelBindingSha256V1(result);
    return result;
}

pub fn modelBindingValidV1(binding: ModelBindingV1) bool {
    const expected = bindModelV1(
        binding.model,
        binding.bundle,
        binding.artifact_license_bytes,
        binding.artifact_license_sha256,
    ) catch return false;
    return std.meta.eql(expected, binding);
}

pub fn intentValidV1(intent: IntentV1) bool {
    if (intent.service_epoch == 0 or
        isZeroDigest(intent.model_binding_sha256) or
        intent.scheduler_epoch == 0 or
        intent.coordinator_id == 0 or
        intent.bank_epoch == 0 or
        isZeroDigest(intent.challenge_sha256) or
        intent.tenant_key == 0 or
        isZeroDigest(intent.idempotency_key_sha256) or
        isZeroDigest(intent.tokenizer_domain_sha256) or
        isZeroDigest(intent.tokenizer_config_sha256) or
        isZeroDigest(intent.raw_text_sha256) or
        intent.raw_text_bytes == 0 or
        intent.max_new_tokens == 0)
        return false;
    return digestEqual(intent.intent_sha256, intentSha256V1(intent));
}

pub fn handleValidV1(handle: HandleV1) bool {
    if (handle.service_epoch == 0 or
        handle.record_index == no_slot or
        handle.record_generation == 0 or
        isZeroDigest(handle.intent_sha256))
        return false;
    return digestEqual(handle.handle_sha256, handleSha256V1(handle));
}

pub const ServiceV1 = struct {
    mutex: std.Thread.Mutex = .{},
    state: ServiceStateV1 = .empty,
    allocator: std.mem.Allocator = undefined,
    binding: ModelBindingV1 = undefined,
    scheduler: *lane.Scheduler = undefined,
    bank: *resource_bank.Bank = undefined,
    scheduler_identity: lane.IdentityV1 = undefined,
    config: ConfigV1 = undefined,
    active_slots: []ActiveSlotV1 = &.{},
    records: []RecordSlotV1 = &.{},
    next_request_identity: u64 = 0,
    next_record_generation: u64 = 1,
    next_active_generation: u64 = 1,
    self_address: usize = 0,
    active_storage_address: usize = 0,
    record_storage_address: usize = 0,

    /// Initialize one service around a fresh, drained, exclusively owned
    /// Scheduler/Bank pair. The Service and both storage slices become
    /// address-stable at this call and remain so through successful close.
    pub fn init(
        self: *ServiceV1,
        allocator: std.mem.Allocator,
        binding: ModelBindingV1,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
        active_storage: []ActiveSlotV1,
        record_storage: []RecordSlotV1,
        config: ConfigV1,
    ) Error!void {
        if (self.state != .empty or
            !modelBindingValidV1(binding) or
            config.service_epoch == 0 or
            config.first_request_identity == 0 or
            config.first_request_identity ==
                std.math.maxInt(u64) or
            config.first_scheduling_request_key ==
                std.math.maxInt(u64) or
            config.first_scheduling_request_generation ==
                std.math.maxInt(u64) or
            config.first_resource_owner_key ==
                std.math.maxInt(u64) or
            config.private_sink_epoch ==
                std.math.maxInt(u64) or
            config.maximum_request_prompt_bytes == 0 or
            config.maximum_request_prompt_bytes >
                maximum_prompt_bytes or
            config.maximum_request_prompt_bytes >
                binding.tokenizer_manifest.max_input_bytes or
            config.maximum_request_output_tokens == 0 or
            config.maximum_request_output_tokens >
                maximum_output_tokens or
            active_storage.len == 0 or
            record_storage.len < active_storage.len or
            active_storage.len > std.math.maxInt(u32) or
            record_storage.len > std.math.maxInt(u32))
            return Error.InvalidConfiguration;

        const active_bytes = std.math.mul(
            usize,
            active_storage.len,
            @sizeOf(ActiveSlotV1),
        ) catch return Error.InvalidConfiguration;
        const record_bytes = std.math.mul(
            usize,
            record_storage.len,
            @sizeOf(RecordSlotV1),
        ) catch return Error.InvalidConfiguration;
        const active_address = @intFromPtr(active_storage.ptr);
        const record_address = @intFromPtr(record_storage.ptr);
        if (rangesOverlap(
            active_address,
            active_bytes,
            record_address,
            record_bytes,
        ) or rangesOverlap(
            active_address,
            active_bytes,
            @intFromPtr(self),
            @sizeOf(ServiceV1),
        ) or rangesOverlap(
            record_address,
            record_bytes,
            @intFromPtr(self),
            @sizeOf(ServiceV1),
        ))
            return Error.InvalidConfiguration;

        const identity = scheduler.identityV1() catch
            return Error.RuntimeUnavailable;
        const scheduler_snapshot = scheduler.snapshot() catch
            return Error.RuntimeUnavailable;
        const bank_snapshot = bank.snapshot() catch
            return Error.RuntimeUnavailable;
        if (scheduler.bank != bank or
            scheduler.slots.len != bank.slots.len or
            active_storage.len > scheduler.slots.len or
            identity.coordinator_address != @intFromPtr(scheduler) or
            identity.bank_epoch != bank_snapshot.bank_epoch or
            scheduler_snapshot.scheduler_epoch !=
                identity.scheduler_epoch or
            scheduler_snapshot.active != 0 or
            scheduler_snapshot.finished != 0 or
            !scheduler_snapshot.used.isZero() or
            scheduler_snapshot.poisoned or
            scheduler_snapshot.closed or
            !bank_snapshot.used.isZero() or
            bank_snapshot.active_reservations != 0 or
            bank_snapshot.committed_receipts != 0)
            return Error.InvalidConfiguration;

        for (active_storage) |*slot| slot.* = .{};
        for (record_storage) |*slot| slot.* = .{};
        self.* = .{
            .state = .open,
            .allocator = allocator,
            .binding = binding,
            .scheduler = scheduler,
            .bank = bank,
            .scheduler_identity = identity,
            .config = config,
            .active_slots = active_storage,
            .records = record_storage,
            .next_request_identity = config.first_request_identity,
            .self_address = @intFromPtr(self),
            .active_storage_address = active_address,
            .record_storage_address = record_address,
        };
    }

    pub fn admitV1(
        self: *ServiceV1,
        request: RequestV1,
    ) Error!AdmissionDecisionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenLocked();

        const intent = try self.makeIntentLocked(request);
        if (self.findRecordByIdempotencyLocked(
            request.tenant_key,
            request.idempotency_key_sha256,
        )) |index| {
            const record = self.records[index];
            if (!std.meta.eql(record.intent, intent)) {
                return .{ .conflict = .{
                    .existing_handle = record.handle,
                    .existing_intent_sha256 = record.intent.intent_sha256,
                    .supplied_intent_sha256 = intent.intent_sha256,
                } };
            }
            return .{ .existing = self.existingForRecordLocked(
                record,
            ) };
        }

        const record_index = self.findFreeRecordLocked() orelse
            return .{ .rejected = .service_capacity };
        const active_index = self.findFreeActiveLocked() orelse
            return .{ .rejected = .service_capacity };
        const request_identity =
            try peekSequenceV1(self.next_request_identity);
        const record_generation =
            try peekSequenceV1(self.next_record_generation);
        const active_generation =
            try peekSequenceV1(self.next_active_generation);
        const request_offset =
            request_identity - self.config.first_request_identity;

        var tokenized = tokenizer.tokenizeUtf8BytesV1(
            self.allocator,
            self.binding.tokenizer_manifest,
            request.prompt_utf8,
        ) catch |err| return mapTokenizerError(err);
        defer tokenized.deinit();

        const options: prepared.OptionsV1 = .{
            .max_new_tokens = request.max_new_tokens,
            .eos_token = std.math.maxInt(u32),
            .seed = 0,
        };
        const scheduling: prepared.SchedulingV1 = .{
            .tenant_key = request.tenant_key,
            .request_key = try configuredSequenceV1(
                self.config.first_scheduling_request_key,
                request_identity,
                request_offset,
            ),
            .request_generation = try configuredSequenceV1(
                self.config.first_scheduling_request_generation,
                request_identity,
                request_offset,
            ),
            .resource_owner_key = try configuredSequenceV1(
                self.config.first_resource_owner_key,
                request_identity,
                request_offset,
            ),
            .weight = 1,
            .deadline_tick = request.deadline_tick,
        };
        const local_plan = prepared.makePlanV1(
            self.binding.model.*,
            tokenized.tokens,
            options,
        ) catch |err| return mapPlanningError(err);
        const bound_input = raw_input.makeBoundPlanInputV1(
            request_identity,
            self.binding.tokenizer_manifest,
            self.binding.artifact_license_sha256,
        ) catch return Error.StateDrift;
        const bound_plan = prepared.makeBoundPlanV1(
            self.binding.model.*,
            tokenized.tokens,
            options,
            local_plan,
            scheduling,
            self.scheduler,
            bound_input,
        ) catch |err| return mapPlanningError(err);
        const input_binding = raw_input.makeBindingV1(
            request.prompt_utf8,
            &tokenized,
            local_plan,
            bound_plan,
        ) catch return Error.StateDrift;

        self.next_request_identity = request_identity + 1;
        self.next_record_generation = record_generation + 1;
        self.next_active_generation = active_generation + 1;
        const record_index_u32: u32 = @intCast(record_index);
        const active_index_u32: u32 = @intCast(active_index);
        const handle = makeHandleV1(
            self.config.service_epoch,
            record_index_u32,
            record_generation,
            intent.intent_sha256,
        );
        self.records[record_index] = .{
            .generation = record_generation,
            .state = .active,
            .intent = intent,
            .handle = handle,
            .active_index = active_index_u32,
            .active_generation = active_generation,
        };
        self.active_slots[active_index] = .{
            .generation = active_generation,
            .record_index = record_index_u32,
            .phase = .start_adoption_recovery,
            .sink = .{
                .sink_epoch = if (self.config.private_sink_epoch == 0)
                    self.config.service_epoch
                else
                    self.config.private_sink_epoch,
            },
        };

        const active = &self.active_slots[active_index];
        const start = active.session.start(
            self.allocator,
            self.binding.model,
            tokenized.tokens,
            options,
            local_plan,
            bound_input,
            bound_plan,
            scheduling,
            self.scheduler,
            self.bank,
        ) catch |err| {
            if (err == error.RecoveryRequired) {
                return .{ .recovery_required = handle };
            }
            active.* = .{};
            self.records[record_index] = .{};
            return mapStartError(err);
        };

        switch (start) {
            .rejected => |event| {
                active.* = .{};
                self.records[record_index] = .{};
                if (event.kind != .admission_rejected or
                    event.rejection_reason == .none)
                {
                    self.enterFailStopLocked(null);
                    return Error.FailStopRequired;
                }
                return .{ .rejected = .{
                    .scheduler = event,
                } };
            },
            .started => |event| {
                if (!startEventMatches(
                    event,
                    scheduling,
                    request_identity,
                )) {
                    self.enterFailStopLocked(active);
                    return Error.FailStopRequired;
                }
                const admission: AdmissionReceiptV1 = .{
                    .handle = handle,
                    .intent = intent,
                    .request_epoch = request_identity,
                    .scheduling = scheduling,
                    .prompt_receipt = tokenized.receipt,
                    .raw_input_binding = input_binding,
                    .local_plan_sha256 = local_plan.plan_sha256,
                    .bound_plan_sha256 = bound_plan.bound_plan_sha256,
                    .start_event = event,
                };
                active.admission = admission;
                active.phase = .running;
                return .{ .accepted = admission };
            },
        }
    }

    pub fn driveNextV1(
        self: *ServiceV1,
    ) Error!DriveDecisionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenLocked();

        if (self.firstBlockingRecoveryLocked()) |notice|
            return .{ .recovery_required = notice };

        const permit = self.scheduler.prepareService() catch |err| {
            if (err == error.NoRunnableRequest) return .idle;
            self.enterFailStopLocked(null);
            return Error.FailStopRequired;
        };
        const active_index =
            self.findRunningActiveForLaneHandleLocked(
                permit.handle,
            ) orelse {
                self.scheduler.abortService(permit) catch {};
                self.enterFailStopLocked(null);
                return Error.FailStopRequired;
            };
        const active = &self.active_slots[active_index];
        const record_index: usize = active.record_index;
        const handle = self.records[record_index].handle;

        const commit_receipt = active.session.step(
            permit,
            active.sink.interface(),
        ) catch |err| {
            if (active.sink.invalid or active.sink.prepared) {
                self.enterFailStopLocked(active);
                return Error.FailStopRequired;
            }
            if (err == error.RecoveryRequired) {
                self.enterFailStopLocked(active);
                return Error.FailStopRequired;
            }
            if (isExecutionError(err)) {
                active.close_reason = .execution_failed;
                const terminal = self.cancelActiveLocked(
                    record_index,
                    active_index,
                    .execution_failed,
                ) catch return Error.FailStopRequired;
                return switch (terminal) {
                    .failed => .{
                        .request_failed = handle,
                    },
                    .cancelled => {
                        self.enterFailStopLocked(null);
                        return Error.FailStopRequired;
                    },
                };
            }

            _ = self.cancelActiveLocked(
                record_index,
                active_index,
                .execution_failed,
            ) catch return Error.FailStopRequired;
            self.enterFailStopLocked(null);
            return Error.FailStopRequired;
        };

        if (!publication.commitReceiptValidV1(commit_receipt) or
            !std.meta.eql(
                commit_receipt.service_event.handle,
                permit.handle,
            ) or active.sink.invalid or
            active.sink.prepared or
            active.sink.commit_calls !=
                active.sink.committed_count or
            active.sink.committed_count == 0 or
            active.sink.committed_count >
                self.config.maximum_request_output_tokens)
        {
            self.enterFailStopLocked(active);
            return Error.FailStopRequired;
        }

        if (!active.session.isFinished()) {
            return .{ .progressed = .{
                .handle = handle,
                .committed_tokens = active.sink.committed_count,
            } };
        }
        return self.finishActiveLocked(
            record_index,
            active_index,
        );
    }

    pub fn cancelV1(
        self: *ServiceV1,
        handle: HandleV1,
    ) Error!CancelDecisionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenLocked();
        const record_index =
            try self.recordIndexForHandleLocked(handle);
        const record = &self.records[record_index];
        switch (record.state) {
            .empty => return Error.StaleHandle,
            .completed, .failed => return .{
                .already_terminal = self.existingForRecordLocked(record.*),
            },
            .cancelled => return .{
                .already_cancelled = record.cancellation orelse
                    return Error.StateDrift,
            },
            .active => {},
        }
        const active_index =
            try self.activeIndexForRecordLocked(record.*);
        const active = &self.active_slots[active_index];
        switch (active.phase) {
            .start_adoption_recovery => {
                const adoption =
                    active.session.inner.inner.recovery_adoption orelse {
                        self.enterFailStopLocked(active);
                        return Error.FailStopRequired;
                    };
                const event =
                    active.session.recoverStartAdoption() catch {
                        return .{ .recovery_required = .{
                            .handle = handle,
                            .phase = active.phase,
                        } };
                    };
                if (!recoveryCancelEventMatches(adoption, event)) {
                    self.enterFailStopLocked(active);
                    return Error.FailStopRequired;
                }
                active.* = .{};
                record.* = .{};
                return .{ .start_rolled_back = event };
            },
            .running => {
                if (self.firstBlockingRecoveryLocked()) |notice|
                    return .{ .recovery_required = notice };
                const terminal = self.cancelActiveLocked(
                    record_index,
                    active_index,
                    .caller_cancel,
                ) catch return Error.FailStopRequired;
                return switch (terminal) {
                    .cancelled => |value| .{
                        .cancelled = value,
                    },
                    .failed => |value| .{
                        .already_terminal = .{
                            .handle = value.handle,
                            .state = .failed,
                        },
                    },
                };
            },
            .publication_fail_stop => return Error.FailStopRequired,
            .empty => return Error.StateDrift,
        }
    }

    pub fn recoverV1(
        self: *ServiceV1,
        handle: HandleV1,
    ) Error!RecoveryDecisionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenLocked();
        const record_index =
            try self.recordIndexForHandleLocked(handle);
        const record = &self.records[record_index];
        if (record.state != .active)
            return Error.InvalidState;
        const active_index =
            try self.activeIndexForRecordLocked(record.*);
        const active = &self.active_slots[active_index];
        switch (active.phase) {
            .start_adoption_recovery => {
                const adoption =
                    active.session.inner.inner.recovery_adoption orelse {
                        self.enterFailStopLocked(active);
                        return Error.FailStopRequired;
                    };
                const event =
                    active.session.recoverStartAdoption() catch {
                        return .{ .still_required = .{
                            .handle = handle,
                            .phase = active.phase,
                        } };
                    };
                if (!recoveryCancelEventMatches(adoption, event)) {
                    self.enterFailStopLocked(active);
                    return Error.FailStopRequired;
                }
                active.* = .{};
                record.* = .{};
                return .{ .start_rolled_back = event };
            },
            .publication_fail_stop => return Error.FailStopRequired,
            .running, .empty => return Error.InvalidState,
        }
    }

    pub fn statusV1(
        self: *ServiceV1,
        handle: HandleV1,
    ) Error!StatusV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireReadableLocked();
        if (self.state == .fail_stop)
            return Error.FailStopRequired;
        const record_index =
            try self.recordIndexForHandleLocked(handle);
        const record = self.records[record_index];
        return switch (record.state) {
            .empty => Error.StaleHandle,
            .active => blk: {
                const active_index =
                    try self.activeIndexForRecordLocked(record);
                const active = self.active_slots[active_index];
                break :blk .{ .active = .{
                    .handle = handle,
                    .phase = active.phase,
                    .committed_tokens = active.sink.committed_count,
                } };
            },
            .completed => .{ .completed = .{
                .handle = handle,
                .response_sha256 = (record.response orelse
                    return Error.StateDrift).response_sha256,
            } },
            .cancelled => .{ .cancelled = record.cancellation orelse
                return Error.StateDrift },
            .failed => .{ .failed = record.failure orelse
                return Error.StateDrift },
        };
    }

    pub fn responseV1(
        self: *ServiceV1,
        handle: HandleV1,
    ) Error!ResponseV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireReadableLocked();
        if (self.state == .fail_stop)
            return Error.FailStopRequired;
        const record_index =
            try self.recordIndexForHandleLocked(handle);
        const record = self.records[record_index];
        return switch (record.state) {
            .completed => record.response orelse
                Error.StateDrift,
            .active => Error.ResponseNotReady,
            .cancelled, .failed => Error.NoResponse,
            .empty => Error.StaleHandle,
        };
    }

    pub fn evictTerminalV1(
        self: *ServiceV1,
        handle: HandleV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenLocked();
        const record_index =
            try self.recordIndexForHandleLocked(handle);
        switch (self.records[record_index].state) {
            .completed, .cancelled, .failed => self.records[record_index] = .{},
            .active => return Error.ActiveRequests,
            .empty => return Error.StaleHandle,
        }
    }

    pub fn snapshotV1(
        self: *ServiceV1,
    ) Error!SnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireReadableLocked();
        var result: SnapshotV1 = .{
            .state = self.state,
            .service_epoch = self.config.service_epoch,
            .next_request_identity = self.next_request_identity,
            .active_requests = 0,
            .terminal_records = 0,
            .completed_records = 0,
            .cancelled_records = 0,
            .failed_records = 0,
            .recovery_required = 0,
            .scheduler = self.scheduler.snapshot() catch null,
            .bank = self.bank.snapshot() catch null,
        };
        for (self.records) |record| switch (record.state) {
            .empty => {},
            .active => {
                result.active_requests += 1;
                const active_index =
                    self.activeIndexForRecordLocked(
                        record,
                    ) catch {
                        result.recovery_required += 1;
                        continue;
                    };
                if (self.active_slots[active_index].phase !=
                    .running)
                    result.recovery_required += 1;
            },
            .completed => {
                result.terminal_records += 1;
                result.completed_records += 1;
            },
            .cancelled => {
                result.terminal_records += 1;
                result.cancelled_records += 1;
            },
            .failed => {
                result.terminal_records += 1;
                result.failed_records += 1;
            },
        };
        return result;
    }

    pub fn closeV1(
        self: *ServiceV1,
    ) Error!CloseReceiptV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenLocked();
        var terminal_records: u32 = 0;
        for (self.records) |record| switch (record.state) {
            .active => return Error.ActiveRequests,
            .completed, .cancelled, .failed => terminal_records += 1,
            .empty => {},
        };

        const scheduler_before =
            self.scheduler.snapshot() catch
                return Error.RuntimeUnavailable;
        const bank_before = self.bank.snapshot() catch
            return Error.RuntimeUnavailable;
        if (scheduler_before.active != 0 or
            scheduler_before.finished != 0 or
            !scheduler_before.used.isZero() or
            !bank_before.used.isZero() or
            bank_before.active_reservations != 0 or
            bank_before.committed_receipts != 0)
            return Error.ActiveRequests;

        const event = self.scheduler.close() catch
            return Error.RuntimeUnavailable;
        const bank_after = self.bank.snapshot() catch {
            self.enterFailStopLocked(null);
            return Error.FailStopRequired;
        };
        if (!bank_after.used.isZero() or
            bank_after.active_reservations != 0 or
            bank_after.committed_receipts != 0)
        {
            self.enterFailStopLocked(null);
            return Error.FailStopRequired;
        }
        self.state = .closed;
        return .{
            .scheduler_event = event,
            .bank_snapshot = bank_after,
            .terminal_records = terminal_records,
        };
    }

    fn makeIntentLocked(
        self: *const ServiceV1,
        request: RequestV1,
    ) Error!IntentV1 {
        if (request.tenant_key == 0 or
            isZeroDigest(request.idempotency_key_sha256) or
            request.prompt_utf8.len == 0 or
            request.max_new_tokens == 0 or
            request.max_new_tokens >
                self.config.maximum_request_output_tokens or
            !std.unicode.utf8ValidateSlice(request.prompt_utf8))
            return Error.InvalidRequest;
        if (request.prompt_utf8.len >
            self.config.maximum_request_prompt_bytes)
            return Error.RequestTooLarge;
        const raw_text_bytes = std.math.cast(
            u64,
            request.prompt_utf8.len,
        ) orelse return Error.RequestTooLarge;
        var intent: IntentV1 = .{
            .service_epoch = self.config.service_epoch,
            .model_binding_sha256 = self.binding.binding_sha256,
            .scheduler_epoch = self.scheduler_identity.scheduler_epoch,
            .coordinator_id = self.scheduler_identity.coordinator_id,
            .bank_epoch = self.scheduler_identity.bank_epoch,
            .challenge_sha256 = self.scheduler_identity.challenge_sha256,
            .tenant_key = request.tenant_key,
            .idempotency_key_sha256 = request.idempotency_key_sha256,
            .tokenizer_domain_sha256 = self.binding.tokenizer_manifest.domain_sha256,
            .tokenizer_config_sha256 = self.binding.tokenizer_manifest.config_sha256,
            .raw_text_sha256 = tokenizer.utf8ByteRawTextRootV1(
                request.prompt_utf8,
            ),
            .raw_text_bytes = raw_text_bytes,
            .max_new_tokens = request.max_new_tokens,
            .deadline_tick = request.deadline_tick,
        };
        intent.intent_sha256 = intentSha256V1(intent);
        return intent;
    }

    fn finishActiveLocked(
        self: *ServiceV1,
        record_index: usize,
        active_index: usize,
    ) Error!DriveDecisionV1 {
        const record = &self.records[record_index];
        const active = &self.active_slots[active_index];
        const handle = record.handle;
        const admission = active.admission orelse {
            self.enterFailStopLocked(active);
            return Error.FailStopRequired;
        };
        const output = active.session.outputTokens();
        if (!active.session.isFinished() or
            active.sink.invalid or
            output.len == 0 or
            output.len > maximum_output_tokens or
            output.len != active.sink.committed_count or
            output.len != record.intent.max_new_tokens)
        {
            self.enterFailStopLocked(active);
            return Error.FailStopRequired;
        }
        for (output, 0..) |token, index| {
            if (active.sink.committed_tokens[index] != token) {
                self.enterFailStopLocked(active);
                return Error.FailStopRequired;
            }
        }

        if (active.sealed == null) {
            const terminal =
                active.session.sealTerminalResult() catch {
                    self.enterFailStopLocked(active);
                    return Error.FailStopRequired;
                };
            active.sealed = terminal;
            active.provisional_output =
                [_]u32{0} ** maximum_output_tokens;
            @memcpy(
                active.provisional_output[0..output.len],
                output,
            );
            active.provisional_output_count =
                @intCast(output.len);
        }

        const retire_event = active.session.retire() catch {
            self.enterFailStopLocked(active);
            return Error.FailStopRequired;
        };
        if (retire_event.kind != .retire or
            !std.meta.eql(
                retire_event.handle,
                admission.start_event.handle,
            ))
        {
            self.enterFailStopLocked(active);
            return Error.FailStopRequired;
        }

        var response: ResponseV1 = .{
            .handle = handle,
            .intent = record.intent,
            .admission = admission,
            .terminal = active.sealed.?,
            .retire_event = retire_event,
            .output_count = active.provisional_output_count,
            .output_tokens = active.provisional_output,
            .private_transcript_sha256 = active.sink.last_transcript_sha256,
            .private_prepare_calls = active.sink.prepare_calls,
            .private_commit_calls = active.sink.commit_calls,
            .private_abort_calls = active.sink.abort_calls,
            .response_sha256 = undefined,
        };
        response.response_sha256 = responseSha256V1(response);
        active.session.deinit();
        active.* = .{};
        record.state = .completed;
        record.active_index = no_slot;
        record.active_generation = 0;
        record.response = response;
        record.cancellation = null;
        record.failure = null;
        return .{ .completed = .{
            .handle = handle,
            .response_sha256 = response.response_sha256,
        } };
    }

    fn cancelActiveLocked(
        self: *ServiceV1,
        record_index: usize,
        active_index: usize,
        reason: CloseReasonV1,
    ) Error!TerminalCloseV1 {
        const record = &self.records[record_index];
        const active = &self.active_slots[active_index];
        const admission = active.admission orelse {
            self.enterFailStopLocked(active);
            return Error.FailStopRequired;
        };
        active.close_reason = reason;
        const event = active.session.cancel() catch {
            self.enterFailStopLocked(active);
            return Error.FailStopRequired;
        };
        if (event.kind != .cancel or
            !std.meta.eql(
                event.handle,
                admission.start_event.handle,
            ))
        {
            self.enterFailStopLocked(active);
            return Error.FailStopRequired;
        }

        const handle = record.handle;
        const intent = record.intent;
        const private_count =
            active.sink.committed_count;
        const transcript =
            active.sink.last_transcript_sha256;
        const terminal: TerminalCloseV1 = switch (reason) {
            .caller_cancel => blk: {
                var cancellation: CancellationV1 = .{
                    .handle = handle,
                    .intent = intent,
                    .admission = admission,
                    .cancel_event = event,
                    .private_committed_tokens = private_count,
                    .private_transcript_sha256 = transcript,
                    .cancellation_sha256 = undefined,
                };
                cancellation.cancellation_sha256 =
                    cancellationSha256V1(cancellation);
                break :blk .{
                    .cancelled = cancellation,
                };
            },
            .execution_failed => blk: {
                var failure: FailureV1 = .{
                    .handle = handle,
                    .intent = intent,
                    .admission = admission,
                    .reason = .execution_failed,
                    .cancel_event = event,
                    .private_committed_tokens = private_count,
                    .private_transcript_sha256 = transcript,
                    .failure_sha256 = undefined,
                };
                failure.failure_sha256 =
                    failureSha256V1(failure);
                break :blk .{ .failed = failure };
            },
            .none => return Error.InvalidState,
        };

        active.session.deinit();
        active.* = .{};
        record.active_index = no_slot;
        record.active_generation = 0;
        record.response = null;
        switch (terminal) {
            .cancelled => |value| {
                record.state = .cancelled;
                record.cancellation = value;
                record.failure = null;
            },
            .failed => |value| {
                record.state = .failed;
                record.failure = value;
                record.cancellation = null;
            },
        }
        return terminal;
    }

    fn requireStorageStableLocked(
        self: *const ServiceV1,
    ) Error!void {
        if (self.state == .empty)
            return Error.InvalidState;
        if (self.self_address != @intFromPtr(self) or
            self.active_slots.len == 0 or
            self.records.len < self.active_slots.len or
            self.active_storage_address !=
                @intFromPtr(self.active_slots.ptr) or
            self.record_storage_address !=
                @intFromPtr(self.records.ptr))
            return Error.StateDrift;
    }

    fn requireOpenLocked(self: *const ServiceV1) Error!void {
        try self.requireStorageStableLocked();
        switch (self.state) {
            .open => {},
            .fail_stop => return Error.FailStopRequired,
            .closed => return Error.ServiceClosed,
            .empty => return Error.InvalidState,
        }
        if (!modelBindingValidV1(self.binding))
            return Error.StateDrift;
    }

    fn requireReadableLocked(
        self: *const ServiceV1,
    ) Error!void {
        try self.requireStorageStableLocked();
        if (self.state != .closed and
            !modelBindingValidV1(self.binding))
            return Error.StateDrift;
    }

    fn findRecordByIdempotencyLocked(
        self: *const ServiceV1,
        tenant_key: u64,
        idempotency_key_sha256: Digest,
    ) ?usize {
        for (self.records, 0..) |record, index| {
            if (record.state != .empty and
                record.intent.tenant_key == tenant_key and
                digestEqual(
                    record.intent.idempotency_key_sha256,
                    idempotency_key_sha256,
                ))
                return index;
        }
        return null;
    }

    fn findFreeRecordLocked(
        self: *const ServiceV1,
    ) ?usize {
        for (self.records, 0..) |record, index|
            if (record.state == .empty) return index;
        return null;
    }

    fn findFreeActiveLocked(
        self: *const ServiceV1,
    ) ?usize {
        for (self.active_slots, 0..) |active, index|
            if (active.phase == .empty) return index;
        return null;
    }

    fn findRunningActiveForLaneHandleLocked(
        self: *const ServiceV1,
        handle: lane.Handle,
    ) ?usize {
        for (self.active_slots, 0..) |active, index| {
            if (active.phase != .running) continue;
            const admission = active.admission orelse continue;
            if (std.meta.eql(
                admission.start_event.handle,
                handle,
            ))
                return index;
        }
        return null;
    }

    fn recordIndexForHandleLocked(
        self: *const ServiceV1,
        handle: HandleV1,
    ) Error!usize {
        if (!handleValidV1(handle) or
            handle.service_epoch != self.config.service_epoch or
            handle.record_index >= self.records.len)
            return Error.StaleHandle;
        const index: usize = handle.record_index;
        const record = self.records[index];
        if (record.state == .empty or
            record.generation != handle.record_generation or
            !std.meta.eql(record.handle, handle) or
            !digestEqual(
                record.intent.intent_sha256,
                handle.intent_sha256,
            ))
            return Error.StaleHandle;
        return index;
    }

    fn activeIndexForRecordLocked(
        self: *const ServiceV1,
        record: RecordSlotV1,
    ) Error!usize {
        if (record.state != .active or
            record.active_index == no_slot or
            record.active_index >= self.active_slots.len)
            return Error.StateDrift;
        const index: usize = record.active_index;
        const active = self.active_slots[index];
        if (active.phase == .empty or
            active.generation != record.active_generation or
            active.record_index != record.handle.record_index)
            return Error.StateDrift;
        return index;
    }

    fn existingForRecordLocked(
        self: *const ServiceV1,
        record: RecordSlotV1,
    ) ExistingV1 {
        const state: ExistingStateV1 = switch (record.state) {
            .empty => unreachable,
            .active => blk: {
                const index =
                    self.activeIndexForRecordLocked(
                        record,
                    ) catch break :blk .recovery_required;
                break :blk if (self.active_slots[index].phase ==
                    .running)
                    .active
                else
                    .recovery_required;
            },
            .completed => .completed,
            .cancelled => .cancelled,
            .failed => .failed,
        };
        return .{
            .handle = record.handle,
            .state = state,
        };
    }

    fn firstBlockingRecoveryLocked(
        self: *const ServiceV1,
    ) ?RecoveryNoticeV1 {
        for (self.active_slots) |active| {
            if (active.phase != .start_adoption_recovery)
                continue;
            const record_index: usize = active.record_index;
            if (record_index >= self.records.len) continue;
            return .{
                .handle = self.records[record_index].handle,
                .phase = active.phase,
            };
        }
        return null;
    }

    fn enterFailStopLocked(
        self: *ServiceV1,
        active: ?*ActiveSlotV1,
    ) void {
        if (active) |slot|
            slot.phase = .publication_fail_stop;
        self.state = .fail_stop;
    }
};

fn modelBindingSha256V1(binding: ModelBindingV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(binding_domain);
    hash.update(&binding.bundle.package.package_sha256);
    hash.update(
        &binding.bundle.representation.representation_sha256,
    );
    hash.update(&binding.tokenizer_manifest.domain_sha256);
    hash.update(&binding.tokenizer_manifest.config_sha256);
    hashU64(&hash, binding.artifact_license_bytes);
    hash.update(&binding.artifact_license_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn intentSha256V1(intent: IntentV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(intent_domain);
    hashU64(&hash, intent.service_epoch);
    hash.update(&intent.model_binding_sha256);
    hashU64(&hash, intent.scheduler_epoch);
    hashU64(&hash, intent.coordinator_id);
    hashU64(&hash, intent.bank_epoch);
    hash.update(&intent.challenge_sha256);
    hashU64(&hash, intent.tenant_key);
    hash.update(&intent.idempotency_key_sha256);
    hash.update(&intent.tokenizer_domain_sha256);
    hash.update(&intent.tokenizer_config_sha256);
    hash.update(&intent.raw_text_sha256);
    hashU64(&hash, intent.raw_text_bytes);
    hashU16(&hash, intent.max_new_tokens);
    hashU64(&hash, intent.deadline_tick);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn makeHandleV1(
    service_epoch: u64,
    record_index: u32,
    record_generation: u64,
    intent_sha256: Digest,
) HandleV1 {
    var handle: HandleV1 = .{
        .service_epoch = service_epoch,
        .record_index = record_index,
        .record_generation = record_generation,
        .intent_sha256 = intent_sha256,
    };
    handle.handle_sha256 = handleSha256V1(handle);
    return handle;
}

fn handleSha256V1(handle: HandleV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(handle_domain);
    hashU64(&hash, handle.service_epoch);
    hashU32(&hash, handle.record_index);
    hashU64(&hash, handle.record_generation);
    hash.update(&handle.intent_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn responseSha256V1(response: ResponseV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(response_domain);
    hash.update(&response.handle.handle_sha256);
    hash.update(&response.intent.intent_sha256);
    hash.update(
        &response.admission.raw_input_binding.binding_sha256,
    );
    hash.update(&response.admission.start_event.event_sha256);
    hash.update(&response.terminal.evidence_sha256);
    hash.update(&response.retire_event.event_sha256);
    hashU16(&hash, response.output_count);
    for (response.output_tokens[0..response.output_count]) |token|
        hashU32(&hash, token);
    hash.update(&response.private_transcript_sha256);
    hashU16(&hash, response.private_prepare_calls);
    hashU16(&hash, response.private_commit_calls);
    hashU16(&hash, response.private_abort_calls);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn cancellationSha256V1(
    cancellation: CancellationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(cancellation_domain);
    hash.update(&cancellation.handle.handle_sha256);
    hash.update(&cancellation.intent.intent_sha256);
    hash.update(&cancellation.admission.start_event.event_sha256);
    hash.update(&cancellation.cancel_event.event_sha256);
    hashU16(&hash, cancellation.private_committed_tokens);
    hash.update(&cancellation.private_transcript_sha256);
    hashU16(&hash, cancellation.externally_visible_tokens);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn failureSha256V1(failure: FailureV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(failure_domain);
    hash.update(&failure.handle.handle_sha256);
    hash.update(&failure.intent.intent_sha256);
    hash.update(&failure.admission.start_event.event_sha256);
    hash.update(&failure.cancel_event.event_sha256);
    hash.update(&.{@intFromEnum(failure.reason)});
    hashU16(&hash, failure.private_committed_tokens);
    hash.update(&failure.private_transcript_sha256);
    hashU16(&hash, failure.externally_visible_tokens);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn startEventMatches(
    event: lane.EventV1,
    scheduling: prepared.SchedulingV1,
    request_epoch: u64,
) bool {
    return event.kind == .admission_accepted and
        event.rejection_reason == .none and
        event.handle.tenant_key == scheduling.tenant_key and
        event.handle.request_key == scheduling.request_key and
        event.handle.request_generation ==
            scheduling.request_generation and
        event.spec.tenant_key == scheduling.tenant_key and
        event.spec.request_key == scheduling.request_key and
        event.spec.request_generation ==
            scheduling.request_generation and
        event.spec.resource_owner_key ==
            scheduling.resource_owner_key and
        event.resource_receipt.owner_key ==
            scheduling.resource_owner_key and
        request_epoch != 0 and
        event.abi_version == lane.event_abi and
        digestEqual(event.event_sha256, lane.eventSha256(event));
}

fn recoveryCancelEventMatches(
    adoption: lane.PublicationAdoptionV1,
    event: lane.EventV1,
) bool {
    const accepted = adoption.admission.event;
    const expected_sequence = std.math.add(
        u64,
        accepted.event_sequence,
        1,
    ) catch return false;
    return digestEqual(
        adoption.adoption_sha256,
        lane.publicationAdoptionSha256(adoption),
    ) and
        digestEqual(
            accepted.event_sha256,
            lane.eventSha256(accepted),
        ) and
        accepted.kind == .admission_accepted and
        event.abi_version == lane.event_abi and
        event.scheduler_epoch == adoption.scheduler_epoch and
        event.kind == .cancel and
        event.rejection_reason == .none and
        event.event_sequence == expected_sequence and
        std.meta.eql(event.handle, adoption.admission.handle) and
        std.meta.eql(event.spec, accepted.spec) and
        std.meta.eql(
            event.resource_receipt,
            accepted.resource_receipt,
        ) and
        digestEqual(
            event.resource_receipt_sha256,
            accepted.resource_receipt_sha256,
        ) and
        digestEqual(event.previous_sha256, accepted.event_sha256) and
        digestEqual(event.state_before_sha256, accepted.state_after_sha256) and
        digestEqual(event.event_sha256, lane.eventSha256(event));
}

fn peekSequenceV1(sequence: u64) Error!u64 {
    if (sequence == 0 or
        sequence == std.math.maxInt(u64))
        return Error.SequenceExhausted;
    return sequence;
}

fn configuredSequenceV1(
    configured_first: u64,
    fallback: u64,
    offset: u64,
) Error!u64 {
    if (configured_first == 0) return fallback;
    const result = std.math.add(
        u64,
        configured_first,
        offset,
    ) catch return Error.SequenceExhausted;
    if (result == 0) return Error.SequenceExhausted;
    return result;
}

fn mapTokenizerError(
    err: tokenizer.CanonicalError,
) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.InputTooLarge => Error.RequestTooLarge,
        error.EmptyInput,
        error.InvalidUtf8,
        error.InvalidPrompt,
        error.InvalidToken,
        => Error.InvalidRequest,
        error.InvalidLength,
        error.InvalidManifest,
        error.UnsupportedVocabulary,
        error.InvalidLimit,
        error.UnsafeDestination,
        => Error.InvalidModelBinding,
    };
}

fn mapPlanningError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.ContextTooLong,
        error.ResourceBudgetExceeded,
        => Error.RequestTooLarge,
        error.PreparedImageRequired,
        error.InvalidConfiguration,
        error.InvalidPlan,
        error.InvalidBoundPlan,
        => Error.InvalidModelBinding,
        error.SequenceOverflow,
        error.GenerationOverflow,
        error.ServiceOverflow,
        => Error.SequenceExhausted,
        else => Error.RuntimeUnavailable,
    };
}

fn mapStartError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.ContextTooLong,
        error.ResourceBudgetExceeded,
        => Error.RequestTooLarge,
        error.SequenceOverflow,
        error.GenerationOverflow,
        error.ServiceOverflow,
        => Error.SequenceExhausted,
        error.PreparedImageRequired,
        error.InvalidConfiguration,
        error.InvalidPlan,
        error.InvalidBoundPlan,
        error.InvalidAdmission,
        error.AdmissionClaimMismatch,
        => Error.InvalidModelBinding,
        else => Error.RuntimeUnavailable,
    };
}

fn isExecutionError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.CacheFull,
        error.ShapeMismatch,
        error.ForwardFailed,
        error.BatchPrefillUnavailable,
        error.SealedDecodePlanUnavailable,
        error.LogitlessGreedyUnavailable,
        error.EligibilityProviderUnavailable,
        error.EligibilityCertificateRejected,
        error.MlpRepresentationUnavailable,
        error.ContextTooLong,
        error.ResourceBudgetExceeded,
        error.ResourceAdmissionUnavailable,
        error.ResourceCommitObserverRejected,
        error.TokenPublicationObserverRejected,
        error.TokenTransactionRejected,
        error.PostPublicationReclaimPending,
        error.PostPublicationGenerationInterrupted,
        error.DecodeLane4Unavailable,
        => true,
        else => false,
    };
}

fn rangesOverlap(
    first_address: usize,
    first_bytes: usize,
    second_address: usize,
    second_bytes: usize,
) bool {
    const first_end = std.math.add(
        usize,
        first_address,
        first_bytes,
    ) catch return true;
    const second_end = std.math.add(
        usize,
        second_address,
        second_bytes,
    ) catch return true;
    return first_address < second_end and
        second_address < first_end;
}

fn isZeroDigest(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

fn digestEqual(first: Digest, second: Digest) bool {
    return std.mem.eql(u8, &first, &second);
}

fn hashU16(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u16,
) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
