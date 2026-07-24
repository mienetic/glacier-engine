//! Resource-admitted, transactional image/audio/video runtime publication.

const std = @import("std");
const resource_bank = @import("resource_bank.zig");
const qos = @import("lane_weave_qos.zig");
const media = @import("media_contract.zig");
const decode_plan = @import("media_decode_plan.zig");
const fixture_api = @import("media_fixture.zig");
const transform = @import("media_transform.zig");

pub const Digest = media.Digest;
pub const runtime_abi: u64 = 0x474d_5254_0000_0001;
pub const receipt_abi: u64 = 0x474d_5252_0000_0001;
pub const receipt_magic = [_]u8{
    'G', 'M', 'R', 'T', 'X', 'N', '1', 0,
};
pub const receipt_bytes: usize = 640;
pub const receipt_body_bytes: usize = receipt_bytes - 32;
pub const mapping_accounting_bytes: u64 = 128;
pub const allowed_flags: u64 = 0;

const resource_domain = "glacier-media-runtime-resource-v1\x00";
const receipt_domain = "glacier-media-runtime-receipt-v1\x00";

comptime {
    if (@sizeOf(transform.TransformMappingV1) !=
        mapping_accounting_bytes)
        @compileError("media transform mapping accounting drift");
}

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidConfiguration,
    InvalidReceipt,
    InvalidState,
    PublicationFailed,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
    TransformFailed,
};

pub const ExecutionReceiptV1 = struct {
    operation: transform.TransformOperationV1,
    kind: media.MediaKindV1,
    request_epoch: u64,
    resource_sequence: u64,
    media_sequence: u64,
    logical_units: u64,
    output_bytes: u64,
    mapping_count: u64,
    claim: resource_bank.Claim,
    resource_bank_epoch: u64,
    resource_slot_index: u32,
    resource_generation: u64,
    resource_owner_key: u64,
    resource_integrity: u64,
    fixture_sha256: Digest,
    transform_plan_sha256: Digest,
    transform_receipt_sha256: Digest,
    resource_claim_sha256: Digest,
    timeline_event_sha256: Digest,
    publication_commit_sha256: Digest,
    output_sha256: Digest,
    mapping_chain_sha256: Digest,
    receipt_sha256: Digest,
};

pub const reference_maximum_payload_bytes: usize =
    fixture_api.maximum_payload_bytes;
pub const reference_maximum_mappings: usize = 4;

/// Caller-owned backing storage for one retained image/audio/video reference
/// input. Returned byte slices borrow this storage.
pub const ReferenceInputStorageV1 = struct {
    fixture: [fixture_api.maximum_fixture_bytes]u8 = undefined,
    decode_plan: [decode_plan.plan_bytes]u8 = undefined,
    transform_plan: [transform.transform_plan_bytes]u8 = undefined,
    decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined,
};

/// Per-session provisional buffers for the retained reference inputs.
pub const ReferenceExecutionStorageV1 = struct {
    decoded_source: [reference_maximum_payload_bytes]u8 = undefined,
    output: [reference_maximum_payload_bytes]u8 = undefined,
    mappings: [reference_maximum_mappings]transform.TransformMappingV1 =
        undefined,
};

/// Fully sealed model-free input used by examples, conformance campaigns, and
/// integration tests. It is deliberately separate from execution buffers.
pub const ReferenceInputV1 = struct {
    encoded_fixture: []const u8,
    fixture: fixture_api.ParsedFixtureV1,
    encoded_decode_plan: []const u8,
    decode_receipt: fixture_api.DecodeReceiptV1,
    transform_plan: transform.TransformPlanV1,
    encoded_transform_plan: []const u8,
    expected_output: []const u8,
    timeline_base: media.TimeBaseV1,
};

pub fn claimForExecutionV1(
    encoded_fixture_bytes: usize,
    plan: transform.TransformPlanV1,
) Error!resource_bank.Claim {
    transform.validateTransformPlanV1(plan) catch
        return Error.InvalidConfiguration;
    const fixture_bytes = std.math.cast(
        u64,
        encoded_fixture_bytes,
    ) orelse return Error.ArithmeticOverflow;
    const mapping_bytes = checkedMul(
        plan.logical_units,
        mapping_accounting_bytes,
    ) catch return Error.ArithmeticOverflow;
    const staging_bytes = checkedAdd(
        mapping_bytes,
        plan.scratch_bytes,
    ) catch return Error.ArithmeticOverflow;
    const capsule_bytes = checkedAdd(
        decode_plan.plan_bytes,
        transform.transform_plan_bytes,
    ) catch return Error.ArithmeticOverflow;
    return .{
        .capsule_bytes = capsule_bytes,
        .kv_bytes = 0,
        .activation_bytes = plan.source_bytes,
        .partial_bytes = 0,
        .logits_bytes = 0,
        .output_journal_bytes = plan.output_bytes,
        .staging_bytes = staging_bytes,
        .device_bytes = 0,
        .io_bytes = fixture_bytes,
        .queue_slots = 1,
    };
}

pub fn limitsForClaimV1(
    claim: resource_bank.Claim,
) Error!resource_bank.Limits {
    return .{
        .host_bytes = claim.hostBytes() catch
            return Error.ArithmeticOverflow,
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
    };
}

pub fn resourceCommitmentV1(
    receipt: resource_bank.Receipt,
    request_epoch: u64,
    fixture_sha256: Digest,
    transform_plan_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(resource_domain);
    hashU64(&hash, runtime_abi);
    hashU64(&hash, request_epoch);
    hashU64(&hash, receipt.bank_epoch);
    hashU64(&hash, receipt.slot_index);
    hashU64(&hash, receipt.generation);
    hashU64(&hash, receipt.owner_key);
    hashClaim(&hash, receipt.claim);
    hashU64(&hash, receipt.integrity);
    hash.update(&fixture_sha256);
    hash.update(&transform_plan_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn timelineEventForPlanV1(
    plan: transform.TransformPlanV1,
    fixture: fixture_api.ParsedFixtureV1,
    state: media.PublicationStateV1,
    transform_plan_sha256: Digest,
) Error!media.TimelineEventV1 {
    transform.validateTransformPlanV1(plan) catch
        return Error.InvalidConfiguration;
    if (plan.kind != fixture.kind or
        !std.mem.eql(
            u8,
            &plan.media_object_sha256,
            &fixture.media_object_sha256,
        ) or
        !std.meta.eql(
            outputTimelineBaseV1(plan),
            state.timeline_base,
        ))
        return Error.InvalidConfiguration;
    const source = try sourceSpanV1(plan);
    const target_end = checkedAdd(
        state.visible_units,
        plan.logical_units,
    ) catch return Error.ArithmeticOverflow;
    return .{
        .kind = switch (plan.operation) {
            .image_crop_nearest_tile => .resample,
            .audio_mix_decimate => .resample,
            .video_keyframe_select => .frame_select,
        },
        .sequence = state.next_sequence,
        .media_object_sha256 = plan.media_object_sha256,
        .source = source,
        .target = .{
            .start = .{
                .ticks = state.visible_units,
                .base = state.timeline_base,
            },
            .end = .{
                .ticks = target_end,
                .base = state.timeline_base,
            },
        },
        .plan_sha256 = transform_plan_sha256,
        .previous_event_sha256 = state.timeline_sha256,
    };
}

pub fn encodeExecutionReceiptV1(
    receipt: ExecutionReceiptV1,
    destination: []u8,
) Error![]const u8 {
    try validateExecutionReceiptV1(receipt);
    if (destination.len < receipt_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..receipt_bytes];
    writeReceiptBodyV1(receipt, output[0..receipt_body_bytes]);
    const root = executionReceiptRootV1(receipt);
    @memcpy(output[receipt_body_bytes..], &root);
    return output;
}

pub fn decodeExecutionReceiptV1(
    encoded: []const u8,
) Error!ExecutionReceiptV1 {
    if (encoded.len != receipt_bytes or
        !std.mem.eql(u8, encoded[0..8], &receipt_magic) or
        readU64(encoded, 8) != receipt_abi or
        readU64(encoded, 16) != receipt_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[472..receipt_body_bytes], 0))
        return Error.InvalidReceipt;
    const slot_raw = readU64(encoded, 184);
    const slot_index = std.math.cast(
        u32,
        slot_raw,
    ) orelse return Error.InvalidReceipt;
    var receipt: ExecutionReceiptV1 = .{
        .operation = std.meta.intToEnum(
            transform.TransformOperationV1,
            readU64(encoded, 32),
        ) catch return Error.InvalidReceipt,
        .kind = std.meta.intToEnum(
            media.MediaKindV1,
            readU64(encoded, 40),
        ) catch return Error.InvalidReceipt,
        .request_epoch = readU64(encoded, 48),
        .resource_sequence = readU64(encoded, 56),
        .media_sequence = readU64(encoded, 64),
        .logical_units = readU64(encoded, 72),
        .output_bytes = readU64(encoded, 80),
        .mapping_count = readU64(encoded, 88),
        .claim = readClaim(encoded, 96),
        .resource_bank_epoch = readU64(encoded, 176),
        .resource_slot_index = slot_index,
        .resource_generation = readU64(encoded, 192),
        .resource_owner_key = readU64(encoded, 200),
        .resource_integrity = readU64(encoded, 208),
        .fixture_sha256 = undefined,
        .transform_plan_sha256 = undefined,
        .transform_receipt_sha256 = undefined,
        .resource_claim_sha256 = undefined,
        .timeline_event_sha256 = undefined,
        .publication_commit_sha256 = undefined,
        .output_sha256 = undefined,
        .mapping_chain_sha256 = undefined,
        .receipt_sha256 = undefined,
    };
    @memcpy(&receipt.fixture_sha256, encoded[216..248]);
    @memcpy(&receipt.transform_plan_sha256, encoded[248..280]);
    @memcpy(&receipt.transform_receipt_sha256, encoded[280..312]);
    @memcpy(&receipt.resource_claim_sha256, encoded[312..344]);
    @memcpy(&receipt.timeline_event_sha256, encoded[344..376]);
    @memcpy(&receipt.publication_commit_sha256, encoded[376..408]);
    @memcpy(&receipt.output_sha256, encoded[408..440]);
    @memcpy(&receipt.mapping_chain_sha256, encoded[440..472]);
    @memcpy(
        &receipt.receipt_sha256,
        encoded[receipt_body_bytes..],
    );
    try validateExecutionReceiptV1(receipt);
    return receipt;
}

pub fn executionReceiptRootV1(
    receipt: ExecutionReceiptV1,
) Digest {
    var body: [receipt_body_bytes]u8 = undefined;
    writeReceiptBodyV1(receipt, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hash.update(&body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn verifyExecutionReceiptV1(
    state_before: media.PublicationStateV1,
    encoded_fixture: []const u8,
    encoded_transform_plan: []const u8,
    transform_receipt: transform.TransformReceiptV1,
    output: []const u8,
    mappings: []const transform.TransformMappingV1,
    receipt: ExecutionReceiptV1,
) Error!void {
    try validateExecutionReceiptV1(receipt);
    transform.verifyReceiptV1(
        encoded_fixture,
        encoded_transform_plan,
        transform_receipt,
        output,
        mappings,
    ) catch return Error.TransformFailed;
    const fixture = fixture_api.parseFixtureV1(
        encoded_fixture,
    ) catch return Error.TransformFailed;
    const plan = transform.decodeTransformPlanV1(
        encoded_transform_plan,
    ) catch return Error.TransformFailed;
    const plan_sha256 = transform.transformPlanSha256V1(
        encoded_transform_plan,
    ) catch return Error.TransformFailed;
    const expected_claim = try claimForExecutionV1(
        encoded_fixture.len,
        plan,
    );
    const resource_receipt: resource_bank.Receipt = .{
        .bank_epoch = receipt.resource_bank_epoch,
        .slot_index = receipt.resource_slot_index,
        .generation = receipt.resource_generation,
        .owner_key = receipt.resource_owner_key,
        .claim = receipt.claim,
        .integrity = receipt.resource_integrity,
    };
    if (!resource_bank.receiptIntegrityValidV1(resource_receipt) or
        !std.meta.eql(receipt.claim, expected_claim) or
        receipt.operation != plan.operation or
        receipt.kind != plan.kind or
        receipt.request_epoch != state_before.request_epoch or
        receipt.media_sequence != state_before.next_sequence or
        receipt.logical_units != plan.logical_units or
        receipt.output_bytes != plan.output_bytes or
        receipt.mapping_count != plan.logical_units or
        !std.mem.eql(
            u8,
            &receipt.fixture_sha256,
            &fixture.fixture_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.transform_plan_sha256,
            &plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.transform_receipt_sha256,
            &transform_receipt.receipt_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.output_sha256,
            &transform_receipt.output_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.mapping_chain_sha256,
            &transform_receipt.mapping_chain_sha256,
        ))
        return Error.InvalidReceipt;
    const resource_claim_sha256 = resourceCommitmentV1(
        resource_receipt,
        state_before.request_epoch,
        fixture.fixture_sha256,
        plan_sha256,
    );
    const event = try timelineEventForPlanV1(
        plan,
        fixture,
        state_before,
        plan_sha256,
    );
    const event_sha256 = media.timelineEventRootV1(
        event,
    ) catch return Error.PublicationFailed;
    const publication = media.preparePublicationV1(
        state_before,
        event,
        transform_receipt.output_sha256,
        resource_claim_sha256,
    ) catch return Error.PublicationFailed;
    if (!std.mem.eql(
        u8,
        &receipt.resource_claim_sha256,
        &resource_claim_sha256,
    ) or
        !std.mem.eql(
            u8,
            &receipt.timeline_event_sha256,
            &event_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.publication_commit_sha256,
            &publication.commit_sha256,
        ))
        return Error.InvalidReceipt;
}

pub const SessionReceiptOwnerV1 = enum {
    session,
    scheduler,
};

const ValidatedSessionInputV1 = struct {
    claim: resource_bank.Claim,
    fixture_sha256: Digest,
    plan_sha256: Digest,
};

const SessionPhase = enum {
    idle,
    prepared,
    armed,
    committing,
    closed,
};

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    receipt: resource_bank.Receipt = undefined,
    request_epoch: u64 = 0,
    media_state: *media.PublicationStateV1 = undefined,
    admitted_claim: resource_bank.Claim = .{},
    admitted_fixture_sha256: Digest = [_]u8{0} ** 32,
    admitted_plan_sha256: Digest = [_]u8{0} ** 32,
    receipt_owner: SessionReceiptOwnerV1 = .session,
    scheduler: ?*qos.Scheduler = null,
    scheduled_handle: ?qos.Handle = null,
    initialized: bool = false,
    published: bool = false,
    phase: SessionPhase = .idle,
    next_resource_sequence: u64 = 0,
    next_generation: u64 = 1,
    active_generation: u64 = 0,
    active_permit: ?resource_bank.PublicationPermit = null,
    active_transform_receipt: ?transform.TransformReceiptV1 = null,
    active_publication: ?media.PreparedPublicationV1 = null,
    active_event_sha256: Digest = [_]u8{0} ** 32,
    active_resource_sha256: Digest = [_]u8{0} ** 32,
    active_fixture: ?[]const u8 = null,
    active_transform_plan: ?[]const u8 = null,
    active_decoded_source: ?[]u8 = null,
    active_output: ?[]u8 = null,
    active_mappings: ?[]transform.TransformMappingV1 = null,

    pub fn init(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        request_epoch: u64,
        publication_state: *media.PublicationStateV1,
        encoded_fixture: []const u8,
        encoded_transform_plan: []const u8,
    ) Error!void {
        if (self.initialized) return Error.InvalidState;
        if (owner_key == 0)
            return Error.InvalidConfiguration;
        const admitted = try validateSessionInputV1(
            request_epoch,
            publication_state,
            encoded_fixture,
            encoded_transform_plan,
        );
        const reservation = bank.reserve(
            owner_key,
            admitted.claim,
        ) catch return Error.ResourceAdmissionFailed;
        const receipt = bank.commit(reservation) catch {
            bank.cancel(reservation) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceAdmissionFailed;
        };
        bank.bindPublicationSession(
            receipt,
            request_epoch,
            @intFromPtr(self),
        ) catch {
            bank.release(receipt) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        self.* = .{
            .bank = bank,
            .receipt = receipt,
            .request_epoch = request_epoch,
            .media_state = publication_state,
            .admitted_claim = admitted.claim,
            .admitted_fixture_sha256 = admitted.fixture_sha256,
            .admitted_plan_sha256 = admitted.plan_sha256,
            .receipt_owner = .session,
            .initialized = true,
        };
    }

    /// Adopt the exact committed receipt created by one current LaneWeave
    /// admission. The Session must already reside at its final address and
    /// must not move until `cancelScheduledV1` or `retireScheduledV1` returns.
    /// This path performs no ResourceBank reserve or commit.
    pub fn initScheduledV1(
        self: *Session,
        scheduler: *qos.Scheduler,
        admission: qos.Admission,
        request_epoch: u64,
        publication_state: *media.PublicationStateV1,
        encoded_fixture: []const u8,
        encoded_transform_plan: []const u8,
    ) Error!void {
        if (self.initialized) return Error.InvalidState;
        const admitted = try validateSessionInputV1(
            request_epoch,
            publication_state,
            encoded_fixture,
            encoded_transform_plan,
        );
        const event = admission.event;
        if (event.kind != .admission_accepted or
            event.rejection_reason != .none or
            !std.meta.eql(event.handle, admission.handle) or
            !std.meta.eql(event.spec.claim, admitted.claim) or
            !std.meta.eql(event.resource_receipt.claim, admitted.claim) or
            event.spec.resource_owner_key !=
                event.resource_receipt.owner_key)
            return Error.InvalidConfiguration;

        scheduler.bindFinalPublicationSession(
            admission,
            request_epoch,
            @intFromPtr(self),
        ) catch |err| switch (err) {
            error.InvalidConfiguration => return Error.InvalidConfiguration,
            else => return Error.ResourceReceiptInvalid,
        };
        self.* = .{
            .bank = scheduler.bank,
            .receipt = event.resource_receipt,
            .request_epoch = request_epoch,
            .media_state = publication_state,
            .admitted_claim = admitted.claim,
            .admitted_fixture_sha256 = admitted.fixture_sha256,
            .admitted_plan_sha256 = admitted.plan_sha256,
            .receipt_owner = .scheduler,
            .scheduler = scheduler,
            .scheduled_handle = admission.handle,
            .initialized = true,
        };
    }

    pub fn prepare(
        self: *Session,
        encoded_fixture: []const u8,
        encoded_decode_plan: []const u8,
        encoded_transform_plan: []const u8,
        decoded_source: []u8,
        output: []u8,
        mappings: []transform.TransformMappingV1,
    ) Error!Transaction {
        if (!self.initialized or self.phase != .idle or
            self.published or self.active_generation != 0)
            return Error.InvalidState;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return Error.InvalidState;
        const fixture = fixture_api.parseFixtureV1(
            encoded_fixture,
        ) catch return Error.TransformFailed;
        const plan = transform.decodeTransformPlanV1(
            encoded_transform_plan,
        ) catch return Error.TransformFailed;
        const plan_sha256 = transform.transformPlanSha256V1(
            encoded_transform_plan,
        ) catch return Error.TransformFailed;
        const expected_claim = try claimForExecutionV1(
            encoded_fixture.len,
            plan,
        );
        if (!std.meta.eql(expected_claim, self.admitted_claim) or
            !std.mem.eql(
                u8,
                &fixture.fixture_sha256,
                &self.admitted_fixture_sha256,
            ) or
            !std.mem.eql(
                u8,
                &plan_sha256,
                &self.admitted_plan_sha256,
            ) or
            self.media_state.request_epoch != self.request_epoch or
            !std.mem.eql(
                u8,
                &self.media_state.media_object_sha256,
                &plan.media_object_sha256,
            ) or
            !std.meta.eql(
                self.media_state.timeline_base,
                outputTimelineBaseV1(plan),
            ))
            return Error.InvalidConfiguration;
        const source_bytes = std.math.cast(
            usize,
            plan.source_bytes,
        ) orelse return Error.InvalidConfiguration;
        const output_bytes = std.math.cast(
            usize,
            plan.output_bytes,
        ) orelse return Error.InvalidConfiguration;
        const mapping_count = std.math.cast(
            usize,
            plan.logical_units,
        ) orelse return Error.InvalidConfiguration;
        if (decoded_source.len < source_bytes or
            output.len < output_bytes or
            mappings.len < mapping_count)
            return Error.BufferTooSmall;
        const source_slice = decoded_source[0..source_bytes];
        const output_slice = output[0..output_bytes];
        const mapping_slice = mappings[0..mapping_count];
        const permit = self.bank.beginPublication(
            self.receipt,
            self.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        const transform_receipt = transform.executeV1(
            encoded_fixture,
            encoded_decode_plan,
            encoded_transform_plan,
            source_slice,
            output_slice,
            mapping_slice,
        ) catch {
            scrubBuffers(source_slice, output_slice, mapping_slice);
            self.bank.abortPublication(permit) catch
                return Error.ResourceReceiptInvalid;
            return Error.TransformFailed;
        };
        transform.verifyReceiptV1(
            encoded_fixture,
            encoded_transform_plan,
            transform_receipt,
            output_slice,
            mapping_slice,
        ) catch {
            scrubBuffers(source_slice, output_slice, mapping_slice);
            self.bank.abortPublication(permit) catch
                return Error.ResourceReceiptInvalid;
            return Error.TransformFailed;
        };
        const event = timelineEventForPlanV1(
            plan,
            fixture,
            self.media_state.*,
            plan_sha256,
        ) catch {
            scrubBuffers(source_slice, output_slice, mapping_slice);
            self.bank.abortPublication(permit) catch
                return Error.ResourceReceiptInvalid;
            return Error.PublicationFailed;
        };
        const event_sha256 = media.timelineEventRootV1(
            event,
        ) catch {
            scrubBuffers(source_slice, output_slice, mapping_slice);
            self.bank.abortPublication(permit) catch
                return Error.ResourceReceiptInvalid;
            return Error.PublicationFailed;
        };
        const resource_sha256 = resourceCommitmentV1(
            self.receipt,
            self.request_epoch,
            fixture.fixture_sha256,
            plan_sha256,
        );
        const publication = media.preparePublicationV1(
            self.media_state.*,
            event,
            transform_receipt.output_sha256,
            resource_sha256,
        ) catch {
            scrubBuffers(source_slice, output_slice, mapping_slice);
            self.bank.abortPublication(permit) catch
                return Error.ResourceReceiptInvalid;
            return Error.PublicationFailed;
        };
        const generation = self.next_generation;
        self.next_generation += 1;
        self.phase = .prepared;
        self.active_generation = generation;
        self.active_permit = permit;
        self.active_transform_receipt = transform_receipt;
        self.active_publication = publication;
        self.active_event_sha256 = event_sha256;
        self.active_resource_sha256 = resource_sha256;
        self.active_fixture = encoded_fixture;
        self.active_transform_plan = encoded_transform_plan;
        self.active_decoded_source = source_slice;
        self.active_output = output_slice;
        self.active_mappings = mapping_slice;
        return .{
            .session = self,
            .generation = generation,
            .state = .prepared,
        };
    }

    pub fn closeAndRelease(self: *Session) Error!void {
        if (!self.initialized or self.receipt_owner != .session or
            self.phase != .idle or
            self.active_generation != 0 or
            self.active_permit != null)
            return Error.InvalidState;
        self.bank.closePublicationSession(
            self.receipt,
            self.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.bank.release(self.receipt) catch
            return Error.ResourceReceiptInvalid;
        self.initialized = false;
        self.phase = .closed;
    }

    /// Cancel scheduler-owned work that has not published media state.
    /// Session close and receipt release are one Bank transition.
    pub fn cancelScheduledV1(self: *Session) Error!qos.EventV1 {
        if (!self.scheduledReadyToFinish(false))
            return Error.InvalidState;
        const scheduler = self.scheduler orelse return Error.InvalidState;
        const handle = self.scheduled_handle orelse return Error.InvalidState;
        const event = scheduler.cancelBoundPublication(
            handle,
            self.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch |err| switch (err) {
            error.InvalidConfiguration => return Error.InvalidConfiguration,
            else => return Error.ResourceReceiptInvalid,
        };
        self.finishScheduledAssumeValid();
        return event;
    }

    /// Retire scheduler-owned work only after its one media publication and
    /// final service transition have both committed.
    pub fn retireScheduledV1(self: *Session) Error!qos.EventV1 {
        if (!self.scheduledReadyToFinish(true))
            return Error.InvalidState;
        const scheduler = self.scheduler orelse return Error.InvalidState;
        const handle = self.scheduled_handle orelse return Error.InvalidState;
        const event = scheduler.retireBoundPublication(
            handle,
            self.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch |err| switch (err) {
            error.InvalidConfiguration => return Error.InvalidConfiguration,
            else => return Error.ResourceReceiptInvalid,
        };
        self.finishScheduledAssumeValid();
        return event;
    }

    fn scheduledReadyToFinish(
        self: *const Session,
        require_published: bool,
    ) bool {
        return self.initialized and self.receipt_owner == .scheduler and
            self.phase == .idle and self.active_generation == 0 and
            self.active_permit == null and
            self.scheduler != null and self.scheduled_handle != null and
            self.published == require_published;
    }

    fn finishScheduledAssumeValid(self: *Session) void {
        self.initialized = false;
        self.phase = .closed;
        self.scheduler = null;
        self.scheduled_handle = null;
    }

    fn clearActive(self: *Session) void {
        self.phase = .idle;
        self.active_generation = 0;
        self.active_permit = null;
        self.active_transform_receipt = null;
        self.active_publication = null;
        self.active_event_sha256 = [_]u8{0} ** 32;
        self.active_resource_sha256 = [_]u8{0} ** 32;
        self.active_fixture = null;
        self.active_transform_plan = null;
        self.active_decoded_source = null;
        self.active_output = null;
        self.active_mappings = null;
    }
};

const TransactionState = enum {
    prepared,
    armed,
    committed,
    aborted,
};

const CommitCandidateV1 = struct {
    permit: resource_bank.PublicationPermit,
    state_after: media.PublicationStateV1,
    receipt: ExecutionReceiptV1,
};

pub const Transaction = struct {
    session: *Session,
    generation: u64,
    state: TransactionState,

    pub fn commit(self: *Transaction) Error!ExecutionReceiptV1 {
        const candidate = try self.preflightCommitV1();
        self.session.phase = .committing;
        self.finalizeCandidateAssumeValid(candidate);
        return candidate.receipt;
    }

    /// Freeze every fallible media-commit check against one already-armed
    /// LaneWeave service intent. The returned object must remain address-stable
    /// until its finalizer runs or `abort` is called. The Session, media state,
    /// provisional buffers, and Bank permit are single-owner and immutable
    /// across that bounded interval; violating this contract is process-fatal
    /// under `ServiceFinalizerV2`.
    pub fn armServiceV1(
        self: *Transaction,
        intent: qos.ServiceIntentV1,
    ) Error!ArmedScheduledTransactionV1 {
        if (!self.owns(.prepared))
            return Error.InvalidState;
        const session = self.session;
        const scheduler = session.scheduler orelse
            return Error.InvalidState;
        const handle = session.scheduled_handle orelse
            return Error.InvalidState;
        if (session.receipt_owner != .scheduler or
            !qos.serviceIntentValidV1(intent) or
            intent.scheduler_epoch != scheduler.config.scheduler_epoch or
            !std.meta.eql(intent.handle, handle) or
            !std.meta.eql(intent.spec.claim, session.admitted_claim) or
            !std.meta.eql(intent.resource_receipt, session.receipt) or
            intent.remaining_before != 1)
            return Error.InvalidConfiguration;
        const candidate = try self.preflightCommitV1();
        session.phase = .armed;
        self.state = .armed;
        return .{
            .transaction = self,
            .intent = intent,
            .candidate = candidate,
        };
    }

    pub fn abort(self: *Transaction) Error!void {
        if (!self.owns(.prepared))
            return Error.InvalidState;
        const permit = self.session.active_permit orelse
            return Error.InvalidState;
        try rollbackActiveV1(self.session, permit);
        self.state = .aborted;
    }

    fn preflightCommitV1(
        self: *Transaction,
    ) Error!CommitCandidateV1 {
        if (!self.owns(.prepared))
            return Error.InvalidState;
        const session = self.session;
        const permit = session.active_permit orelse
            return Error.InvalidState;
        const transform_receipt =
            session.active_transform_receipt orelse
            return Error.InvalidState;
        const publication = session.active_publication orelse
            return Error.InvalidState;
        const encoded_fixture = session.active_fixture orelse
            return Error.InvalidState;
        const encoded_transform_plan =
            session.active_transform_plan orelse
            return Error.InvalidState;
        const decoded_source = session.active_decoded_source orelse
            return Error.InvalidState;
        const output = session.active_output orelse
            return Error.InvalidState;
        const mappings = session.active_mappings orelse
            return Error.InvalidState;
        session.bank.validatePublication(permit) catch {
            try rollbackActiveV1(session, permit);
            self.state = .aborted;
            return Error.ResourceReceiptInvalid;
        };
        transform.verifyReceiptV1(
            encoded_fixture,
            encoded_transform_plan,
            transform_receipt,
            output,
            mappings,
        ) catch {
            try rollbackActiveV1(session, permit);
            self.state = .aborted;
            return Error.TransformFailed;
        };
        var state_after = session.media_state.*;
        media.commitPublicationV1(
            &state_after,
            publication,
        ) catch {
            try rollbackActiveV1(session, permit);
            self.state = .aborted;
            return Error.PublicationFailed;
        };
        const fixture = fixture_api.parseFixtureV1(
            encoded_fixture,
        ) catch unreachable;
        const plan = transform.decodeTransformPlanV1(
            encoded_transform_plan,
        ) catch unreachable;
        const receipt: ExecutionReceiptV1 = blk: {
            var value: ExecutionReceiptV1 = .{
                .operation = plan.operation,
                .kind = plan.kind,
                .request_epoch = session.request_epoch,
                .resource_sequence = permit.sequence,
                .media_sequence = publication.sequence,
                .logical_units = plan.logical_units,
                .output_bytes = plan.output_bytes,
                .mapping_count = plan.logical_units,
                .claim = session.receipt.claim,
                .resource_bank_epoch = session.receipt.bank_epoch,
                .resource_slot_index = session.receipt.slot_index,
                .resource_generation = session.receipt.generation,
                .resource_owner_key = session.receipt.owner_key,
                .resource_integrity = session.receipt.integrity,
                .fixture_sha256 = fixture.fixture_sha256,
                .transform_plan_sha256 = transform_receipt.transform_plan_sha256,
                .transform_receipt_sha256 = transform_receipt.receipt_sha256,
                .resource_claim_sha256 = session.active_resource_sha256,
                .timeline_event_sha256 = session.active_event_sha256,
                .publication_commit_sha256 = publication.commit_sha256,
                .output_sha256 = transform_receipt.output_sha256,
                .mapping_chain_sha256 = transform_receipt.mapping_chain_sha256,
                .receipt_sha256 = [_]u8{0} ** 32,
            };
            value.receipt_sha256 = executionReceiptRootV1(value);
            break :blk value;
        };
        verifyExecutionReceiptV1(
            session.media_state.*,
            encoded_fixture,
            encoded_transform_plan,
            transform_receipt,
            output,
            mappings,
            receipt,
        ) catch {
            try rollbackActiveV1(session, permit);
            self.state = .aborted;
            return Error.InvalidReceipt;
        };
        _ = decoded_source;
        return .{
            .permit = permit,
            .state_after = state_after,
            .receipt = receipt,
        };
    }

    fn finalizeCandidateAssumeValid(
        self: *Transaction,
        candidate: CommitCandidateV1,
    ) void {
        const session = self.session;
        session.media_state.* = candidate.state_after;
        session.bank.commitPublicationAssumeValid(candidate.permit);
        session.next_resource_sequence = candidate.permit.sequence + 1;
        session.published = true;
        session.clearActive();
        self.state = .committed;
    }

    fn owns(
        self: *const Transaction,
        expected: TransactionState,
    ) bool {
        const phase: SessionPhase = switch (expected) {
            .prepared => .prepared,
            .armed => .armed,
            .committed, .aborted => return false,
        };
        return self.state == expected and
            self.session.initialized and
            self.session.active_generation == self.generation and
            self.session.phase == phase;
    }
};

const ArmedScheduledState = enum {
    armed,
    committed,
    aborted,
};

/// In-process authority that joins one fully preflighted media publication to
/// one exact LaneWeave service event. `finalizer` is bounded and infallible;
/// caller-visible failures must happen before it is passed to the Scheduler.
pub const ArmedScheduledTransactionV1 = struct {
    transaction: *Transaction,
    intent: qos.ServiceIntentV1,
    candidate: CommitCandidateV1,
    state: ArmedScheduledState = .armed,
    committed_receipt: ?ExecutionReceiptV1 = null,
    service_event_sha256: Digest = [_]u8{0} ** 32,

    pub fn finalizer(self: *ArmedScheduledTransactionV1) qos.ServiceFinalizerV2 {
        const session = self.transaction.session;
        return .{
            .publication_request_epoch = session.request_epoch,
            .publication_session_id = @intFromPtr(session),
            .context = self,
            .finalize = finalize,
        };
    }

    pub fn executionReceiptV1(
        self: *const ArmedScheduledTransactionV1,
    ) Error!ExecutionReceiptV1 {
        if (self.state != .committed)
            return Error.InvalidState;
        return self.committed_receipt orelse Error.InvalidState;
    }

    /// Abort only the media publication permit and provisional buffers. The
    /// caller must separately consume the LaneWeave armed ticket with
    /// `abortArmedService`.
    pub fn abort(self: *ArmedScheduledTransactionV1) Error!void {
        if (self.state != .armed or
            !self.transaction.owns(.armed))
            return Error.InvalidState;
        try rollbackActiveV1(
            self.transaction.session,
            self.candidate.permit,
        );
        self.transaction.state = .aborted;
        self.state = .aborted;
    }

    fn finalize(
        context: *anyopaque,
        event: *const qos.EventV1,
    ) void {
        const self: *ArmedScheduledTransactionV1 =
            @ptrCast(@alignCast(context));
        if (self.state != .armed or
            !self.transaction.owns(.armed) or
            event.remaining_after != 0 or
            !qos.eventMatchesServiceIntentV1(event.*, self.intent))
            @panic("invalid armed media service finalization");
        self.transaction.finalizeCandidateAssumeValid(self.candidate);
        self.committed_receipt = self.candidate.receipt;
        self.service_event_sha256 = event.event_sha256;
        self.state = .committed;
    }
};

fn validateSessionInputV1(
    request_epoch: u64,
    publication_state: *const media.PublicationStateV1,
    encoded_fixture: []const u8,
    encoded_transform_plan: []const u8,
) Error!ValidatedSessionInputV1 {
    if (request_epoch == 0 or
        publication_state.request_epoch != request_epoch)
        return Error.InvalidConfiguration;
    const fixture = fixture_api.parseFixtureV1(
        encoded_fixture,
    ) catch return Error.TransformFailed;
    const plan = transform.decodeTransformPlanV1(
        encoded_transform_plan,
    ) catch return Error.TransformFailed;
    const plan_sha256 = transform.transformPlanSha256V1(
        encoded_transform_plan,
    ) catch return Error.TransformFailed;
    if (!std.mem.eql(
        u8,
        &publication_state.media_object_sha256,
        &plan.media_object_sha256,
    ) or
        !std.mem.eql(
            u8,
            &fixture.media_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.meta.eql(
            publication_state.timeline_base,
            outputTimelineBaseV1(plan),
        ))
        return Error.InvalidConfiguration;
    return .{
        .claim = try claimForExecutionV1(encoded_fixture.len, plan),
        .fixture_sha256 = fixture.fixture_sha256,
        .plan_sha256 = plan_sha256,
    };
}

fn rollbackActiveV1(
    session: *Session,
    permit: resource_bank.PublicationPermit,
) Error!void {
    const source = session.active_decoded_source orelse
        return Error.InvalidState;
    const output = session.active_output orelse
        return Error.InvalidState;
    const mappings = session.active_mappings orelse
        return Error.InvalidState;
    scrubBuffers(source, output, mappings);
    session.bank.abortPublication(permit) catch
        return Error.ResourceReceiptInvalid;
    session.clearActive();
}

fn validateExecutionReceiptV1(
    receipt: ExecutionReceiptV1,
) Error!void {
    if (receipt.request_epoch == 0 or
        receipt.resource_sequence != 0 or
        receipt.media_sequence == 0 or
        receipt.logical_units == 0 or
        receipt.output_bytes == 0 or
        receipt.mapping_count != receipt.logical_units or
        receipt.claim.isZero() or
        receipt.claim.queue_slots != 1 or
        receipt.claim.kv_bytes != 0 or
        receipt.claim.partial_bytes != 0 or
        receipt.claim.logits_bytes != 0 or
        receipt.claim.device_bytes != 0 or
        receipt.claim.output_journal_bytes != receipt.output_bytes or
        receipt.resource_bank_epoch == 0 or
        receipt.resource_generation == 0 or
        receipt.resource_owner_key == 0 or
        receipt.resource_integrity == 0 or
        isZero(receipt.fixture_sha256) or
        isZero(receipt.transform_plan_sha256) or
        isZero(receipt.transform_receipt_sha256) or
        isZero(receipt.resource_claim_sha256) or
        isZero(receipt.timeline_event_sha256) or
        isZero(receipt.publication_commit_sha256) or
        isZero(receipt.output_sha256) or
        isZero(receipt.mapping_chain_sha256) or
        isZero(receipt.receipt_sha256) or
        !std.mem.eql(
            u8,
            &receipt.receipt_sha256,
            &executionReceiptRootV1(receipt),
        ))
        return Error.InvalidReceipt;
    const minimum_staging = checkedMul(
        receipt.mapping_count,
        mapping_accounting_bytes,
    ) catch return Error.InvalidReceipt;
    if (receipt.claim.staging_bytes < minimum_staging)
        return Error.InvalidReceipt;
}

fn writeReceiptBodyV1(
    receipt: ExecutionReceiptV1,
    body: []u8,
) void {
    std.debug.assert(body.len == receipt_body_bytes);
    @memset(body, 0);
    @memcpy(body[0..8], &receipt_magic);
    writeU64(body, 8, receipt_abi);
    writeU64(body, 16, receipt_bytes);
    writeU64(body, 24, allowed_flags);
    writeU64(body, 32, @intFromEnum(receipt.operation));
    writeU64(body, 40, @intFromEnum(receipt.kind));
    writeU64(body, 48, receipt.request_epoch);
    writeU64(body, 56, receipt.resource_sequence);
    writeU64(body, 64, receipt.media_sequence);
    writeU64(body, 72, receipt.logical_units);
    writeU64(body, 80, receipt.output_bytes);
    writeU64(body, 88, receipt.mapping_count);
    writeClaim(body, 96, receipt.claim);
    writeU64(body, 176, receipt.resource_bank_epoch);
    writeU64(body, 184, receipt.resource_slot_index);
    writeU64(body, 192, receipt.resource_generation);
    writeU64(body, 200, receipt.resource_owner_key);
    writeU64(body, 208, receipt.resource_integrity);
    @memcpy(body[216..248], &receipt.fixture_sha256);
    @memcpy(body[248..280], &receipt.transform_plan_sha256);
    @memcpy(body[280..312], &receipt.transform_receipt_sha256);
    @memcpy(body[312..344], &receipt.resource_claim_sha256);
    @memcpy(body[344..376], &receipt.timeline_event_sha256);
    @memcpy(body[376..408], &receipt.publication_commit_sha256);
    @memcpy(body[408..440], &receipt.output_sha256);
    @memcpy(body[440..472], &receipt.mapping_chain_sha256);
}

fn writeClaim(
    output: []u8,
    offset: usize,
    claim: resource_bank.Claim,
) void {
    writeU64(output, offset, claim.capsule_bytes);
    writeU64(output, offset + 8, claim.kv_bytes);
    writeU64(output, offset + 16, claim.activation_bytes);
    writeU64(output, offset + 24, claim.partial_bytes);
    writeU64(output, offset + 32, claim.logits_bytes);
    writeU64(output, offset + 40, claim.output_journal_bytes);
    writeU64(output, offset + 48, claim.staging_bytes);
    writeU64(output, offset + 56, claim.device_bytes);
    writeU64(output, offset + 64, claim.io_bytes);
    writeU64(output, offset + 72, claim.queue_slots);
}

fn readClaim(input: []const u8, offset: usize) resource_bank.Claim {
    return .{
        .capsule_bytes = readU64(input, offset),
        .kv_bytes = readU64(input, offset + 8),
        .activation_bytes = readU64(input, offset + 16),
        .partial_bytes = readU64(input, offset + 24),
        .logits_bytes = readU64(input, offset + 32),
        .output_journal_bytes = readU64(input, offset + 40),
        .staging_bytes = readU64(input, offset + 48),
        .device_bytes = readU64(input, offset + 56),
        .io_bytes = readU64(input, offset + 64),
        .queue_slots = readU64(input, offset + 72),
    };
}

fn outputTimelineBaseV1(
    plan: transform.TransformPlanV1,
) media.TimeBaseV1 {
    return switch (plan.kind) {
        .image => .{ .numerator = 1, .denominator = 1 },
        .audio, .video => plan.target_time_base,
    };
}

fn sourceSpanV1(
    plan: transform.TransformPlanV1,
) Error!media.SpanV1 {
    const values = switch (plan.operation) {
        .image_crop_nearest_tile => blk: {
            const first = checkedAdd(
                try checkedMul(
                    plan.parameters[1],
                    plan.source_axes[0],
                ),
                plan.parameters[0],
            ) catch return Error.ArithmeticOverflow;
            const last_row = checkedAdd(
                plan.parameters[1],
                plan.parameters[3] - 1,
            ) catch return Error.ArithmeticOverflow;
            const last_column = checkedAdd(
                plan.parameters[0],
                plan.parameters[2],
            ) catch return Error.ArithmeticOverflow;
            const end = checkedAdd(
                try checkedMul(last_row, plan.source_axes[0]),
                last_column,
            ) catch return Error.ArithmeticOverflow;
            break :blk .{
                first,
                end,
                media.TimeBaseV1{
                    .numerator = 1,
                    .denominator = 1,
                },
            };
        },
        .audio_mix_decimate => .{
            plan.parameters[0],
            checkedAdd(
                plan.parameters[0],
                plan.parameters[1],
            ) catch return Error.ArithmeticOverflow,
            plan.source_time_base,
        },
        .video_keyframe_select => blk: {
            const count: usize = @intCast(plan.parameters[0]);
            var first = plan.parameters[1];
            var last = first;
            for (plan.parameters[2 .. count + 1]) |frame| {
                first = @min(first, frame);
                last = @max(last, frame);
            }
            break :blk .{
                first,
                checkedAdd(last, 1) catch
                    return Error.ArithmeticOverflow,
                plan.source_time_base,
            };
        },
    };
    return .{
        .start = .{
            .ticks = values[0],
            .base = values[2],
        },
        .end = .{
            .ticks = values[1],
            .base = values[2],
        },
    };
}

fn scrubBuffers(
    source: []u8,
    output: []u8,
    mappings: []transform.TransformMappingV1,
) void {
    @memset(source, 0);
    @memset(output, 0);
    @memset(
        std.mem.sliceAsBytes(mappings),
        0,
    );
}

fn checkedAdd(a: anytype, b: anytype) Error!u64 {
    return std.math.add(
        u64,
        @intCast(a),
        @intCast(b),
    ) catch Error.ArithmeticOverflow;
}

fn checkedMul(a: anytype, b: anytype) Error!u64 {
    return std.math.mul(
        u64,
        @intCast(a),
        @intCast(b),
    ) catch Error.ArithmeticOverflow;
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    @memcpy(output[offset .. offset + 8], &bytes);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    hashU64(hash, claim.capsule_bytes);
    hashU64(hash, claim.kv_bytes);
    hashU64(hash, claim.activation_bytes);
    hashU64(hash, claim.partial_bytes);
    hashU64(hash, claim.logits_bytes);
    hashU64(hash, claim.output_journal_bytes);
    hashU64(hash, claim.staging_bytes);
    hashU64(hash, claim.device_bytes);
    hashU64(hash, claim.io_bytes);
    hashU64(hash, claim.queue_slots);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

const TestContext = ReferenceInputV1;

pub fn prepareReferenceInputV1(
    kind: media.MediaKindV1,
    storage: *ReferenceInputStorageV1,
) Error!ReferenceInputV1 {
    return prepareReferenceInputIntoV1(
        kind,
        &storage.fixture,
        &storage.decode_plan,
        &storage.transform_plan,
        &storage.decoded_for_plan,
    );
}

fn prepareTestContext(
    case_index: usize,
    fixture_storage: *[fixture_api.maximum_fixture_bytes]u8,
    decode_plan_storage: *[decode_plan.plan_bytes]u8,
    transform_plan_storage: *[transform.transform_plan_bytes]u8,
    decoded: *[fixture_api.maximum_payload_bytes]u8,
) !TestContext {
    const kind: media.MediaKindV1 = switch (case_index) {
        0 => .image,
        1 => .audio,
        2 => .video,
        else => unreachable,
    };
    return prepareReferenceInputIntoV1(
        kind,
        fixture_storage,
        decode_plan_storage,
        transform_plan_storage,
        decoded,
    );
}

fn prepareReferenceInputIntoV1(
    kind: media.MediaKindV1,
    fixture_storage: *[fixture_api.maximum_fixture_bytes]u8,
    decode_plan_storage: *[decode_plan.plan_bytes]u8,
    transform_plan_storage: *[transform.transform_plan_bytes]u8,
    decoded: *[fixture_api.maximum_payload_bytes]u8,
) Error!ReferenceInputV1 {
    const spec = switch (kind) {
        .image => fixture_api.imageSpecV1(),
        .audio => fixture_api.audioSpecV1(),
        .video => fixture_api.videoSpecV1(),
    };
    const encoded_fixture = fixture_api.encodeFixtureV1(
        spec,
        fixture_storage,
    ) catch return Error.TransformFailed;
    const fixture = fixture_api.parseFixtureV1(
        encoded_fixture,
    ) catch return Error.TransformFailed;
    const plan = fixture_api.makeDecodePlanV1(
        fixture,
        [_]u8{0xd1} ** 32,
        [_]u8{0xe1} ** 32,
    ) catch return Error.TransformFailed;
    const encoded_decode_plan = decode_plan.encodePlanV1(
        plan,
        decode_plan_storage,
    ) catch return Error.TransformFailed;
    const decode_receipt = fixture_api.decodeFixtureV1(
        encoded_fixture,
        encoded_decode_plan,
        decoded,
    ) catch return Error.TransformFailed;
    const transform_plan = switch (kind) {
        .image => transform.makeImagePlanV1(
            fixture,
            decode_receipt,
            1,
            0,
            1,
            2,
            2,
            2,
            1,
            1,
            [_]u8{0xf1} ** 32,
            [_]u8{0xf2} ** 32,
        ) catch return Error.TransformFailed,
        .audio => transform.makeAudioPlanV1(
            fixture,
            decode_receipt,
            0,
            6,
            16_000,
            1,
            0,
            1,
            [_]u8{0xf1} ** 32,
            [_]u8{0xf2} ** 32,
        ) catch return Error.TransformFailed,
        .video => blk: {
            const selected = [_]u64{1};
            break :blk transform.makeVideoPlanV1(
                fixture,
                decode_receipt,
                &selected,
                [_]u8{0xf1} ** 32,
                [_]u8{0xf2} ** 32,
            ) catch return Error.TransformFailed;
        },
    };
    const encoded_transform_plan =
        transform.encodeTransformPlanV1(
            transform_plan,
            transform_plan_storage,
        ) catch return Error.TransformFailed;
    if (transform_plan.logical_units > reference_maximum_mappings or
        transform_plan.source_bytes > reference_maximum_payload_bytes or
        transform_plan.output_bytes > reference_maximum_payload_bytes)
        return Error.InvalidConfiguration;
    const expected_output: []const u8 = switch (kind) {
        .image => &[_]u8{
            0,   255, 0,   0,   255, 0,
            255, 255, 255, 255, 255, 255,
        },
        .audio => &[_]u8{ 0x00, 0xc0, 0x55, 0x15 },
        .video => &[_]u8{ 255, 128, 64, 0 },
    };
    return .{
        .encoded_fixture = encoded_fixture,
        .fixture = fixture,
        .encoded_decode_plan = encoded_decode_plan,
        .decode_receipt = decode_receipt,
        .transform_plan = transform_plan,
        .encoded_transform_plan = encoded_transform_plan,
        .expected_output = expected_output,
        .timeline_base = outputTimelineBaseV1(transform_plan),
    };
}

test "scheduled runtime adopts one receipt and commits every media kind" {
    const kinds = [_]media.MediaKindV1{ .image, .audio, .video };
    for (kinds, 0..) |kind, case_index| {
        var reference_storage: ReferenceInputStorageV1 = .{};
        const context = try prepareReferenceInputV1(
            kind,
            &reference_storage,
        );
        const claim = try claimForExecutionV1(
            context.encoded_fixture.len,
            context.transform_plan,
        );
        var bank_slots = [_]resource_bank.Slot{.{}};
        var bank = try resource_bank.Bank.init(
            &bank_slots,
            try limitsForClaimV1(claim),
            0x9000 + case_index,
        );
        var lane_slots = [_]qos.Slot{.{}};
        var projection = [_]qos.ProjectionSlot{.{}};
        var challenge = [_]u8{0} ** 32;
        challenge[0] = @intCast(0xa0 + case_index);
        var scheduler = try qos.Scheduler.init(
            &bank,
            .{
                .slots = &lane_slots,
                .projection = &projection,
            },
            .{
                .scheduler_epoch = 0xa000 + case_index,
                .challenge = challenge,
                .max_weight = 1,
                .max_projection_quanta = 8,
                .max_projection_operations = 64,
            },
        );
        const owner_key: u64 = 0xb000 + case_index;
        const request_epoch: u64 = 0xc000 + case_index;
        const decision = try scheduler.admit(.{
            .tenant_key = 0xd000 + case_index,
            .request_key = 0xe000 + case_index,
            .request_generation = 1,
            .resource_owner_key = owner_key,
            .weight = 1,
            .work_quanta = 1,
            .deadline_tick = 8,
            .claim = claim,
        });
        const admission = switch (decision) {
            .admitted => |value| value,
            .rejected => return Error.ResourceAdmissionFailed,
        };
        var previous_commit = [_]u8{0} ** 32;
        previous_commit[0] = @intCast(0xf0 + case_index);
        var publication_state =
            try media.initializePublicationStateV1(
                request_epoch,
                1,
                context.timeline_base,
                context.fixture.media_object_sha256,
                previous_commit,
            );
        const state_before = publication_state;
        const bank_before_adopt = try bank.snapshot();
        var session: Session = .{};
        try session.initScheduledV1(
            &scheduler,
            admission,
            request_epoch,
            &publication_state,
            context.encoded_fixture,
            context.encoded_transform_plan,
        );
        try std.testing.expectEqualDeep(
            bank_before_adopt,
            try bank.snapshot(),
        );
        try std.testing.expectError(
            Error.InvalidState,
            session.closeAndRelease(),
        );

        var decoded = [_]u8{0} ** fixture_api.maximum_payload_bytes;
        var output = [_]u8{0} ** fixture_api.maximum_payload_bytes;
        var mappings: [reference_maximum_mappings]transform.TransformMappingV1 =
            undefined;
        const service_permit = try scheduler.prepareService();
        var transaction = try session.prepare(
            context.encoded_fixture,
            context.encoded_decode_plan,
            context.encoded_transform_plan,
            &decoded,
            &output,
            &mappings,
        );
        const transform_receipt =
            session.active_transform_receipt orelse
            return Error.InvalidState;
        const armed_service =
            try scheduler.armServiceCommit(service_permit);
        var armed_media = try transaction.armServiceV1(
            armed_service.intent,
        );
        const service_event = try scheduler.commitArmedServiceV2(
            armed_service.ticket,
            armed_media.finalizer(),
        );
        try std.testing.expect(qos.eventMatchesServiceIntentV1(
            service_event,
            armed_service.intent,
        ));
        const execution_receipt =
            try armed_media.executionReceiptV1();
        try std.testing.expectEqual(
            @as(u64, 0),
            service_event.remaining_after,
        );
        try std.testing.expectEqualDeep(
            admission.event.resource_receipt.claim,
            execution_receipt.claim,
        );
        try std.testing.expectEqual(
            admission.event.resource_receipt.slot_index,
            execution_receipt.resource_slot_index,
        );
        try std.testing.expectEqual(
            admission.event.resource_receipt.generation,
            execution_receipt.resource_generation,
        );
        try std.testing.expectEqual(
            admission.event.resource_receipt.owner_key,
            execution_receipt.resource_owner_key,
        );
        const output_bytes: usize =
            @intCast(execution_receipt.output_bytes);
        const mapping_count: usize =
            @intCast(execution_receipt.mapping_count);
        try std.testing.expectEqualSlices(
            u8,
            context.expected_output,
            output[0..output_bytes],
        );
        try verifyExecutionReceiptV1(
            state_before,
            context.encoded_fixture,
            context.encoded_transform_plan,
            transform_receipt,
            output[0..output_bytes],
            mappings[0..mapping_count],
            execution_receipt,
        );

        const retire_event = try session.retireScheduledV1();
        try std.testing.expectEqual(qos.EventKind.retire, retire_event.kind);
        _ = try scheduler.close();
        const final = try bank.snapshot();
        try std.testing.expect(final.used.isZero());
        try std.testing.expectEqual(@as(usize, 0), final.committed_receipts);
        try std.testing.expectEqual(@as(u64, 1), final.successful_commits);
        try std.testing.expectEqual(@as(u64, 1), final.releases);
        try std.testing.expectEqual(
            try claim.hostBytes(),
            final.peak_host_bytes,
        );
    }
}

test "scheduled adoption rejects claim drift and bound cancellation is atomic" {
    var reference_storage: ReferenceInputStorageV1 = .{};
    const context = try prepareReferenceInputV1(
        .image,
        &reference_storage,
    );
    const exact_claim = try claimForExecutionV1(
        context.encoded_fixture.len,
        context.transform_plan,
    );
    var bank_slots = [_]resource_bank.Slot{.{}};
    var limits = try limitsForClaimV1(exact_claim);
    limits.host_bytes += 1;
    limits.activation_bytes += 1;
    var bank = try resource_bank.Bank.init(&bank_slots, limits, 0x9100);
    var lane_slots = [_]qos.Slot{.{}};
    var projection = [_]qos.ProjectionSlot{.{}};
    var challenge = [_]u8{0} ** 32;
    challenge[0] = 0xa1;
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &lane_slots,
            .projection = &projection,
        },
        .{
            .scheduler_epoch = 0xa100,
            .challenge = challenge,
            .max_weight = 1,
            .max_projection_quanta = 16,
            .max_projection_operations = 64,
        },
    );
    const request_epoch: u64 = 0xc100;
    const previous_commit = [_]u8{0xaa} ** 32;
    var publication_state =
        try media.initializePublicationStateV1(
            request_epoch,
            1,
            context.timeline_base,
            context.fixture.media_object_sha256,
            previous_commit,
        );
    const state_before = publication_state;

    var drift_claim = exact_claim;
    drift_claim.activation_bytes += 1;
    const drift_decision = try scheduler.admit(.{
        .tenant_key = 1,
        .request_key = 10,
        .request_generation = 1,
        .resource_owner_key = 100,
        .weight = 1,
        .work_quanta = 2,
        .deadline_tick = 8,
        .claim = drift_claim,
    });
    const drift_admission = switch (drift_decision) {
        .admitted => |value| value,
        .rejected => return Error.ResourceAdmissionFailed,
    };
    var rejected_session: Session = .{};
    try std.testing.expectError(
        Error.InvalidConfiguration,
        rejected_session.initScheduledV1(
            &scheduler,
            drift_admission,
            request_epoch,
            &publication_state,
            context.encoded_fixture,
            context.encoded_transform_plan,
        ),
    );
    _ = try scheduler.cancel(drift_admission.handle);

    const exact_decision = try scheduler.admit(.{
        .tenant_key = 1,
        .request_key = 10,
        .request_generation = 2,
        .resource_owner_key = 100,
        .weight = 1,
        .work_quanta = 2,
        .deadline_tick = 8,
        .claim = exact_claim,
    });
    const exact_admission = switch (exact_decision) {
        .admitted => |value| value,
        .rejected => return Error.ResourceAdmissionFailed,
    };
    var session: Session = .{};
    try session.initScheduledV1(
        &scheduler,
        exact_admission,
        request_epoch,
        &publication_state,
        context.encoded_fixture,
        context.encoded_transform_plan,
    );
    const scheduler_before = try scheduler.snapshot();
    const bank_before = try bank.snapshot();
    session.next_resource_sequence = 1;
    try std.testing.expectError(
        Error.ResourceReceiptInvalid,
        session.cancelScheduledV1(),
    );
    try std.testing.expectEqualDeep(
        scheduler_before,
        try scheduler.snapshot(),
    );
    try std.testing.expectEqualDeep(bank_before, try bank.snapshot());

    session.next_resource_sequence = 0;
    const cancel_event = try session.cancelScheduledV1();
    try std.testing.expectEqual(qos.EventKind.cancel, cancel_event.kind);
    try std.testing.expectEqualDeep(state_before, publication_state);
    _ = try scheduler.close();
    const final = try bank.snapshot();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(@as(u64, 2), final.successful_commits);
    try std.testing.expectEqual(@as(u64, 2), final.releases);
}

test "armed scheduled media drift aborts both coordinators and retries exactly" {
    var reference_storage: ReferenceInputStorageV1 = .{};
    const context = try prepareReferenceInputV1(
        .image,
        &reference_storage,
    );
    const claim = try claimForExecutionV1(
        context.encoded_fixture.len,
        context.transform_plan,
    );
    var bank_slots = [_]resource_bank.Slot{.{}};
    var bank = try resource_bank.Bank.init(
        &bank_slots,
        try limitsForClaimV1(claim),
        0x9200,
    );
    var lane_slots = [_]qos.Slot{.{}};
    var projection = [_]qos.ProjectionSlot{.{}};
    var challenge = [_]u8{0} ** 32;
    challenge[0] = 0xa2;
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &lane_slots,
            .projection = &projection,
        },
        .{
            .scheduler_epoch = 0xa200,
            .challenge = challenge,
            .max_weight = 1,
            .max_projection_quanta = 8,
            .max_projection_operations = 64,
        },
    );
    const request_epoch: u64 = 0xc200;
    const decision = try scheduler.admit(.{
        .tenant_key = 2,
        .request_key = 20,
        .request_generation = 1,
        .resource_owner_key = 200,
        .weight = 1,
        .work_quanta = 1,
        .deadline_tick = 8,
        .claim = claim,
    });
    const admission = switch (decision) {
        .admitted => |value| value,
        .rejected => return Error.ResourceAdmissionFailed,
    };
    const previous_commit = [_]u8{0xab} ** 32;
    var publication_state =
        try media.initializePublicationStateV1(
            request_epoch,
            1,
            context.timeline_base,
            context.fixture.media_object_sha256,
            previous_commit,
        );
    const state_before = publication_state;
    var session: Session = .{};
    try session.initScheduledV1(
        &scheduler,
        admission,
        request_epoch,
        &publication_state,
        context.encoded_fixture,
        context.encoded_transform_plan,
    );
    const scheduler_before = try scheduler.snapshot();
    const bank_before = try bank.snapshot();

    var decoded = [_]u8{0} ** fixture_api.maximum_payload_bytes;
    var output = [_]u8{0} ** fixture_api.maximum_payload_bytes;
    var mappings: [reference_maximum_mappings]transform.TransformMappingV1 =
        undefined;
    const first_permit = try scheduler.prepareService();
    var first_transaction = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
    );
    const first_armed = try scheduler.armServiceCommit(first_permit);
    output[0] ^= 1;
    try std.testing.expectError(
        Error.TransformFailed,
        first_transaction.armServiceV1(first_armed.intent),
    );
    try scheduler.abortArmedService(first_armed.ticket);
    try std.testing.expect(std.mem.allEqual(
        u8,
        output[0..context.transform_plan.output_bytes],
        0,
    ));
    try std.testing.expectEqualDeep(state_before, publication_state);
    try std.testing.expectEqualDeep(
        scheduler_before,
        try scheduler.snapshot(),
    );
    try std.testing.expectEqualDeep(bank_before, try bank.snapshot());

    const retry_permit = try scheduler.prepareService();
    try std.testing.expectEqualDeep(
        first_permit.state_before_sha256,
        retry_permit.state_before_sha256,
    );
    var retry_transaction = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
    );
    const retry_armed = try scheduler.armServiceCommit(retry_permit);
    try std.testing.expectEqualDeep(
        first_armed.intent,
        retry_armed.intent,
    );
    var armed_media = try retry_transaction.armServiceV1(
        retry_armed.intent,
    );
    _ = try scheduler.commitArmedServiceV2(
        retry_armed.ticket,
        armed_media.finalizer(),
    );
    _ = try armed_media.executionReceiptV1();
    _ = try session.retireScheduledV1();
    _ = try scheduler.close();
    const final = try bank.snapshot();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(@as(u64, 1), final.successful_commits);
    try std.testing.expectEqual(@as(u64, 1), final.releases);
}

test "runtime admits commits and releases image audio and video exactly" {
    var roots: [3]Digest = undefined;
    for (0..3) |case_index| {
        var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
            undefined;
        var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
        var transform_plan_storage: [transform.transform_plan_bytes]u8 =
            undefined;
        var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
            undefined;
        const context = try prepareTestContext(
            case_index,
            &fixture_storage,
            &decode_plan_storage,
            &transform_plan_storage,
            &decoded_for_plan,
        );
        const claim = try claimForExecutionV1(
            context.encoded_fixture.len,
            context.transform_plan,
        );
        var slots = [_]resource_bank.Slot{.{}};
        var bank = try resource_bank.Bank.init(
            &slots,
            try limitsForClaimV1(claim),
            800 + case_index,
        );
        const request_epoch: u64 = 900 + case_index;
        var publication_state =
            try media.initializePublicationStateV1(
                request_epoch,
                1,
                context.timeline_base,
                context.fixture.media_object_sha256,
                [_]u8{@intCast(0xa0 + case_index)} ** 32,
            );
        const state_before = publication_state;
        var session: Session = .{};
        try session.init(
            &bank,
            700 + case_index,
            request_epoch,
            &publication_state,
            context.encoded_fixture,
            context.encoded_transform_plan,
        );
        try std.testing.expect(std.meta.eql(
            claim,
            (try bank.snapshot()).used,
        ));
        var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
        var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
        var mappings: [4]transform.TransformMappingV1 = undefined;
        var transaction = try session.prepare(
            context.encoded_fixture,
            context.encoded_decode_plan,
            context.encoded_transform_plan,
            &decoded,
            &output,
            &mappings,
        );
        const transform_receipt =
            session.active_transform_receipt orelse
            return Error.InvalidState;
        try std.testing.expect(std.meta.eql(
            state_before,
            publication_state,
        ));
        const receipt = try transaction.commit();
        const output_bytes: usize = @intCast(receipt.output_bytes);
        const mapping_count: usize = @intCast(receipt.mapping_count);
        try std.testing.expectEqualSlices(
            u8,
            context.expected_output,
            output[0..output_bytes],
        );
        try std.testing.expectEqual(@as(u64, 1), publication_state.visible_chunks);
        try std.testing.expectEqual(
            context.transform_plan.logical_units,
            publication_state.visible_units,
        );
        try verifyExecutionReceiptV1(
            state_before,
            context.encoded_fixture,
            context.encoded_transform_plan,
            transform_receipt,
            output[0..output_bytes],
            mappings[0..mapping_count],
            receipt,
        );
        var receipt_storage: [receipt_bytes]u8 = undefined;
        const encoded = try encodeExecutionReceiptV1(
            receipt,
            &receipt_storage,
        );
        try std.testing.expect(std.meta.eql(
            receipt,
            try decodeExecutionReceiptV1(encoded),
        ));
        roots[case_index] = receipt.receipt_sha256;
        try session.closeAndRelease();
        const snapshot = try bank.snapshot();
        try std.testing.expect(snapshot.used.isZero());
        try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
    }
    const expected = [_][]const u8{
        "4fd2368c0b7a34db2e69b378ca43fb87354a0363e27f0b58a63e1eda49b3b711",
        "a636e11e16f55a6fa1bf9ee6bfc1b7e5add14bf077b0afd913e11bd01dfb6025",
        "7b9f97e839e9b0f85bb361d634c695f73eb3b0d49316668ecea81c050d33eebb",
    };
    for (roots, expected) |root, expected_hex| {
        const actual_hex = std.fmt.bytesToHex(root, .lower);
        try std.testing.expectEqualStrings(expected_hex, &actual_hex);
    }
}

test "runtime abort and failed candidate verification scrub provisional bytes" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var transform_plan_storage: [transform.transform_plan_bytes]u8 =
        undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        1,
        &fixture_storage,
        &decode_plan_storage,
        &transform_plan_storage,
        &decoded_for_plan,
    );
    const claim = try claimForExecutionV1(
        context.encoded_fixture.len,
        context.transform_plan,
    );
    var slots = [_]resource_bank.Slot{.{}};
    var bank = try resource_bank.Bank.init(
        &slots,
        try limitsForClaimV1(claim),
        1201,
    );
    var publication_state = try media.initializePublicationStateV1(
        1202,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xb1} ** 32,
    );
    const state_before = publication_state;
    var session: Session = .{};
    try session.init(
        &bank,
        1203,
        1202,
        &publication_state,
        context.encoded_fixture,
        context.encoded_transform_plan,
    );
    var decoded = [_]u8{0x5a} ** fixture_api.maximum_payload_bytes;
    var output = [_]u8{0x5a} ** fixture_api.maximum_payload_bytes;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var first = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
    );
    try first.abort();
    try std.testing.expect(std.mem.allEqual(
        u8,
        decoded[0..context.transform_plan.source_bytes],
        0,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        output[0..context.transform_plan.output_bytes],
        0,
    ));
    try std.testing.expect(std.meta.eql(
        state_before,
        publication_state,
    ));

    @memset(&decoded, 0x5a);
    @memset(&output, 0x5a);
    @memset(std.mem.asBytes(&mappings), 0x5a);
    var invalid_decode_plan: [decode_plan.plan_bytes]u8 = undefined;
    @memcpy(
        &invalid_decode_plan,
        context.encoded_decode_plan,
    );
    invalid_decode_plan[0] ^= 1;
    try std.testing.expectError(
        Error.TransformFailed,
        session.prepare(
            context.encoded_fixture,
            &invalid_decode_plan,
            context.encoded_transform_plan,
            &decoded,
            &output,
            &mappings,
        ),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        decoded[0..context.transform_plan.source_bytes],
        0,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        output[0..context.transform_plan.output_bytes],
        0,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        std.mem.sliceAsBytes(mappings[0..context.transform_plan.logical_units]),
        0,
    ));

    var second = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
    );
    output[0] ^= 1;
    try std.testing.expectError(
        Error.TransformFailed,
        second.commit(),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        output[0..context.transform_plan.output_bytes],
        0,
    ));
    try std.testing.expect(std.meta.eql(
        state_before,
        publication_state,
    ));

    var poisoned = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
    );
    const valid_permit = session.active_permit.?;
    session.active_permit.?.integrity ^= 1;
    try std.testing.expectError(
        Error.ResourceReceiptInvalid,
        poisoned.commit(),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        decoded[0..context.transform_plan.source_bytes],
        0,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        output[0..context.transform_plan.output_bytes],
        0,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        std.mem.sliceAsBytes(mappings[0..context.transform_plan.logical_units]),
        0,
    ));
    session.active_permit = valid_permit;
    session.phase = .prepared;
    try poisoned.abort();

    var third = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
    );
    var copied = third;
    _ = try third.commit();
    try std.testing.expectError(Error.InvalidState, copied.commit());
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "runtime rejects capacity plan substitution and short output atomically" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var transform_plan_storage: [transform.transform_plan_bytes]u8 =
        undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        0,
        &fixture_storage,
        &decode_plan_storage,
        &transform_plan_storage,
        &decoded_for_plan,
    );
    const claim = try claimForExecutionV1(
        context.encoded_fixture.len,
        context.transform_plan,
    );
    var tight_limits = try limitsForClaimV1(claim);
    tight_limits.host_bytes -= 1;
    var rejected_slots = [_]resource_bank.Slot{.{}};
    var rejected_bank = try resource_bank.Bank.init(
        &rejected_slots,
        tight_limits,
        1301,
    );
    var rejected_state = try media.initializePublicationStateV1(
        1302,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xc1} ** 32,
    );
    var rejected_session: Session = .{};
    try std.testing.expectError(
        Error.ResourceAdmissionFailed,
        rejected_session.init(
            &rejected_bank,
            1303,
            1302,
            &rejected_state,
            context.encoded_fixture,
            context.encoded_transform_plan,
        ),
    );
    try std.testing.expect((try rejected_bank.snapshot()).used.isZero());

    var slots = [_]resource_bank.Slot{.{}};
    var bank = try resource_bank.Bank.init(
        &slots,
        try limitsForClaimV1(claim),
        1304,
    );
    var state = try media.initializePublicationStateV1(
        1305,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xc2} ** 32,
    );
    const state_before = state;
    var session: Session = .{};
    try session.init(
        &bank,
        1306,
        1305,
        &state,
        context.encoded_fixture,
        context.encoded_transform_plan,
    );
    const alternate_plan = try transform.makeImagePlanV1(
        context.fixture,
        context.decode_receipt,
        0,
        0,
        1,
        2,
        2,
        2,
        1,
        1,
        [_]u8{0xf1} ** 32,
        [_]u8{0xf2} ** 32,
    );
    var alternate_storage: [transform.transform_plan_bytes]u8 = undefined;
    const alternate_encoded = try transform.encodeTransformPlanV1(
        alternate_plan,
        &alternate_storage,
    );
    var decoded = [_]u8{0x5a} ** fixture_api.maximum_payload_bytes;
    var output = [_]u8{0x5a} ** fixture_api.maximum_payload_bytes;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    try std.testing.expectError(
        Error.InvalidConfiguration,
        session.prepare(
            context.encoded_fixture,
            context.encoded_decode_plan,
            alternate_encoded,
            &decoded,
            &output,
            &mappings,
        ),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        output[0..context.transform_plan.output_bytes],
        0x5a,
    ));
    var short_output = [_]u8{0x5a} ** 11;
    try std.testing.expectError(
        Error.BufferTooSmall,
        session.prepare(
            context.encoded_fixture,
            context.encoded_decode_plan,
            context.encoded_transform_plan,
            &decoded,
            &short_output,
            &mappings,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &short_output, 0x5a));
    try std.testing.expect(std.meta.eql(state_before, state));
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "runtime receipt rejects every mutation and rehashed contradiction" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var transform_plan_storage: [transform.transform_plan_bytes]u8 =
        undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        2,
        &fixture_storage,
        &decode_plan_storage,
        &transform_plan_storage,
        &decoded_for_plan,
    );
    const claim = try claimForExecutionV1(
        context.encoded_fixture.len,
        context.transform_plan,
    );
    var slots = [_]resource_bank.Slot{.{}};
    var bank = try resource_bank.Bank.init(
        &slots,
        try limitsForClaimV1(claim),
        1401,
    );
    var state = try media.initializePublicationStateV1(
        1402,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xd1} ** 32,
    );
    var session: Session = .{};
    try session.init(
        &bank,
        1403,
        1402,
        &state,
        context.encoded_fixture,
        context.encoded_transform_plan,
    );
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var transaction = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
    );
    const receipt = try transaction.commit();
    var storage: [receipt_bytes]u8 = undefined;
    const encoded = try encodeExecutionReceiptV1(receipt, &storage);
    var corrupted: [receipt_bytes]u8 = undefined;
    for (0..encoded.len) |index| {
        @memcpy(&corrupted, encoded);
        corrupted[index] ^= 1;
        const accepted = if (decodeExecutionReceiptV1(
            &corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }
    @memcpy(&corrupted, encoded);
    writeU64(&corrupted, 88, 2);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hash.update(corrupted[0..receipt_body_bytes]);
    var rerooted: Digest = undefined;
    hash.final(&rerooted);
    @memcpy(corrupted[receipt_body_bytes..], &rerooted);
    try std.testing.expectError(
        Error.InvalidReceipt,
        decodeExecutionReceiptV1(&corrupted),
    );
    try session.closeAndRelease();
}
