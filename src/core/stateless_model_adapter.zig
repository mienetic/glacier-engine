//! Shared prepare/validate/publish lifecycle for stateless model adapters.
//!
//! Family-specific modules must validate their source/state/cache bindings
//! before entering this lifecycle. The backend receives only bounded slices.

const std = @import("std");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
const descriptor_domain = "glacier-stateless-model-adapter-v1\x00";

pub const Error = model.Error || resource_bank.Error || error{
    InvalidAdapter,
    InvalidBinding,
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
        var next_state = self.publication_state.*;
        model.commitResultV1(&next_state, result) catch {
            try self.rollbackV1(permit);
            return Error.InvalidBinding;
        };
        @memcpy(visible_output, candidate);
        self.publication_state.* = next_state;
        self.bank.commitPublicationAssumeValid(permit);
        self.next_resource_sequence = permit.sequence + 1;
        @memset(candidate, 0);
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
