//! Bounded generated-image decode, provenance, and atomic publication.
//!
//! The portable core receives already-authorized caller-owned bytes. It has no
//! filesystem, network, provider, display, accelerator, or device authority.

const std = @import("std");
const media = @import("media_contract.zig");
const model = @import("model_contract.zig");
const stateful = @import("stateful_model_adapter.zig");
const continuation = @import("stateful_model_continuation.zig");
const latent = @import("latent_step_adapter.zig");
const resource_bank = @import("resource_bank.zig");

const Digest = [32]u8;

pub const plan_abi: u64 = 0x4749_504c_414e_0001;
pub const plan_bytes: usize = 736;
const plan_body_bytes = plan_bytes - 32;
const plan_magic = [_]u8{ 'G', 'I', 'P', 'L', 'A', 'N', '1', 0 };
const plan_domain = "glacier-generated-image-plan-v1\x00";

pub const provenance_abi: u64 = 0x4749_5052_4f56_0001;
pub const provenance_bytes: usize = 640;
const provenance_body_bytes = provenance_bytes - 32;
const provenance_magic = [_]u8{ 'G', 'I', 'P', 'R', 'O', 'V', '1', 0 };
const provenance_domain = "glacier-generated-image-provenance-v1\x00";

pub const result_abi: u64 = 0x4749_5253_4c54_0001;
pub const result_bytes: usize = 704;
const result_body_bytes = result_bytes - 32;
const result_magic = [_]u8{ 'G', 'I', 'R', 'S', 'L', 'T', '1', 0 };
const result_domain = "glacier-generated-image-result-v1\x00";

const source_provenance_domain =
    "glacier-generated-image-source-provenance-v1\x00";
const resource_domain =
    "glacier-generated-image-resource-v1\x00";
const allowed_flags: u64 = 0;
const runtime_abi: u64 = 0x4749_5254_0000_0001;

pub const raw_image_semantic_abi: u64 =
    0x4749_5241_5700_0001;
pub const raw_container_id: u64 =
    0x4749_5241_5700_0001;
pub const interleaved_u8_codec_id: u64 =
    0x4749_5538_0000_0001;
pub const reference_decoder_abi: u64 =
    0x4749_4445_434f_0001;
pub const reference_decoder_payload =
    [_]u8{ 4, 3, 2, 1 };
pub const reference_terminal_latent =
    [_]u8{ 6, 12, 18, 24 };
pub const reference_pixels =
    [_]u8{ 24, 36, 36, 24 };
pub const maximum_dimension: u64 = 8_192;
pub const maximum_pixel_bytes: u64 = 16 * 1024 * 1024;
pub const maximum_latent_bytes: u64 = 16 * 1024 * 1024;

pub const ColorModelV1 = enum(u64) {
    gray = 1,
    rgb = 2,
};

pub const TransferFunctionV1 = enum(u64) {
    linear = 1,
    srgb = 2,
};

pub const AlphaModeV1 = enum(u64) {
    none = 1,
    straight = 2,
};

pub const Error = media.Error || model.Error ||
    stateful.Error || continuation.Error || latent.Error ||
    resource_bank.Error || error{
    InvalidPlan,
    InvalidProvenance,
    InvalidResult,
    InvalidBinding,
    UnsupportedDecoder,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
    BufferTooSmall,
    BufferAlias,
    CandidateInvalid,
    CandidateDrift,
    InvalidState,
    ArithmeticOverflow,
};

pub const GeneratedImagePlanV1 = struct {
    request_epoch: u64,
    generation: u64,
    image_index: u64,
    source_step: u64,
    width: u64,
    height: u64,
    channels: u64,
    row_stride: u64,
    latent_bytes: u64,
    pixel_bytes: u64,
    maximum_output_bytes: u64,
    decoder_abi: u64,
    color_model: ColorModelV1,
    transfer_function: TransferFunctionV1,
    alpha_mode: AlphaModeV1,
    publication_sequence: u64,
    visible_images_before: u64,
    visible_images_after: u64,
    logical_units: u64,
    required_capabilities: u64,
    artifact_sha256: Digest,
    terminal_result_sha256: Digest,
    terminal_plan_sha256: Digest,
    terminal_output_sha256: Digest,
    terminal_state_publication_sha256: Digest,
    stateful_checkpoint_sha256: Digest,
    decoder_payload_sha256: Digest,
    decoder_implementation_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    source_provenance_sha256: Digest,
    challenge_sha256: Digest,
    previous_plan_sha256: Digest,
    previous_result_sha256: Digest,
    media_object_sha256: Digest,
    plan_sha256: Digest,
};

pub const GeneratedImageProvenanceV1 = struct {
    request_epoch: u64,
    generation: u64,
    image_index: u64,
    source_step: u64,
    width: u64,
    height: u64,
    channels: u64,
    pixel_bytes: u64,
    decoder_abi: u64,
    color_model: ColorModelV1,
    transfer_function: TransferFunctionV1,
    alpha_mode: AlphaModeV1,
    plan_sha256: Digest,
    artifact_sha256: Digest,
    terminal_result_sha256: Digest,
    terminal_plan_sha256: Digest,
    terminal_output_sha256: Digest,
    terminal_state_publication_sha256: Digest,
    stateful_checkpoint_sha256: Digest,
    decoder_payload_sha256: Digest,
    decoder_implementation_sha256: Digest,
    media_object_sha256: Digest,
    output_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    source_provenance_sha256: Digest,
    challenge_sha256: Digest,
    provenance_sha256: Digest,
};

pub const GeneratedImageResultV1 = struct {
    request_epoch: u64,
    generation: u64,
    image_index: u64,
    source_step: u64,
    width: u64,
    height: u64,
    channels: u64,
    row_stride: u64,
    pixel_bytes: u64,
    publication_sequence: u64,
    visible_images_before: u64,
    visible_images_after: u64,
    logical_units: u64,
    decoder_abi: u64,
    plan_sha256: Digest,
    provenance_sha256: Digest,
    artifact_sha256: Digest,
    terminal_result_sha256: Digest,
    terminal_output_sha256: Digest,
    terminal_state_publication_sha256: Digest,
    media_object_sha256: Digest,
    output_sha256: Digest,
    resource_receipt_sha256: Digest,
    publication_state_before_sha256: Digest,
    timeline_event_sha256: Digest,
    media_commit_sha256: Digest,
    publication_state_after_sha256: Digest,
    previous_result_sha256: Digest,
    decoder_implementation_sha256: Digest,
    challenge_sha256: Digest,
    result_sha256: Digest,
};

pub const DecoderV1 = struct {
    decoder_abi: u64,
    maximum_latent_bytes: u64,
    maximum_output_bytes: u64,
    required_capabilities: u64,
    implementation_sha256: Digest,
    context: *anyopaque,
    execute: *const fn (
        context: *anyopaque,
        plan: *const GeneratedImagePlanV1,
        terminal_latent: []const u8,
        decoder_payload: []const u8,
        candidate_output: []u8,
    ) anyerror!void,
    validate: *const fn (
        context: *anyopaque,
        plan: *const GeneratedImagePlanV1,
        terminal_latent: []const u8,
        decoder_payload: []const u8,
        candidate_output: []const u8,
    ) anyerror!void,
};

pub const Phase = enum {
    idle,
    prepared,
    poisoned,
    closed,
};

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    publication_state: *media.PublicationStateV1 = undefined,
    receipt: resource_bank.Receipt = undefined,
    manifest: model.ArtifactManifestV1 = undefined,
    checkpoint: continuation.CheckpointV1 = undefined,
    terminal_plan: model.ExecutionPlanV1 = undefined,
    terminal_result: model.ResultEnvelopeV1 = undefined,
    terminal_state_publication: stateful.StatePublicationV1 = undefined,
    media_object: media.MediaObjectV1 = undefined,
    plan: GeneratedImagePlanV1 = undefined,
    decoder: DecoderV1 = undefined,
    decoder_payload: []const u8 = &[_]u8{},
    terminal_latent: []const u8 = &[_]u8{},
    permit: ?resource_bank.PublicationPermit = null,
    prepared_provenance: ?GeneratedImageProvenanceV1 = null,
    prepared_result: ?GeneratedImageResultV1 = null,
    prepared_event: ?media.TimelineEventV1 = null,
    prepared_publication: ?media.PreparedPublicationV1 = null,
    prepared_state_after: ?media.PublicationStateV1 = null,
    candidate_output: ?[]u8 = null,
    candidate_provenance: ?[]u8 = null,
    candidate_result: ?[]u8 = null,
    visible_output: ?[]u8 = null,
    visible_provenance: ?[]u8 = null,
    visible_result: ?[]u8 = null,
    expected_output_sha256: Digest =
        [_]u8{0} ** 32,
    expected_provenance_wire_sha256: Digest =
        [_]u8{0} ** 32,
    expected_result_wire_sha256: Digest =
        [_]u8{0} ** 32,
    expected_publication_state_sha256: Digest =
        [_]u8{0} ** 32,
    next_resource_sequence: u64 = 0,
    initialized: bool = false,
    phase: Phase = .idle,

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        publication_state: *media.PublicationStateV1,
        manifest: model.ArtifactManifestV1,
        checkpoint: continuation.CheckpointV1,
        terminal_plan: model.ExecutionPlanV1,
        terminal_result: model.ResultEnvelopeV1,
        terminal_state_publication: stateful.StatePublicationV1,
        media_object: media.MediaObjectV1,
        plan: GeneratedImagePlanV1,
        decoder_payload: []const u8,
        decoder: DecoderV1,
    ) Error!void {
        if (self.initialized or self.phase != .idle or
            owner_key == 0)
            return Error.InvalidState;
        try validateGeneratedImageBindingsV1(
            plan,
            manifest,
            checkpoint,
            terminal_plan,
            terminal_result,
            terminal_state_publication,
            media_object,
            decoder_payload,
            decoder,
            publication_state.*,
        );
        const payload_bytes = std.math.cast(
            u64,
            decoder_payload.len,
        ) orelse return Error.ArithmeticOverflow;
        const claim = try claimForPlanV1(
            plan,
            payload_bytes,
        );
        const reservation = bank.reserve(
            owner_key,
            claim,
        ) catch return Error.ResourceAdmissionFailed;
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
            .receipt = receipt,
            .manifest = manifest,
            .checkpoint = checkpoint,
            .terminal_plan = terminal_plan,
            .terminal_result = terminal_result,
            .terminal_state_publication = terminal_state_publication,
            .media_object = media_object,
            .plan = plan,
            .decoder = decoder,
            .decoder_payload = decoder_payload,
            .initialized = true,
        };
    }

    pub fn prepareV1(
        self: *Session,
        terminal_latent: []const u8,
        candidate_output_storage: []u8,
        candidate_provenance_storage: []u8,
        candidate_result_storage: []u8,
        visible_output_storage: []u8,
        visible_provenance_storage: []u8,
        visible_result_storage: []u8,
    ) Error!GeneratedImageResultV1 {
        if (!self.initialized or self.phase != .idle or
            self.permit != null)
            return Error.InvalidState;
        try validateGeneratedImageBindingsV1(
            self.plan,
            self.manifest,
            self.checkpoint,
            self.terminal_plan,
            self.terminal_result,
            self.terminal_state_publication,
            self.media_object,
            self.decoder_payload,
            self.decoder,
            self.publication_state.*,
        );
        const pixel_bytes: usize = std.math.cast(
            usize,
            self.plan.pixel_bytes,
        ) orelse return Error.ArithmeticOverflow;
        if (terminal_latent.len !=
            self.plan.latent_bytes or
            candidate_output_storage.len <
                pixel_bytes or
            candidate_provenance_storage.len <
                provenance_bytes or
            candidate_result_storage.len <
                result_bytes or
            visible_output_storage.len <
                pixel_bytes or
            visible_provenance_storage.len <
                provenance_bytes or
            visible_result_storage.len <
                result_bytes)
            return Error.BufferTooSmall;
        const candidate_output =
            candidate_output_storage[0..pixel_bytes];
        const candidate_provenance =
            candidate_provenance_storage[0..provenance_bytes];
        const candidate_result =
            candidate_result_storage[0..result_bytes];
        const visible_output =
            visible_output_storage[0..pixel_bytes];
        const visible_provenance =
            visible_provenance_storage[0..provenance_bytes];
        const visible_result =
            visible_result_storage[0..result_bytes];
        const mutable = [_][]u8{
            candidate_output,
            candidate_provenance,
            candidate_result,
            visible_output,
            visible_provenance,
            visible_result,
        };
        const immutable = [_][]const u8{
            terminal_latent,
            self.decoder_payload,
            std.mem.asBytes(&self.manifest),
            std.mem.asBytes(&self.checkpoint),
            std.mem.asBytes(&self.terminal_plan),
            std.mem.asBytes(&self.terminal_result),
            std.mem.asBytes(
                &self.terminal_state_publication,
            ),
            std.mem.asBytes(&self.media_object),
            std.mem.asBytes(&self.plan),
            std.mem.asBytes(self.publication_state),
        };
        if (!buffersDisjoint(&mutable, &immutable))
            return Error.BufferAlias;
        if (!std.mem.eql(
            u8,
            &model.sha256(terminal_latent),
            &self.plan.terminal_output_sha256,
        ))
            return Error.InvalidBinding;
        @memset(candidate_output, 0);
        @memset(candidate_provenance, 0);
        @memset(candidate_result, 0);
        const permit = self.bank.beginPublication(
            self.receipt,
            self.plan.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.permit = permit;
        self.terminal_latent = terminal_latent;
        self.candidate_output = candidate_output;
        self.candidate_provenance =
            candidate_provenance;
        self.candidate_result = candidate_result;
        self.visible_output = visible_output;
        self.visible_provenance = visible_provenance;
        self.visible_result = visible_result;
        self.phase = .prepared;
        self.decoder.execute(
            self.decoder.context,
            &self.plan,
            terminal_latent,
            self.decoder_payload,
            candidate_output,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateInvalid;
        };
        self.decoder.validate(
            self.decoder.context,
            &self.plan,
            terminal_latent,
            self.decoder_payload,
            candidate_output,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateInvalid;
        };
        const output_sha256 = model.sha256(
            candidate_output,
        );
        if (!std.mem.eql(
            u8,
            &output_sha256,
            &self.media_object.content_sha256,
        )) {
            try self.rollbackV1(permit);
            return Error.CandidateInvalid;
        }
        const provenance =
            makeGeneratedImageProvenanceV1(
                self.plan,
                output_sha256,
            ) catch {
                try self.rollbackV1(permit);
                return Error.InvalidProvenance;
            };
        var provenance_wire: [provenance_bytes]u8 =
            undefined;
        _ = encodeGeneratedImageProvenanceV1(
            provenance,
            &provenance_wire,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidProvenance;
        };
        @memcpy(candidate_provenance, &provenance_wire);
        const event = timelineEventForPlanV1(
            self.plan,
            self.publication_state.*,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidBinding;
        };
        const resource_root = resourceReceiptRootV1(
            self.receipt,
            self.plan.request_epoch,
            self.plan.plan_sha256,
            self.plan.decoder_implementation_sha256,
        );
        const prepared = media.preparePublicationV1(
            self.publication_state.*,
            event,
            output_sha256,
            resource_root,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidBinding;
        };
        var state_after = self.publication_state.*;
        media.commitPublicationV1(
            &state_after,
            prepared,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidBinding;
        };
        const result = makeGeneratedImageResultV1(
            self.plan,
            provenance,
            self.media_object,
            self.receipt,
            self.publication_state.*,
            event,
            prepared,
            state_after,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidResult;
        };
        var result_wire: [result_bytes]u8 = undefined;
        _ = encodeGeneratedImageResultV1(
            result,
            &result_wire,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidResult;
        };
        @memcpy(candidate_result, &result_wire);
        self.prepared_provenance = provenance;
        self.prepared_result = result;
        self.prepared_event = event;
        self.prepared_publication = prepared;
        self.prepared_state_after = state_after;
        self.expected_output_sha256 = output_sha256;
        self.expected_provenance_wire_sha256 =
            model.sha256(candidate_provenance);
        self.expected_result_wire_sha256 =
            model.sha256(candidate_result);
        self.expected_publication_state_sha256 =
            media.publicationStateRootV1(
                self.publication_state.*,
            );
        return result;
    }

    pub fn commitV1(
        self: *Session,
    ) Error!GeneratedImageResultV1 {
        if (!self.initialized or
            self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse
            return Error.InvalidState;
        const expected_provenance =
            self.prepared_provenance orelse
            return Error.InvalidState;
        const expected_result =
            self.prepared_result orelse
            return Error.InvalidState;
        const expected_event = self.prepared_event orelse
            return Error.InvalidState;
        const expected_publication =
            self.prepared_publication orelse
            return Error.InvalidState;
        const expected_state_after =
            self.prepared_state_after orelse
            return Error.InvalidState;
        const candidate_output =
            self.candidate_output orelse
            return Error.InvalidState;
        const candidate_provenance =
            self.candidate_provenance orelse
            return Error.InvalidState;
        const candidate_result =
            self.candidate_result orelse
            return Error.InvalidState;
        const visible_output = self.visible_output orelse
            return Error.InvalidState;
        const visible_provenance =
            self.visible_provenance orelse
            return Error.InvalidState;
        const visible_result = self.visible_result orelse
            return Error.InvalidState;
        self.bank.validatePublication(permit) catch {
            try self.rollbackV1(permit);
            return Error.ResourceReceiptInvalid;
        };
        validateGeneratedImageBindingsV1(
            self.plan,
            self.manifest,
            self.checkpoint,
            self.terminal_plan,
            self.terminal_result,
            self.terminal_state_publication,
            self.media_object,
            self.decoder_payload,
            self.decoder,
            self.publication_state.*,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.mem.eql(
            u8,
            &media.publicationStateRootV1(
                self.publication_state.*,
            ),
            &self.expected_publication_state_sha256,
        ) or
            !std.mem.eql(
                u8,
                &model.sha256(self.terminal_latent),
                &self.plan.terminal_output_sha256,
            ) or
            !std.mem.eql(
                u8,
                &model.sha256(candidate_output),
                &self.expected_output_sha256,
            ) or
            !std.mem.eql(
                u8,
                &model.sha256(candidate_provenance),
                &self.expected_provenance_wire_sha256,
            ) or
            !std.mem.eql(
                u8,
                &model.sha256(candidate_result),
                &self.expected_result_wire_sha256,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        self.decoder.validate(
            self.decoder.context,
            &self.plan,
            self.terminal_latent,
            self.decoder_payload,
            candidate_output,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const decoded_provenance =
            decodeGeneratedImageProvenanceV1(
                candidate_provenance,
            ) catch {
                try self.rollbackV1(permit);
                return Error.CandidateDrift;
            };
        const decoded_result =
            decodeGeneratedImageResultV1(
                candidate_result,
            ) catch {
                try self.rollbackV1(permit);
                return Error.CandidateDrift;
            };
        const output_sha256 = model.sha256(
            candidate_output,
        );
        const reconstructed_provenance =
            makeGeneratedImageProvenanceV1(
                self.plan,
                output_sha256,
            ) catch {
                try self.rollbackV1(permit);
                return Error.CandidateDrift;
            };
        const event = timelineEventForPlanV1(
            self.plan,
            self.publication_state.*,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const resource_root = resourceReceiptRootV1(
            self.receipt,
            self.plan.request_epoch,
            self.plan.plan_sha256,
            self.plan.decoder_implementation_sha256,
        );
        const prepared = media.preparePublicationV1(
            self.publication_state.*,
            event,
            output_sha256,
            resource_root,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        var state_after = self.publication_state.*;
        media.commitPublicationV1(
            &state_after,
            prepared,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const reconstructed_result =
            makeGeneratedImageResultV1(
                self.plan,
                reconstructed_provenance,
                self.media_object,
                self.receipt,
                self.publication_state.*,
                event,
                prepared,
                state_after,
            ) catch {
                try self.rollbackV1(permit);
                return Error.CandidateDrift;
            };
        if (!std.meta.eql(
            decoded_provenance,
            expected_provenance,
        ) or
            !std.meta.eql(
                decoded_provenance,
                reconstructed_provenance,
            ) or
            !std.meta.eql(
                decoded_result,
                expected_result,
            ) or
            !std.meta.eql(
                decoded_result,
                reconstructed_result,
            ) or
            !std.meta.eql(event, expected_event) or
            !std.meta.eql(
                prepared,
                expected_publication,
            ) or
            !std.meta.eql(
                state_after,
                expected_state_after,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        @memcpy(visible_output, candidate_output);
        @memcpy(
            visible_provenance,
            candidate_provenance,
        );
        @memcpy(visible_result, candidate_result);
        self.publication_state.* = state_after;
        self.bank.commitPublicationAssumeValid(permit);
        self.next_resource_sequence = permit.sequence + 1;
        self.scrubCandidatesV1();
        self.clearPreparedV1();
        self.phase = .idle;
        return decoded_result;
    }

    pub fn abortV1(self: *Session) Error!void {
        if (!self.initialized or
            self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse
            return Error.InvalidState;
        try self.rollbackV1(permit);
    }

    pub fn closeAndRelease(
        self: *Session,
    ) Error!void {
        if (!self.initialized or self.phase != .idle)
            return Error.InvalidState;
        self.bank.closePublicationSession(
            self.receipt,
            self.plan.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.bank.release(self.receipt) catch
            return Error.ResourceReceiptInvalid;
        self.initialized = false;
        self.phase = .closed;
    }

    fn rollbackV1(
        self: *Session,
        permit: resource_bank.PublicationPermit,
    ) Error!void {
        self.bank.abortPublication(permit) catch {
            self.scrubCandidatesV1();
            self.clearPreparedV1();
            self.phase = .poisoned;
            return Error.ResourceReceiptInvalid;
        };
        self.scrubCandidatesV1();
        self.clearPreparedV1();
        self.phase = .idle;
    }

    fn scrubCandidatesV1(self: *Session) void {
        if (self.candidate_output) |bytes|
            @memset(bytes, 0);
        if (self.candidate_provenance) |bytes|
            @memset(bytes, 0);
        if (self.candidate_result) |bytes|
            @memset(bytes, 0);
    }

    fn clearPreparedV1(self: *Session) void {
        self.permit = null;
        self.prepared_provenance = null;
        self.prepared_result = null;
        self.prepared_event = null;
        self.prepared_publication = null;
        self.prepared_state_after = null;
        self.candidate_output = null;
        self.candidate_provenance = null;
        self.candidate_result = null;
        self.visible_output = null;
        self.visible_provenance = null;
        self.visible_result = null;
        self.terminal_latent = &[_]u8{};
        self.expected_output_sha256 =
            [_]u8{0} ** 32;
        self.expected_provenance_wire_sha256 =
            [_]u8{0} ** 32;
        self.expected_result_wire_sha256 =
            [_]u8{0} ** 32;
        self.expected_publication_state_sha256 =
            [_]u8{0} ** 32;
    }
};

pub fn sourceProvenanceRootV1(
    manifest: model.ArtifactManifestV1,
    checkpoint: continuation.CheckpointV1,
    terminal_plan: model.ExecutionPlanV1,
    terminal_result: model.ResultEnvelopeV1,
    terminal_state_publication: stateful.StatePublicationV1,
    decoder_payload_sha256: Digest,
    decoder_implementation_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_provenance_domain);
    hashU64(&hash, plan_abi);
    hashU64(&hash, terminal_result.request_epoch);
    hashU64(&hash, terminal_result.generation);
    hash.update(&manifest.artifact_sha256);
    hash.update(&checkpoint.checkpoint_sha256);
    hash.update(&terminal_plan.plan_sha256);
    hash.update(&terminal_result.result_sha256);
    hash.update(&terminal_result.output_sha256);
    hash.update(&terminal_state_publication.publication_sha256);
    hash.update(&decoder_payload_sha256);
    hash.update(&decoder_implementation_sha256);
    hash.update(&tenant_scope_sha256);
    hash.update(&metadata_policy_sha256);
    hash.update(&challenge_sha256);
    return hash.finalResult();
}

pub fn makeGeneratedImagePlanV1(
    manifest: model.ArtifactManifestV1,
    checkpoint: continuation.CheckpointV1,
    terminal_plan: model.ExecutionPlanV1,
    terminal_result: model.ResultEnvelopeV1,
    terminal_state_publication: stateful.StatePublicationV1,
    media_object: media.MediaObjectV1,
    decoder_payload: []const u8,
    decoder: DecoderV1,
    publication_state: media.PublicationStateV1,
    previous_plan_sha256: Digest,
    previous_result_sha256: Digest,
) Error!GeneratedImagePlanV1 {
    const media_root = try mediaObjectRootV1(media_object);
    const visible_images_after = try checkedAdd(
        publication_state.visible_chunks,
        1,
    );
    const expected_source_provenance =
        sourceProvenanceRootV1(
            manifest,
            checkpoint,
            terminal_plan,
            terminal_result,
            terminal_state_publication,
            model.sha256(decoder_payload),
            decoder.implementation_sha256,
            media_object.tenant_scope_sha256,
            media_object.metadata_policy_sha256,
            terminal_result.challenge_sha256,
        );
    var plan: GeneratedImagePlanV1 = .{
        .request_epoch = terminal_result.request_epoch,
        .generation = terminal_result.generation,
        .image_index = visible_images_after,
        .source_step = terminal_state_publication.current_step,
        .width = media_object.axes[0],
        .height = media_object.axes[1],
        .channels = media_object.axes[2],
        .row_stride = try checkedMul(
            media_object.axes[0],
            media_object.axes[2],
        ),
        .latent_bytes = terminal_result.output_bytes,
        .pixel_bytes = media_object.byte_length,
        .maximum_output_bytes = media_object.byte_length,
        .decoder_abi = decoder.decoder_abi,
        .color_model = colorModelForChannels(
            media_object.axes[2],
        ) catch return Error.InvalidPlan,
        .transfer_function = .linear,
        .alpha_mode = alphaModeForChannels(
            media_object.axes[2],
        ) catch return Error.InvalidPlan,
        .publication_sequence = publication_state.next_sequence,
        .visible_images_before = publication_state.visible_chunks,
        .visible_images_after = visible_images_after,
        .logical_units = 1,
        .required_capabilities = decoder.required_capabilities,
        .artifact_sha256 = manifest.artifact_sha256,
        .terminal_result_sha256 = terminal_result.result_sha256,
        .terminal_plan_sha256 = terminal_plan.plan_sha256,
        .terminal_output_sha256 = terminal_result.output_sha256,
        .terminal_state_publication_sha256 = terminal_state_publication.publication_sha256,
        .stateful_checkpoint_sha256 = checkpoint.checkpoint_sha256,
        .decoder_payload_sha256 = model.sha256(decoder_payload),
        .decoder_implementation_sha256 = decoder.implementation_sha256,
        .tenant_scope_sha256 = media_object.tenant_scope_sha256,
        .metadata_policy_sha256 = media_object.metadata_policy_sha256,
        .source_provenance_sha256 = expected_source_provenance,
        .challenge_sha256 = terminal_result.challenge_sha256,
        .previous_plan_sha256 = previous_plan_sha256,
        .previous_result_sha256 = previous_result_sha256,
        .media_object_sha256 = media_root,
        .plan_sha256 = [_]u8{0} ** 32,
    };
    plan.plan_sha256 = generatedImagePlanRootV1(plan);
    try validateGeneratedImageBindingsV1(
        plan,
        manifest,
        checkpoint,
        terminal_plan,
        terminal_result,
        terminal_state_publication,
        media_object,
        decoder_payload,
        decoder,
        publication_state,
    );
    return plan;
}

pub fn validateGeneratedImagePlanV1(
    plan: GeneratedImagePlanV1,
) Error!void {
    const expected_stride = checkedMul(
        plan.width,
        plan.channels,
    ) catch return Error.InvalidPlan;
    const expected_bytes = checkedMul(
        expected_stride,
        plan.height,
    ) catch return Error.InvalidPlan;
    const expected_after = std.math.add(
        u64,
        plan.visible_images_before,
        1,
    ) catch return Error.InvalidPlan;
    const expected_index = expected_after;
    if (plan.request_epoch == 0 or
        plan.generation == 0 or
        plan.image_index != expected_index or
        plan.source_step == 0 or
        plan.width == 0 or
        plan.width > maximum_dimension or
        plan.height == 0 or
        plan.height > maximum_dimension or
        plan.channels == 0 or
        plan.channels > 4 or
        plan.row_stride != expected_stride or
        plan.latent_bytes == 0 or
        plan.latent_bytes > maximum_latent_bytes or
        plan.pixel_bytes != expected_bytes or
        plan.pixel_bytes == 0 or
        plan.pixel_bytes > maximum_pixel_bytes or
        plan.maximum_output_bytes != plan.pixel_bytes or
        plan.decoder_abi == 0 or
        plan.publication_sequence == 0 or
        plan.visible_images_after != expected_after or
        plan.logical_units != 1 or
        plan.required_capabilities != 0 or
        !validColorShape(
            plan.channels,
            plan.color_model,
            plan.alpha_mode,
        ) or
        (plan.transfer_function != .linear and
            plan.transfer_function != .srgb) or
        isZero(plan.artifact_sha256) or
        isZero(plan.terminal_result_sha256) or
        isZero(plan.terminal_plan_sha256) or
        isZero(plan.terminal_output_sha256) or
        isZero(plan.terminal_state_publication_sha256) or
        isZero(plan.stateful_checkpoint_sha256) or
        isZero(plan.decoder_payload_sha256) or
        isZero(plan.decoder_implementation_sha256) or
        isZero(plan.tenant_scope_sha256) or
        isZero(plan.metadata_policy_sha256) or
        isZero(plan.source_provenance_sha256) or
        isZero(plan.challenge_sha256) or
        isZero(plan.previous_plan_sha256) or
        isZero(plan.previous_result_sha256) or
        isZero(plan.media_object_sha256) or
        !std.mem.eql(
            u8,
            &plan.plan_sha256,
            &generatedImagePlanRootV1(plan),
        ))
        return Error.InvalidPlan;
}

pub fn validateGeneratedImageBindingsV1(
    plan: GeneratedImagePlanV1,
    manifest: model.ArtifactManifestV1,
    checkpoint: continuation.CheckpointV1,
    terminal_plan: model.ExecutionPlanV1,
    terminal_result: model.ResultEnvelopeV1,
    terminal_state_publication: stateful.StatePublicationV1,
    media_object: media.MediaObjectV1,
    decoder_payload: []const u8,
    decoder: DecoderV1,
    publication_state: media.PublicationStateV1,
) Error!void {
    try validateGeneratedImagePlanV1(plan);
    try model.validateArtifactManifestV1(manifest);
    try continuation.validateCheckpointV1(checkpoint);
    try model.validateExecutionPlanV1(terminal_plan);
    try model.validateResultEnvelopeV1(terminal_result);
    try stateful.validateStatePublicationV1(
        terminal_state_publication,
    );
    const media_root = try mediaObjectRootV1(media_object);
    const expected_source_provenance =
        sourceProvenanceRootV1(
            manifest,
            checkpoint,
            terminal_plan,
            terminal_result,
            terminal_state_publication,
            model.sha256(decoder_payload),
            decoder.implementation_sha256,
            media_object.tenant_scope_sha256,
            media_object.metadata_policy_sha256,
            terminal_result.challenge_sha256,
        );
    const expected_checkpoint_step = std.math.add(
        u64,
        checkpoint.current_step,
        1,
    ) catch return Error.InvalidBinding;
    if (manifest.family != .image_generation or
        manifest.input_kind != .latent_tensor or
        manifest.output_kind != .media_chunk or
        manifest.numerical_policy != .exact_integer or
        terminal_plan.family != manifest.family or
        terminal_plan.operation != .diffuse_step or
        terminal_plan.input_kind != manifest.input_kind or
        terminal_plan.output_kind != manifest.output_kind or
        terminal_plan.numerical_policy !=
            manifest.numerical_policy or
        terminal_result.family != manifest.family or
        terminal_result.operation !=
            terminal_plan.operation or
        terminal_result.output_kind !=
            terminal_plan.output_kind or
        terminal_result.numerical_policy !=
            terminal_plan.numerical_policy or
        plan.request_epoch != terminal_plan.request_epoch or
        plan.request_epoch != terminal_result.request_epoch or
        plan.request_epoch !=
            terminal_state_publication.request_epoch or
        plan.request_epoch != checkpoint.request_epoch or
        plan.generation != terminal_plan.generation or
        plan.generation != terminal_result.generation or
        plan.source_step !=
            terminal_state_publication.current_step or
        plan.source_step !=
            terminal_state_publication.total_steps or
        plan.source_step != checkpoint.total_steps or
        plan.source_step != expected_checkpoint_step or
        plan.latent_bytes != terminal_result.output_bytes or
        terminal_plan.output_bytes !=
            terminal_result.output_bytes or
        terminal_plan.output_bytes !=
            terminal_state_publication.state_bytes or
        !digestEqual(
            terminal_state_publication.previous_result_sha256,
            terminal_result.result_sha256,
        ) or
        !digestEqual(
            checkpoint.artifact_sha256,
            manifest.artifact_sha256,
        ) or
        !digestEqual(
            terminal_plan.artifact_sha256,
            manifest.artifact_sha256,
        ) or
        !digestEqual(
            terminal_result.artifact_sha256,
            manifest.artifact_sha256,
        ) or
        !digestEqual(
            terminal_result.plan_sha256,
            terminal_plan.plan_sha256,
        ) or
        terminal_result.resource_bank_epoch !=
            checkpoint.restore_bank_epoch or
        !digestEqual(
            terminal_result.previous_result_sha256,
            checkpoint.previous_result_sha256,
        ) or
        !digestEqual(
            terminal_plan.previous_plan_sha256,
            checkpoint.last_plan_sha256,
        ) or
        !digestEqual(
            terminal_plan.processor_state_sha256,
            checkpoint.state_publication_sha256,
        ) or
        !digestEqual(
            terminal_plan.cache_payload_sha256,
            checkpoint.current_state_sha256,
        ) or
        !digestEqual(
            terminal_plan.challenge_sha256,
            checkpoint.challenge_sha256,
        ) or
        checkpoint.publication_next_sequence !=
            terminal_result.publication_sequence or
        media_object.kind != .image or
        media_object.semantic_abi !=
            raw_image_semantic_abi or
        media_object.byte_length != plan.pixel_bytes or
        media_object.container_id != raw_container_id or
        media_object.codec_id !=
            interleaved_u8_codec_id or
        media_object.axes[0] != plan.width or
        media_object.axes[1] != plan.height or
        media_object.axes[2] != plan.channels or
        media_object.time_base.numerator != 0 or
        media_object.time_base.denominator != 1 or
        publication_state.request_epoch !=
            plan.request_epoch or
        publication_state.next_sequence !=
            plan.publication_sequence or
        publication_state.visible_chunks !=
            plan.visible_images_before or
        publication_state.visible_units != 0 or
        publication_state.timeline_base.numerator != 1 or
        publication_state.timeline_base.denominator != 1 or
        !isZero(publication_state.timeline_sha256) or
        !std.mem.eql(
            u8,
            &publication_state.media_object_sha256,
            &plan.media_object_sha256,
        ) or
        decoder.decoder_abi != plan.decoder_abi or
        decoder.maximum_latent_bytes < plan.latent_bytes or
        decoder.maximum_output_bytes <
            plan.pixel_bytes or
        decoder.required_capabilities !=
            plan.required_capabilities or
        !digestEqual(
            decoder.implementation_sha256,
            plan.decoder_implementation_sha256,
        ) or
        decoder_payload.len == 0 or
        !digestEqual(
            model.sha256(decoder_payload),
            plan.decoder_payload_sha256,
        ) or
        !digestEqual(
            manifest.artifact_sha256,
            plan.artifact_sha256,
        ) or
        !digestEqual(
            terminal_result.result_sha256,
            plan.terminal_result_sha256,
        ) or
        !digestEqual(
            terminal_plan.plan_sha256,
            plan.terminal_plan_sha256,
        ) or
        !digestEqual(
            terminal_result.output_sha256,
            plan.terminal_output_sha256,
        ) or
        !digestEqual(
            terminal_state_publication.publication_sha256,
            plan.terminal_state_publication_sha256,
        ) or
        !digestEqual(
            terminal_state_publication.artifact_sha256,
            manifest.artifact_sha256,
        ) or
        !digestEqual(
            terminal_state_publication.challenge_sha256,
            plan.challenge_sha256,
        ) or
        !digestEqual(
            checkpoint.checkpoint_sha256,
            plan.stateful_checkpoint_sha256,
        ) or
        !digestEqual(
            media_root,
            plan.media_object_sha256,
        ) or
        !digestEqual(
            media_object.tenant_scope_sha256,
            plan.tenant_scope_sha256,
        ) or
        !digestEqual(
            media_object.metadata_policy_sha256,
            plan.metadata_policy_sha256,
        ) or
        !digestEqual(
            media_object.provenance_sha256,
            plan.source_provenance_sha256,
        ) or
        !digestEqual(
            expected_source_provenance,
            plan.source_provenance_sha256,
        ) or
        !digestEqual(
            terminal_result.challenge_sha256,
            plan.challenge_sha256,
        ) or
        !digestEqual(
            checkpoint.challenge_sha256,
            plan.challenge_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn makeGeneratedImageProvenanceV1(
    plan: GeneratedImagePlanV1,
    output_sha256: Digest,
) Error!GeneratedImageProvenanceV1 {
    try validateGeneratedImagePlanV1(plan);
    if (isZero(output_sha256))
        return Error.InvalidProvenance;
    var value: GeneratedImageProvenanceV1 = .{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .image_index = plan.image_index,
        .source_step = plan.source_step,
        .width = plan.width,
        .height = plan.height,
        .channels = plan.channels,
        .pixel_bytes = plan.pixel_bytes,
        .decoder_abi = plan.decoder_abi,
        .color_model = plan.color_model,
        .transfer_function = plan.transfer_function,
        .alpha_mode = plan.alpha_mode,
        .plan_sha256 = plan.plan_sha256,
        .artifact_sha256 = plan.artifact_sha256,
        .terminal_result_sha256 = plan.terminal_result_sha256,
        .terminal_plan_sha256 = plan.terminal_plan_sha256,
        .terminal_output_sha256 = plan.terminal_output_sha256,
        .terminal_state_publication_sha256 = plan.terminal_state_publication_sha256,
        .stateful_checkpoint_sha256 = plan.stateful_checkpoint_sha256,
        .decoder_payload_sha256 = plan.decoder_payload_sha256,
        .decoder_implementation_sha256 = plan.decoder_implementation_sha256,
        .media_object_sha256 = plan.media_object_sha256,
        .output_sha256 = output_sha256,
        .tenant_scope_sha256 = plan.tenant_scope_sha256,
        .metadata_policy_sha256 = plan.metadata_policy_sha256,
        .source_provenance_sha256 = plan.source_provenance_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .provenance_sha256 = [_]u8{0} ** 32,
    };
    value.provenance_sha256 =
        generatedImageProvenanceRootV1(value);
    try validateGeneratedImageProvenanceV1(value);
    return value;
}

pub fn validateGeneratedImageProvenanceV1(
    value: GeneratedImageProvenanceV1,
) Error!void {
    if (value.request_epoch == 0 or
        value.generation == 0 or
        value.image_index == 0 or
        value.source_step == 0 or
        value.width == 0 or
        value.width > maximum_dimension or
        value.height == 0 or
        value.height > maximum_dimension or
        value.channels == 0 or
        value.channels > 4 or
        value.pixel_bytes == 0 or
        value.pixel_bytes > maximum_pixel_bytes or
        value.decoder_abi == 0 or
        !validColorShape(
            value.channels,
            value.color_model,
            value.alpha_mode,
        ) or
        (value.transfer_function != .linear and
            value.transfer_function != .srgb) or
        isZero(value.plan_sha256) or
        isZero(value.artifact_sha256) or
        isZero(value.terminal_result_sha256) or
        isZero(value.terminal_plan_sha256) or
        isZero(value.terminal_output_sha256) or
        isZero(
            value.terminal_state_publication_sha256,
        ) or
        isZero(value.stateful_checkpoint_sha256) or
        isZero(value.decoder_payload_sha256) or
        isZero(value.decoder_implementation_sha256) or
        isZero(value.media_object_sha256) or
        isZero(value.output_sha256) or
        isZero(value.tenant_scope_sha256) or
        isZero(value.metadata_policy_sha256) or
        isZero(value.source_provenance_sha256) or
        isZero(value.challenge_sha256) or
        !std.mem.eql(
            u8,
            &value.provenance_sha256,
            &generatedImageProvenanceRootV1(value),
        ))
        return Error.InvalidProvenance;
}

pub fn validateGeneratedImageProvenanceBindingsV1(
    plan: GeneratedImagePlanV1,
    provenance: GeneratedImageProvenanceV1,
    media_object: media.MediaObjectV1,
) Error!void {
    try validateGeneratedImagePlanV1(plan);
    try validateGeneratedImageProvenanceV1(
        provenance,
    );
    const media_root = try mediaObjectRootV1(
        media_object,
    );
    if (provenance.request_epoch !=
        plan.request_epoch or
        provenance.generation != plan.generation or
        provenance.image_index != plan.image_index or
        provenance.source_step != plan.source_step or
        provenance.width != plan.width or
        provenance.height != plan.height or
        provenance.channels != plan.channels or
        provenance.pixel_bytes != plan.pixel_bytes or
        provenance.decoder_abi != plan.decoder_abi or
        provenance.color_model != plan.color_model or
        provenance.transfer_function !=
            plan.transfer_function or
        provenance.alpha_mode != plan.alpha_mode or
        !digestEqual(
            provenance.plan_sha256,
            plan.plan_sha256,
        ) or
        !digestEqual(
            provenance.artifact_sha256,
            plan.artifact_sha256,
        ) or
        !digestEqual(
            provenance.terminal_result_sha256,
            plan.terminal_result_sha256,
        ) or
        !digestEqual(
            provenance.terminal_plan_sha256,
            plan.terminal_plan_sha256,
        ) or
        !digestEqual(
            provenance.terminal_output_sha256,
            plan.terminal_output_sha256,
        ) or
        !digestEqual(
            provenance.terminal_state_publication_sha256,
            plan.terminal_state_publication_sha256,
        ) or
        !digestEqual(
            provenance.stateful_checkpoint_sha256,
            plan.stateful_checkpoint_sha256,
        ) or
        !digestEqual(
            provenance.decoder_payload_sha256,
            plan.decoder_payload_sha256,
        ) or
        !digestEqual(
            provenance.decoder_implementation_sha256,
            plan.decoder_implementation_sha256,
        ) or
        !digestEqual(
            provenance.media_object_sha256,
            plan.media_object_sha256,
        ) or
        !digestEqual(
            provenance.tenant_scope_sha256,
            plan.tenant_scope_sha256,
        ) or
        !digestEqual(
            provenance.metadata_policy_sha256,
            plan.metadata_policy_sha256,
        ) or
        !digestEqual(
            provenance.source_provenance_sha256,
            plan.source_provenance_sha256,
        ) or
        !digestEqual(
            provenance.challenge_sha256,
            plan.challenge_sha256,
        ) or
        !digestEqual(
            media_root,
            plan.media_object_sha256,
        ) or
        !digestEqual(
            media_object.content_sha256,
            provenance.output_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn makeGeneratedImageResultV1(
    plan: GeneratedImagePlanV1,
    provenance: GeneratedImageProvenanceV1,
    media_object: media.MediaObjectV1,
    receipt: resource_bank.Receipt,
    publication_state_before: media.PublicationStateV1,
    timeline_event: media.TimelineEventV1,
    prepared_publication: media.PreparedPublicationV1,
    publication_state_after: media.PublicationStateV1,
) Error!GeneratedImageResultV1 {
    try validateGeneratedImagePlanV1(plan);
    try validateGeneratedImageProvenanceV1(provenance);
    try validateGeneratedImageProvenanceBindingsV1(
        plan,
        provenance,
        media_object,
    );
    const event_root =
        try media.timelineEventRootV1(timeline_event);
    const resource_root =
        resourceReceiptRootV1(
            receipt,
            plan.request_epoch,
            plan.plan_sha256,
            plan.decoder_implementation_sha256,
        );
    const expected_prepared =
        try media.preparePublicationV1(
            publication_state_before,
            timeline_event,
            provenance.output_sha256,
            resource_root,
        );
    var expected_state_after =
        publication_state_before;
    try media.commitPublicationV1(
        &expected_state_after,
        expected_prepared,
    );
    if (!std.meta.eql(
        expected_prepared,
        prepared_publication,
    ) or
        !std.meta.eql(
            expected_state_after,
            publication_state_after,
        ) or
        !digestEqual(
            provenance.plan_sha256,
            plan.plan_sha256,
        ) or
        isZero(provenance.provenance_sha256))
        return Error.InvalidBinding;
    var value: GeneratedImageResultV1 = .{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .image_index = plan.image_index,
        .source_step = plan.source_step,
        .width = plan.width,
        .height = plan.height,
        .channels = plan.channels,
        .row_stride = plan.row_stride,
        .pixel_bytes = plan.pixel_bytes,
        .publication_sequence = plan.publication_sequence,
        .visible_images_before = plan.visible_images_before,
        .visible_images_after = plan.visible_images_after,
        .logical_units = plan.logical_units,
        .decoder_abi = plan.decoder_abi,
        .plan_sha256 = plan.plan_sha256,
        .provenance_sha256 = provenance.provenance_sha256,
        .artifact_sha256 = plan.artifact_sha256,
        .terminal_result_sha256 = plan.terminal_result_sha256,
        .terminal_output_sha256 = plan.terminal_output_sha256,
        .terminal_state_publication_sha256 = plan.terminal_state_publication_sha256,
        .media_object_sha256 = plan.media_object_sha256,
        .output_sha256 = provenance.output_sha256,
        .resource_receipt_sha256 = resource_root,
        .publication_state_before_sha256 = media.publicationStateRootV1(
            publication_state_before,
        ),
        .timeline_event_sha256 = event_root,
        .media_commit_sha256 = prepared_publication.commit_sha256,
        .publication_state_after_sha256 = media.publicationStateRootV1(
            publication_state_after,
        ),
        .previous_result_sha256 = plan.previous_result_sha256,
        .decoder_implementation_sha256 = plan.decoder_implementation_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .result_sha256 = [_]u8{0} ** 32,
    };
    value.result_sha256 =
        generatedImageResultRootV1(value);
    try validateGeneratedImageResultV1(value);
    return value;
}

pub fn validateGeneratedImageResultV1(
    value: GeneratedImageResultV1,
) Error!void {
    const expected_stride = checkedMul(
        value.width,
        value.channels,
    ) catch return Error.InvalidResult;
    const expected_bytes = checkedMul(
        expected_stride,
        value.height,
    ) catch return Error.InvalidResult;
    const expected_after = std.math.add(
        u64,
        value.visible_images_before,
        1,
    ) catch return Error.InvalidResult;
    if (value.request_epoch == 0 or
        value.generation == 0 or
        value.image_index != expected_after or
        value.source_step == 0 or
        value.width == 0 or
        value.width > maximum_dimension or
        value.height == 0 or
        value.height > maximum_dimension or
        value.channels == 0 or
        value.channels > 4 or
        value.row_stride != expected_stride or
        value.pixel_bytes != expected_bytes or
        value.pixel_bytes == 0 or
        value.pixel_bytes > maximum_pixel_bytes or
        value.publication_sequence == 0 or
        value.visible_images_after != expected_after or
        value.logical_units != 1 or
        value.decoder_abi == 0 or
        isZero(value.plan_sha256) or
        isZero(value.provenance_sha256) or
        isZero(value.artifact_sha256) or
        isZero(value.terminal_result_sha256) or
        isZero(value.terminal_output_sha256) or
        isZero(
            value.terminal_state_publication_sha256,
        ) or
        isZero(value.media_object_sha256) or
        isZero(value.output_sha256) or
        isZero(value.resource_receipt_sha256) or
        isZero(value.publication_state_before_sha256) or
        isZero(value.timeline_event_sha256) or
        isZero(value.media_commit_sha256) or
        isZero(value.publication_state_after_sha256) or
        isZero(value.previous_result_sha256) or
        isZero(value.decoder_implementation_sha256) or
        isZero(value.challenge_sha256) or
        !std.mem.eql(
            u8,
            &value.result_sha256,
            &generatedImageResultRootV1(value),
        ))
        return Error.InvalidResult;
}

pub fn encodeGeneratedImagePlanV1(
    plan: GeneratedImagePlanV1,
    output: *[plan_bytes]u8,
) Error![]const u8 {
    try validateGeneratedImagePlanV1(plan);
    writePlanBodyV1(plan, output[0..plan_body_bytes]);
    @memcpy(output[plan_body_bytes..], &plan.plan_sha256);
    return output;
}

pub fn decodeGeneratedImagePlanV1(
    encoded: []const u8,
) Error!GeneratedImagePlanV1 {
    if (encoded.len != plan_bytes or
        !std.mem.eql(u8, encoded[0..8], &plan_magic) or
        readU64(encoded, 8) != plan_abi or
        readU64(encoded, 16) != plan_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[192..224], 0))
        return Error.InvalidPlan;
    const value: GeneratedImagePlanV1 = .{
        .request_epoch = readU64(encoded, 32),
        .generation = readU64(encoded, 40),
        .image_index = readU64(encoded, 48),
        .source_step = readU64(encoded, 56),
        .width = readU64(encoded, 64),
        .height = readU64(encoded, 72),
        .channels = readU64(encoded, 80),
        .row_stride = readU64(encoded, 88),
        .latent_bytes = readU64(encoded, 96),
        .pixel_bytes = readU64(encoded, 104),
        .maximum_output_bytes = readU64(encoded, 112),
        .decoder_abi = readU64(encoded, 120),
        .color_model = std.meta.intToEnum(
            ColorModelV1,
            readU64(encoded, 128),
        ) catch return Error.InvalidPlan,
        .transfer_function = std.meta.intToEnum(
            TransferFunctionV1,
            readU64(encoded, 136),
        ) catch return Error.InvalidPlan,
        .alpha_mode = std.meta.intToEnum(
            AlphaModeV1,
            readU64(encoded, 144),
        ) catch return Error.InvalidPlan,
        .publication_sequence = readU64(encoded, 152),
        .visible_images_before = readU64(encoded, 160),
        .visible_images_after = readU64(encoded, 168),
        .logical_units = readU64(encoded, 176),
        .required_capabilities = readU64(encoded, 184),
        .artifact_sha256 = encoded[224..256].*,
        .terminal_result_sha256 = encoded[256..288].*,
        .terminal_plan_sha256 = encoded[288..320].*,
        .terminal_output_sha256 = encoded[320..352].*,
        .terminal_state_publication_sha256 = encoded[352..384].*,
        .stateful_checkpoint_sha256 = encoded[384..416].*,
        .decoder_payload_sha256 = encoded[416..448].*,
        .decoder_implementation_sha256 = encoded[448..480].*,
        .tenant_scope_sha256 = encoded[480..512].*,
        .metadata_policy_sha256 = encoded[512..544].*,
        .source_provenance_sha256 = encoded[544..576].*,
        .challenge_sha256 = encoded[576..608].*,
        .previous_plan_sha256 = encoded[608..640].*,
        .previous_result_sha256 = encoded[640..672].*,
        .media_object_sha256 = encoded[672..704].*,
        .plan_sha256 = encoded[704..736].*,
    };
    try validateGeneratedImagePlanV1(value);
    var canonical: [plan_bytes]u8 = undefined;
    _ = try encodeGeneratedImagePlanV1(value, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidPlan;
    return value;
}

pub fn encodeGeneratedImageProvenanceV1(
    value: GeneratedImageProvenanceV1,
    output: *[provenance_bytes]u8,
) Error![]const u8 {
    try validateGeneratedImageProvenanceV1(value);
    writeProvenanceBodyV1(
        value,
        output[0..provenance_body_bytes],
    );
    @memcpy(
        output[provenance_body_bytes..],
        &value.provenance_sha256,
    );
    return output;
}

pub fn decodeGeneratedImageProvenanceV1(
    encoded: []const u8,
) Error!GeneratedImageProvenanceV1 {
    if (encoded.len != provenance_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &provenance_magic,
        ) or
        readU64(encoded, 8) != provenance_abi or
        readU64(encoded, 16) != provenance_bytes or
        readU64(encoded, 24) != allowed_flags)
        return Error.InvalidProvenance;
    const value: GeneratedImageProvenanceV1 = .{
        .request_epoch = readU64(encoded, 32),
        .generation = readU64(encoded, 40),
        .image_index = readU64(encoded, 48),
        .source_step = readU64(encoded, 56),
        .width = readU64(encoded, 64),
        .height = readU64(encoded, 72),
        .channels = readU64(encoded, 80),
        .pixel_bytes = readU64(encoded, 88),
        .decoder_abi = readU64(encoded, 96),
        .color_model = std.meta.intToEnum(
            ColorModelV1,
            readU64(encoded, 104),
        ) catch return Error.InvalidProvenance,
        .transfer_function = std.meta.intToEnum(
            TransferFunctionV1,
            readU64(encoded, 112),
        ) catch return Error.InvalidProvenance,
        .alpha_mode = std.meta.intToEnum(
            AlphaModeV1,
            readU64(encoded, 120),
        ) catch return Error.InvalidProvenance,
        .plan_sha256 = encoded[128..160].*,
        .artifact_sha256 = encoded[160..192].*,
        .terminal_result_sha256 = encoded[192..224].*,
        .terminal_plan_sha256 = encoded[224..256].*,
        .terminal_output_sha256 = encoded[256..288].*,
        .terminal_state_publication_sha256 = encoded[288..320].*,
        .stateful_checkpoint_sha256 = encoded[320..352].*,
        .decoder_payload_sha256 = encoded[352..384].*,
        .decoder_implementation_sha256 = encoded[384..416].*,
        .media_object_sha256 = encoded[416..448].*,
        .output_sha256 = encoded[448..480].*,
        .tenant_scope_sha256 = encoded[480..512].*,
        .metadata_policy_sha256 = encoded[512..544].*,
        .source_provenance_sha256 = encoded[544..576].*,
        .challenge_sha256 = encoded[576..608].*,
        .provenance_sha256 = encoded[608..640].*,
    };
    try validateGeneratedImageProvenanceV1(value);
    var canonical: [provenance_bytes]u8 = undefined;
    _ = try encodeGeneratedImageProvenanceV1(
        value,
        &canonical,
    );
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidProvenance;
    return value;
}

pub fn encodeGeneratedImageResultV1(
    value: GeneratedImageResultV1,
    output: *[result_bytes]u8,
) Error![]const u8 {
    try validateGeneratedImageResultV1(value);
    writeResultBodyV1(value, output[0..result_body_bytes]);
    @memcpy(output[result_body_bytes..], &value.result_sha256);
    return output;
}

pub fn decodeGeneratedImageResultV1(
    encoded: []const u8,
) Error!GeneratedImageResultV1 {
    if (encoded.len != result_bytes or
        !std.mem.eql(u8, encoded[0..8], &result_magic) or
        readU64(encoded, 8) != result_abi or
        readU64(encoded, 16) != result_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[144..160], 0))
        return Error.InvalidResult;
    const value: GeneratedImageResultV1 = .{
        .request_epoch = readU64(encoded, 32),
        .generation = readU64(encoded, 40),
        .image_index = readU64(encoded, 48),
        .source_step = readU64(encoded, 56),
        .width = readU64(encoded, 64),
        .height = readU64(encoded, 72),
        .channels = readU64(encoded, 80),
        .row_stride = readU64(encoded, 88),
        .pixel_bytes = readU64(encoded, 96),
        .publication_sequence = readU64(encoded, 104),
        .visible_images_before = readU64(encoded, 112),
        .visible_images_after = readU64(encoded, 120),
        .logical_units = readU64(encoded, 128),
        .decoder_abi = readU64(encoded, 136),
        .plan_sha256 = encoded[160..192].*,
        .provenance_sha256 = encoded[192..224].*,
        .artifact_sha256 = encoded[224..256].*,
        .terminal_result_sha256 = encoded[256..288].*,
        .terminal_output_sha256 = encoded[288..320].*,
        .terminal_state_publication_sha256 = encoded[320..352].*,
        .media_object_sha256 = encoded[352..384].*,
        .output_sha256 = encoded[384..416].*,
        .resource_receipt_sha256 = encoded[416..448].*,
        .publication_state_before_sha256 = encoded[448..480].*,
        .timeline_event_sha256 = encoded[480..512].*,
        .media_commit_sha256 = encoded[512..544].*,
        .publication_state_after_sha256 = encoded[544..576].*,
        .previous_result_sha256 = encoded[576..608].*,
        .decoder_implementation_sha256 = encoded[608..640].*,
        .challenge_sha256 = encoded[640..672].*,
        .result_sha256 = encoded[672..704].*,
    };
    try validateGeneratedImageResultV1(value);
    var canonical: [result_bytes]u8 = undefined;
    _ = try encodeGeneratedImageResultV1(value, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidResult;
    return value;
}

pub fn generatedImagePlanRootV1(
    plan: GeneratedImagePlanV1,
) Digest {
    var body: [plan_body_bytes]u8 = undefined;
    writePlanBodyV1(plan, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn generatedImageProvenanceRootV1(
    value: GeneratedImageProvenanceV1,
) Digest {
    var body: [provenance_body_bytes]u8 = undefined;
    writeProvenanceBodyV1(value, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(provenance_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn generatedImageResultRootV1(
    value: GeneratedImageResultV1,
) Digest {
    var body: [result_body_bytes]u8 = undefined;
    writeResultBodyV1(value, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(result_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn claimForPlanV1(
    plan: GeneratedImagePlanV1,
    decoder_payload_bytes: u64,
) Error!resource_bank.Claim {
    try validateGeneratedImagePlanV1(plan);
    if (decoder_payload_bytes == 0)
        return Error.InvalidPlan;
    const private_bytes = try checkedAdd(
        plan.pixel_bytes,
        provenance_bytes + result_bytes,
    );
    return .{
        .capsule_bytes = decoder_payload_bytes,
        .activation_bytes = plan.latent_bytes,
        .partial_bytes = private_bytes,
        .output_journal_bytes = private_bytes,
        .queue_slots = 1,
    };
}

pub fn timelineEventForPlanV1(
    plan: GeneratedImagePlanV1,
    publication_state: media.PublicationStateV1,
) Error!media.TimelineEventV1 {
    try validateGeneratedImagePlanV1(plan);
    const base: media.TimeBaseV1 = .{
        .numerator = 1,
        .denominator = 1,
    };
    const event: media.TimelineEventV1 = .{
        .kind = .identity,
        .sequence = plan.publication_sequence,
        .media_object_sha256 = plan.media_object_sha256,
        .source = .{
            .start = .{ .ticks = 0, .base = base },
            .end = .{
                .ticks = plan.logical_units,
                .base = base,
            },
        },
        .target = .{
            .start = .{
                .ticks = publication_state.visible_units,
                .base = base,
            },
            .end = .{
                .ticks = try checkedAdd(
                    publication_state.visible_units,
                    plan.logical_units,
                ),
                .base = base,
            },
        },
        .plan_sha256 = plan.plan_sha256,
        .previous_event_sha256 = publication_state.timeline_sha256,
    };
    _ = try media.timelineEventRootV1(event);
    return event;
}

pub fn resourceReceiptRootV1(
    receipt: resource_bank.Receipt,
    request_epoch: u64,
    plan_sha256: Digest,
    decoder_implementation_sha256: Digest,
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
    hash.update(&plan_sha256);
    hash.update(&decoder_implementation_sha256);
    return hash.finalResult();
}

pub fn referenceDecoderV1(
    context: *anyopaque,
) DecoderV1 {
    return .{
        .decoder_abi = reference_decoder_abi,
        .maximum_latent_bytes = reference_terminal_latent.len,
        .maximum_output_bytes = reference_pixels.len,
        .required_capabilities = 0,
        .implementation_sha256 = model.sha256("reference exact latent-to-gray8 decoder v1"),
        .context = context,
        .execute = referenceDecodeV1,
        .validate = validateReferenceDecodeV1,
    };
}

pub fn referenceDecodeV1(
    context: *anyopaque,
    plan: *const GeneratedImagePlanV1,
    terminal_latent: []const u8,
    decoder_payload: []const u8,
    candidate_output: []u8,
) anyerror!void {
    _ = context;
    if (terminal_latent.len != plan.latent_bytes or
        decoder_payload.len != terminal_latent.len or
        candidate_output.len != plan.pixel_bytes or
        candidate_output.len != terminal_latent.len)
        return Error.CandidateInvalid;
    for (
        terminal_latent,
        decoder_payload,
        candidate_output,
    ) |latent_value, weight, *pixel| {
        pixel.* = std.math.mul(
            u8,
            latent_value,
            weight,
        ) catch return Error.CandidateInvalid;
    }
}

pub fn validateReferenceDecodeV1(
    context: *anyopaque,
    plan: *const GeneratedImagePlanV1,
    terminal_latent: []const u8,
    decoder_payload: []const u8,
    candidate_output: []const u8,
) anyerror!void {
    if (candidate_output.len != plan.pixel_bytes)
        return Error.CandidateInvalid;
    var expected: [reference_pixels.len]u8 = undefined;
    if (candidate_output.len != expected.len)
        return Error.CandidateInvalid;
    try referenceDecodeV1(
        context,
        plan,
        terminal_latent,
        decoder_payload,
        &expected,
    );
    if (!std.mem.eql(u8, candidate_output, &expected))
        return Error.CandidateInvalid;
}

pub const ReferenceFixtureV1 = struct {
    manifest: model.ArtifactManifestV1,
    checkpoint: continuation.CheckpointV1,
    terminal_plan: model.ExecutionPlanV1,
    terminal_result: model.ResultEnvelopeV1,
    terminal_state_publication: stateful.StatePublicationV1,
    terminal_latent: [reference_terminal_latent.len]u8,
    media_object: media.MediaObjectV1,
    publication_state: media.PublicationStateV1,
    plan: GeneratedImagePlanV1,
};

pub fn makeReferenceFixtureV1(
    source_bank: *resource_bank.Bank,
    target_bank: *resource_bank.Bank,
    decoder_context: *anyopaque,
) Error!ReferenceFixtureV1 {
    if (source_bank.epoch == target_bank.epoch)
        return Error.InvalidBinding;
    var fixture = try latent.makeReferenceFixtureV1();
    var context: u8 = 1;
    const latent_adapter =
        try latent.referenceAdapterV1(
            fixture.manifest,
            &context,
        );
    var source_session: latent.Session = .{};
    try source_session.initV1(
        source_bank,
        121_101,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        fixture.plan,
        latent_adapter,
    );
    var first_candidate_output: [reference_terminal_latent.len]u8 = undefined;
    var first_candidate_state: [reference_terminal_latent.len]u8 = undefined;
    var first_visible_output: [reference_terminal_latent.len]u8 = undefined;
    var first_visible_state: [reference_terminal_latent.len]u8 = undefined;
    _ = try source_session.prepareV1(
        &latent.reference_weights,
        &latent.reference_conditioning,
        &latent.reference_initial_state,
        &first_candidate_output,
        &first_candidate_state,
        &first_visible_output,
        &first_visible_state,
    );
    const first_result =
        try source_session.commitV1();
    const checkpoint =
        try continuation.makeCheckpointV1(
            source_bank.epoch,
            .{
                .restore_bank_epoch = target_bank.epoch,
                .restore_owner_key = 122_101,
                .restore_tree_key = 122_201,
                .restore_authority_key = 122_301,
                .tenant_key = 122_401,
                .scope_key = 122_501,
                .allocation_key = 122_601,
                .binding_key = 122_701,
            },
            fixture.model_publication,
            fixture.state_publication,
            first_result,
        );
    var checkpoint_wire: [continuation.checkpoint_bytes]u8 = undefined;
    _ = try continuation.encodeCheckpointV1(
        checkpoint,
        &checkpoint_wire,
    );
    var intermediate_publication_wire: [stateful.state_publication_bytes]u8 = undefined;
    _ = try stateful.encodeStatePublicationV1(
        fixture.state_publication,
        &intermediate_publication_wire,
    );
    try source_session.closeAndRelease();
    if (!(try source_bank.snapshotV3()).used.isZero())
        return Error.InvalidState;
    var resumed: continuation.ResumeSession = .{};
    try resumed.prepareV1(
        target_bank,
        &checkpoint_wire,
        &intermediate_publication_wire,
    );
    var restored_state: [reference_terminal_latent.len]u8 = undefined;
    try resumed.commitMaterializedV1(
        &first_visible_state,
        &restored_state,
    );
    const terminal_plan =
        try latent.makeReferencePlanV1(
            fixture.manifest,
            resumed.model_publication,
            resumed.state_publication,
            checkpoint.last_plan_sha256,
        );
    var terminal_session: latent.Session = .{};
    try terminal_session.initV1(
        target_bank,
        123_001,
        &resumed.model_publication,
        &resumed.state_publication,
        fixture.manifest,
        terminal_plan,
        latent_adapter,
    );
    var terminal_candidate_output: [reference_terminal_latent.len]u8 = undefined;
    var terminal_candidate_state: [reference_terminal_latent.len]u8 = undefined;
    var terminal_output: [reference_terminal_latent.len]u8 = undefined;
    var terminal_state: [reference_terminal_latent.len]u8 = undefined;
    _ = try terminal_session.prepareV1(
        &latent.reference_weights,
        &latent.reference_conditioning,
        &restored_state,
        &terminal_candidate_output,
        &terminal_candidate_state,
        &terminal_output,
        &terminal_state,
    );
    const terminal_result =
        try terminal_session.commitV1();
    if (!std.mem.eql(
        u8,
        &terminal_output,
        &reference_terminal_latent,
    ))
        return Error.CandidateInvalid;
    const terminal_state_publication =
        resumed.state_publication;
    try resumed.closeAndRelease();
    try terminal_session.closeAndRelease();
    if (!(try target_bank.snapshotV3()).used.isZero())
        return Error.InvalidState;
    const decoder = referenceDecoderV1(
        decoder_context,
    );
    const tenant_scope_sha256 =
        model.sha256("generated image tenant");
    const metadata_policy_sha256 =
        model.sha256("generated image metadata policy");
    const decoder_payload_sha256 =
        model.sha256(&reference_decoder_payload);
    const source_provenance_sha256 =
        sourceProvenanceRootV1(
            fixture.manifest,
            checkpoint,
            terminal_plan,
            terminal_result,
            terminal_state_publication,
            decoder_payload_sha256,
            decoder.implementation_sha256,
            tenant_scope_sha256,
            metadata_policy_sha256,
            terminal_result.challenge_sha256,
        );
    const media_object: media.MediaObjectV1 = .{
        .kind = .image,
        .semantic_abi = raw_image_semantic_abi,
        .byte_length = reference_pixels.len,
        .container_id = raw_container_id,
        .codec_id = interleaved_u8_codec_id,
        .axes = .{ 2, 2, 1 },
        .time_base = .{
            .numerator = 0,
            .denominator = 1,
        },
        .tenant_scope_sha256 = tenant_scope_sha256,
        .content_sha256 = model.sha256(&reference_pixels),
        .metadata_policy_sha256 = metadata_policy_sha256,
        .provenance_sha256 = source_provenance_sha256,
    };
    const media_root = try mediaObjectRootV1(
        media_object,
    );
    const publication_state =
        try media.initializePublicationStateV1(
            terminal_result.request_epoch,
            1,
            .{ .numerator = 1, .denominator = 1 },
            media_root,
            model.sha256(
                "generated image publication genesis",
            ),
        );
    const plan = try makeGeneratedImagePlanV1(
        fixture.manifest,
        checkpoint,
        terminal_plan,
        terminal_result,
        terminal_state_publication,
        media_object,
        &reference_decoder_payload,
        decoder,
        publication_state,
        model.sha256("generated image plan genesis"),
        model.sha256("generated image result genesis"),
    );
    return .{
        .manifest = fixture.manifest,
        .checkpoint = checkpoint,
        .terminal_plan = terminal_plan,
        .terminal_result = terminal_result,
        .terminal_state_publication = terminal_state_publication,
        .terminal_latent = terminal_output,
        .media_object = media_object,
        .publication_state = publication_state,
        .plan = plan,
    };
}

fn mediaObjectRootV1(
    object: media.MediaObjectV1,
) Error!Digest {
    var encoded: [media.descriptor_bytes]u8 = undefined;
    _ = try media.encodeMediaObjectV1(object, &encoded);
    return media.mediaObjectSha256V1(&encoded);
}

fn colorModelForChannels(
    channels: u64,
) Error!ColorModelV1 {
    return switch (channels) {
        1 => .gray,
        3, 4 => .rgb,
        else => Error.InvalidPlan,
    };
}

fn alphaModeForChannels(
    channels: u64,
) Error!AlphaModeV1 {
    return switch (channels) {
        1, 3 => .none,
        4 => .straight,
        else => Error.InvalidPlan,
    };
}

fn validColorShape(
    channels: u64,
    color_model: ColorModelV1,
    alpha_mode: AlphaModeV1,
) bool {
    return switch (channels) {
        1 => color_model == .gray and
            alpha_mode == .none,
        3 => color_model == .rgb and
            alpha_mode == .none,
        4 => color_model == .rgb and
            alpha_mode == .straight,
        else => false,
    };
}

fn buffersDisjoint(
    mutable: []const []u8,
    immutable: []const []const u8,
) bool {
    for (mutable, 0..) |left, left_index| {
        for (mutable[left_index + 1 ..]) |right| {
            if (slicesOverlap(left, right))
                return false;
        }
        for (immutable) |right| {
            if (slicesOverlap(left, right))
                return false;
        }
    }
    return true;
}

fn slicesOverlap(
    left: []const u8,
    right: []const u8,
) bool {
    if (left.len == 0 or right.len == 0)
        return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(
        usize,
        left_start,
        left.len,
    ) catch return true;
    const right_end = std.math.add(
        usize,
        right_start,
        right.len,
    ) catch return true;
    return left_start < right_end and
        right_start < left_end;
}

fn writePlanBodyV1(
    plan: GeneratedImagePlanV1,
    output: *[plan_body_bytes]u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &plan_magic);
    writeU64(output, 8, plan_abi);
    writeU64(output, 16, plan_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        plan.request_epoch,
        plan.generation,
        plan.image_index,
        plan.source_step,
        plan.width,
        plan.height,
        plan.channels,
        plan.row_stride,
        plan.latent_bytes,
        plan.pixel_bytes,
        plan.maximum_output_bytes,
        plan.decoder_abi,
        @intFromEnum(plan.color_model),
        @intFromEnum(plan.transfer_function),
        @intFromEnum(plan.alpha_mode),
        plan.publication_sequence,
        plan.visible_images_before,
        plan.visible_images_after,
        plan.logical_units,
        plan.required_capabilities,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        plan.artifact_sha256,
        plan.terminal_result_sha256,
        plan.terminal_plan_sha256,
        plan.terminal_output_sha256,
        plan.terminal_state_publication_sha256,
        plan.stateful_checkpoint_sha256,
        plan.decoder_payload_sha256,
        plan.decoder_implementation_sha256,
        plan.tenant_scope_sha256,
        plan.metadata_policy_sha256,
        plan.source_provenance_sha256,
        plan.challenge_sha256,
        plan.previous_plan_sha256,
        plan.previous_result_sha256,
        plan.media_object_sha256,
    };
    for (digests, 0..) |digest, index|
        @memcpy(
            output[224 + index * 32 ..][0..32],
            &digest,
        );
}

fn writeProvenanceBodyV1(
    value: GeneratedImageProvenanceV1,
    output: *[provenance_body_bytes]u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &provenance_magic);
    writeU64(output, 8, provenance_abi);
    writeU64(output, 16, provenance_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        value.request_epoch,
        value.generation,
        value.image_index,
        value.source_step,
        value.width,
        value.height,
        value.channels,
        value.pixel_bytes,
        value.decoder_abi,
        @intFromEnum(value.color_model),
        @intFromEnum(value.transfer_function),
        @intFromEnum(value.alpha_mode),
    };
    for (scalars, 0..) |scalar, index|
        writeU64(output, 32 + index * 8, scalar);
    const digests = [_]Digest{
        value.plan_sha256,
        value.artifact_sha256,
        value.terminal_result_sha256,
        value.terminal_plan_sha256,
        value.terminal_output_sha256,
        value.terminal_state_publication_sha256,
        value.stateful_checkpoint_sha256,
        value.decoder_payload_sha256,
        value.decoder_implementation_sha256,
        value.media_object_sha256,
        value.output_sha256,
        value.tenant_scope_sha256,
        value.metadata_policy_sha256,
        value.source_provenance_sha256,
        value.challenge_sha256,
    };
    for (digests, 0..) |digest, index|
        @memcpy(
            output[128 + index * 32 ..][0..32],
            &digest,
        );
}

fn writeResultBodyV1(
    value: GeneratedImageResultV1,
    output: *[result_body_bytes]u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &result_magic);
    writeU64(output, 8, result_abi);
    writeU64(output, 16, result_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        value.request_epoch,
        value.generation,
        value.image_index,
        value.source_step,
        value.width,
        value.height,
        value.channels,
        value.row_stride,
        value.pixel_bytes,
        value.publication_sequence,
        value.visible_images_before,
        value.visible_images_after,
        value.logical_units,
        value.decoder_abi,
    };
    for (scalars, 0..) |scalar, index|
        writeU64(output, 32 + index * 8, scalar);
    const digests = [_]Digest{
        value.plan_sha256,
        value.provenance_sha256,
        value.artifact_sha256,
        value.terminal_result_sha256,
        value.terminal_output_sha256,
        value.terminal_state_publication_sha256,
        value.media_object_sha256,
        value.output_sha256,
        value.resource_receipt_sha256,
        value.publication_state_before_sha256,
        value.timeline_event_sha256,
        value.media_commit_sha256,
        value.publication_state_after_sha256,
        value.previous_result_sha256,
        value.decoder_implementation_sha256,
        value.challenge_sha256,
    };
    for (digests, 0..) |digest, index|
        @memcpy(
            output[160 + index * 32 ..][0..32],
            &digest,
        );
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(
        u64,
        left,
        right,
    ) catch Error.ArithmeticOverflow;
}

fn checkedMul(left: u64, right: u64) Error!u64 {
    return std.math.mul(
        u64,
        left,
        right,
    ) catch Error.ArithmeticOverflow;
}

fn writeU64(
    output: []u8,
    offset: usize,
    value: u64,
) void {
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

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
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

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

const TestStorage = struct {
    slots: [12]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 12,
    roots: [12]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 12,
    nodes: [24]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 24,
};

test "generated image wires are canonical and mutation complete" {
    var source_storage: TestStorage = .{};
    var target_storage: TestStorage = .{};
    var source_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &source_storage.slots,
            &source_storage.roots,
            &source_storage.nodes,
            .{},
            121_001,
        );
    var target_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &target_storage.slots,
            &target_storage.roots,
            &target_storage.nodes,
            .{},
            122_001,
        );
    var decoder_context: u8 = 1;
    var fixture = try makeReferenceFixtureV1(
        &source_bank,
        &target_bank,
        &decoder_context,
    );
    const decoder = referenceDecoderV1(
        &decoder_context,
    );
    var session: Session = .{};
    try session.initV1(
        &target_bank,
        124_001,
        &fixture.publication_state,
        fixture.manifest,
        fixture.checkpoint,
        fixture.terminal_plan,
        fixture.terminal_result,
        fixture.terminal_state_publication,
        fixture.media_object,
        fixture.plan,
        &reference_decoder_payload,
        decoder,
    );
    var candidate_output: [reference_pixels.len]u8 = undefined;
    var candidate_provenance: [provenance_bytes]u8 = undefined;
    var candidate_result: [result_bytes]u8 = undefined;
    var visible_output =
        [_]u8{0} ** reference_pixels.len;
    var visible_provenance =
        [_]u8{0} ** provenance_bytes;
    var visible_result =
        [_]u8{0} ** result_bytes;
    _ = try session.prepareV1(
        &fixture.terminal_latent,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    var plan_wire: [plan_bytes]u8 = undefined;
    _ = try encodeGeneratedImagePlanV1(
        fixture.plan,
        &plan_wire,
    );
    try std.testing.expectEqual(
        fixture.plan,
        try decodeGeneratedImagePlanV1(&plan_wire),
    );
    for (0..plan_wire.len) |index| {
        var mutated = plan_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidPlan,
            decodeGeneratedImagePlanV1(&mutated),
        );
    }
    _ = try decodeGeneratedImageProvenanceV1(
        &candidate_provenance,
    );
    for (0..candidate_provenance.len) |index| {
        var mutated = candidate_provenance;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidProvenance,
            decodeGeneratedImageProvenanceV1(
                &mutated,
            ),
        );
    }
    _ = try decodeGeneratedImageResultV1(
        &candidate_result,
    );
    for (0..candidate_result.len) |index| {
        var mutated = candidate_result;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidResult,
            decodeGeneratedImageResultV1(&mutated),
        );
    }
    try session.abortV1();
    try session.closeAndRelease();
    try std.testing.expect(
        (try source_bank.snapshotV3()).used.isZero(),
    );
    try std.testing.expect(
        (try target_bank.snapshotV3()).used.isZero(),
    );
}

test "terminal latent publishes image and provenance atomically" {
    var source_storage: TestStorage = .{};
    var target_storage: TestStorage = .{};
    var source_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &source_storage.slots,
            &source_storage.roots,
            &source_storage.nodes,
            .{},
            121_001,
        );
    var target_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &target_storage.slots,
            &target_storage.roots,
            &target_storage.nodes,
            .{},
            122_001,
        );
    var decoder_context: u8 = 1;
    var fixture = try makeReferenceFixtureV1(
        &source_bank,
        &target_bank,
        &decoder_context,
    );
    const state_before = fixture.publication_state;
    var session: Session = .{};
    try session.initV1(
        &target_bank,
        124_001,
        &fixture.publication_state,
        fixture.manifest,
        fixture.checkpoint,
        fixture.terminal_plan,
        fixture.terminal_result,
        fixture.terminal_state_publication,
        fixture.media_object,
        fixture.plan,
        &reference_decoder_payload,
        referenceDecoderV1(&decoder_context),
    );
    var candidate_output: [reference_pixels.len]u8 = undefined;
    var candidate_provenance: [provenance_bytes]u8 = undefined;
    var candidate_result: [result_bytes]u8 = undefined;
    var visible_output =
        [_]u8{0xa5} ** reference_pixels.len;
    var visible_provenance =
        [_]u8{0xa5} ** provenance_bytes;
    var visible_result =
        [_]u8{0xa5} ** result_bytes;
    const prepared = try session.prepareV1(
        &fixture.terminal_latent,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    try std.testing.expectEqual(
        state_before,
        fixture.publication_state,
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &visible_output, 0xa5),
    );
    try std.testing.expectEqualSlices(
        u8,
        &reference_pixels,
        &candidate_output,
    );
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try std.testing.expectEqualSlices(
        u8,
        &reference_pixels,
        &visible_output,
    );
    const provenance =
        try decodeGeneratedImageProvenanceV1(
            &visible_provenance,
        );
    const result = try decodeGeneratedImageResultV1(
        &visible_result,
    );
    var expected_plan_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_plan_sha256,
        "19c59a1a1cdcecb3f3159ea4ac920a197261dd6070e69beb1aff81c15a6f6b02",
    );
    var expected_provenance_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_provenance_sha256,
        "c61c2944db031743f420b675a768fa370921388a01f331138f1b6da392f0516c",
    );
    var expected_result_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_result_sha256,
        "3c45c797c20d2582af287d790ba759fe2bab615e2651c802e2bcbd4b381376e3",
    );
    try std.testing.expectEqual(
        expected_plan_sha256,
        fixture.plan.plan_sha256,
    );
    try std.testing.expectEqual(
        expected_provenance_sha256,
        provenance.provenance_sha256,
    );
    try std.testing.expectEqual(
        expected_result_sha256,
        result.result_sha256,
    );
    try validateGeneratedImageProvenanceBindingsV1(
        fixture.plan,
        provenance,
        fixture.media_object,
    );
    try std.testing.expectEqual(
        provenance.provenance_sha256,
        result.provenance_sha256,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        fixture.publication_state.visible_chunks,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        fixture.publication_state.visible_units,
    );
    try std.testing.expectEqual(
        fixture.media_object.content_sha256,
        result.output_sha256,
    );
    try session.closeAndRelease();
    try std.testing.expect(
        (try source_bank.snapshotV3()).used.isZero(),
    );
    try std.testing.expect(
        (try target_bank.snapshotV3()).used.isZero(),
    );
}

test "generated image abort drift and foreign latent preserve visibility" {
    var source_storage: TestStorage = .{};
    var target_storage: TestStorage = .{};
    var source_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &source_storage.slots,
            &source_storage.roots,
            &source_storage.nodes,
            .{},
            121_001,
        );
    var target_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &target_storage.slots,
            &target_storage.roots,
            &target_storage.nodes,
            .{},
            122_001,
        );
    var decoder_context: u8 = 1;
    var fixture = try makeReferenceFixtureV1(
        &source_bank,
        &target_bank,
        &decoder_context,
    );
    const state_before = fixture.publication_state;
    var session: Session = .{};
    try session.initV1(
        &target_bank,
        124_001,
        &fixture.publication_state,
        fixture.manifest,
        fixture.checkpoint,
        fixture.terminal_plan,
        fixture.terminal_result,
        fixture.terminal_state_publication,
        fixture.media_object,
        fixture.plan,
        &reference_decoder_payload,
        referenceDecoderV1(&decoder_context),
    );
    var candidate_output: [reference_pixels.len]u8 = undefined;
    var candidate_provenance: [provenance_bytes]u8 = undefined;
    var candidate_result: [result_bytes]u8 = undefined;
    var visible_output =
        [_]u8{0x5a} ** reference_pixels.len;
    var visible_provenance =
        [_]u8{0x5a} ** provenance_bytes;
    var visible_result =
        [_]u8{0x5a} ** result_bytes;
    var foreign_latent = fixture.terminal_latent;
    foreign_latent[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidBinding,
        session.prepareV1(
            &foreign_latent,
            &candidate_output,
            &candidate_provenance,
            &candidate_result,
            &visible_output,
            &visible_provenance,
            &visible_result,
        ),
    );
    _ = try session.prepareV1(
        &fixture.terminal_latent,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    candidate_result[160] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expectEqual(
        state_before,
        fixture.publication_state,
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &visible_output, 0x5a),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate_output, 0),
    );
    _ = try session.prepareV1(
        &fixture.terminal_latent,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    try session.abortV1();
    try std.testing.expectEqual(
        state_before,
        fixture.publication_state,
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &visible_result, 0x5a),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate_result, 0),
    );
    try session.closeAndRelease();
    try std.testing.expect(
        (try source_bank.snapshotV3()).used.isZero(),
    );
    try std.testing.expect(
        (try target_bank.snapshotV3()).used.isZero(),
    );
}

test "rehashed terminal lineage substitution rejects before admission" {
    var source_storage: TestStorage = .{};
    var target_storage: TestStorage = .{};
    var source_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &source_storage.slots,
            &source_storage.roots,
            &source_storage.nodes,
            .{},
            121_001,
        );
    var target_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &target_storage.slots,
            &target_storage.roots,
            &target_storage.nodes,
            .{},
            122_001,
        );
    var decoder_context: u8 = 1;
    const fixture = try makeReferenceFixtureV1(
        &source_bank,
        &target_bank,
        &decoder_context,
    );
    var foreign_plan = fixture.plan;
    foreign_plan.terminal_output_sha256 =
        model.sha256("foreign terminal latent");
    foreign_plan.plan_sha256 =
        generatedImagePlanRootV1(foreign_plan);
    try validateGeneratedImagePlanV1(foreign_plan);
    try std.testing.expectError(
        Error.InvalidBinding,
        validateGeneratedImageBindingsV1(
            foreign_plan,
            fixture.manifest,
            fixture.checkpoint,
            fixture.terminal_plan,
            fixture.terminal_result,
            fixture.terminal_state_publication,
            fixture.media_object,
            &reference_decoder_payload,
            referenceDecoderV1(&decoder_context),
            fixture.publication_state,
        ),
    );
    const foreign_provenance =
        try makeGeneratedImageProvenanceV1(
            fixture.plan,
            model.sha256("foreign decoded pixels"),
        );
    try validateGeneratedImageProvenanceV1(
        foreign_provenance,
    );
    try std.testing.expectError(
        Error.InvalidBinding,
        validateGeneratedImageProvenanceBindingsV1(
            fixture.plan,
            foreign_provenance,
            fixture.media_object,
        ),
    );
    try std.testing.expect(
        (try source_bank.snapshotV3()).used.isZero(),
    );
    try std.testing.expect(
        (try target_bank.snapshotV3()).used.isZero(),
    );
}
