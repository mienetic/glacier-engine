//! Exact synthetic latent-denoise step over the stateful model lifecycle.
//!
//! This fixture proves retained-state replacement and typed-result publication
//! as one transaction. It does not claim image quality or production diffusion
//! compatibility.

const std = @import("std");
const model = @import("model_contract.zig");
const stateful = @import("stateful_model_adapter.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const reference_adapter_abi: u64 = 0x474c_4154_0000_0001;
pub const latent_step_support = [_]model.SupportRecordV1{.{
    .family = .image_generation,
    .operation = .diffuse_step,
    .input_kind = .latent_tensor,
    .output_kind = .media_chunk,
    .numerical_policy = .exact_integer,
    .max_batch_items = 1,
    .max_input_features = 1_048_576,
    .max_output_dimensions = 1_048_576,
    .allowed_capabilities = model.no_capabilities,
}};

pub const Error = stateful.Error || error{
    InvalidLatentBinding,
};

pub const AdapterDescriptorV1 = stateful.AdapterDescriptorV1;
pub const AdapterV1 = stateful.AdapterV1;
pub const StatePublicationV1 = stateful.StatePublicationV1;
pub const Phase = stateful.Phase;
pub const reference_weights = [_]u8{2};
pub const reference_conditioning = [_]u8{ 1, 2, 3, 4 };
pub const reference_initial_state = [_]u8{ 10, 20, 30, 40 };
pub const reference_request_epoch: u64 = 301;

pub const ReferenceFixtureV1 = struct {
    manifest: model.ArtifactManifestV1,
    model_publication: model.PublicationStateV1,
    state_publication: StatePublicationV1,
    plan: model.ExecutionPlanV1,
};

pub const Session = struct {
    inner: stateful.Session = .{},

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        model_publication: *model.PublicationStateV1,
        state_publication: *StatePublicationV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        adapter: AdapterV1,
    ) Error!void {
        try validateLatentAdapterV1(
            adapter,
            manifest,
            plan,
            state_publication.*,
        );
        try self.inner.initV1(
            bank,
            owner_key,
            model_publication,
            state_publication,
            manifest,
            plan,
            adapter,
            &latent_step_support,
        );
    }

    pub fn prepareV1(
        self: *Session,
        weights: []const u8,
        conditioning: []const u8,
        current_state: []const u8,
        candidate_output: []u8,
        candidate_state: []u8,
        visible_output: []u8,
        visible_next_state: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateLatentBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            self.inner.state_publication.*,
            conditioning,
            current_state,
        );
        return self.inner.prepareV1(
            weights,
            conditioning,
            current_state,
            candidate_output,
            candidate_state,
            visible_output,
            visible_next_state,
        );
    }

    pub fn commitV1(self: *Session) Error!model.ResultEnvelopeV1 {
        return self.inner.commitV1();
    }

    pub fn abortV1(self: *Session) Error!void {
        return self.inner.abortV1();
    }

    pub fn closeAndRelease(self: *Session) Error!void {
        return self.inner.closeAndRelease();
    }
};

pub fn makeAdapterDescriptorV1(
    manifest: model.ArtifactManifestV1,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    try validateLatentManifestV1(manifest);
    return stateful.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .diffuse_step,
        model.no_capabilities,
        implementation_sha256,
    );
}

pub fn makeReferenceFixtureV1() Error!ReferenceFixtureV1 {
    const manifest = try model.makeArtifactManifestV1(
        .image_generation,
        0x4c41_5445_4e54_0001,
        .latent_tensor,
        .media_chunk,
        .exact_integer,
        1,
        reference_initial_state.len,
        reference_initial_state.len,
        1,
        1,
        1,
        &reference_weights,
        model.sha256("latent step fixture metadata"),
        model.sha256("fixture-only license"),
    );
    const state_publication =
        try stateful.initializeStatePublicationV1(
            reference_request_epoch,
            2,
            reference_initial_state.len,
            manifest.artifact_sha256,
            model.sha256(&reference_initial_state),
            referenceChallengeV1(),
        );
    const model_publication =
        try model.initializePublicationStateV1(
            reference_request_epoch,
            manifest.artifact_sha256,
        );
    return .{
        .manifest = manifest,
        .model_publication = model_publication,
        .state_publication = state_publication,
        .plan = try makeReferencePlanV1(
            manifest,
            model_publication,
            state_publication,
            referenceGenesisPlanRootV1(),
        ),
    };
}

pub fn referenceChallengeV1() Digest {
    return model.sha256("latent step challenge");
}

pub fn referenceGenesisPlanRootV1() Digest {
    return model.sha256("latent genesis plan");
}

pub fn makeReferencePlanV1(
    manifest: model.ArtifactManifestV1,
    model_publication: model.PublicationStateV1,
    state_publication: StatePublicationV1,
    previous_plan_sha256: Digest,
) Error!model.ExecutionPlanV1 {
    try validateLatentManifestV1(manifest);
    try stateful.validateStatePublicationV1(state_publication);
    const generation = std.math.add(
        u64,
        state_publication.current_step,
        1,
    ) catch return Error.InvalidLatentBinding;
    if (state_publication.current_step >=
        state_publication.total_steps or
        model_publication.request_epoch !=
            state_publication.request_epoch or
        model_publication.next_sequence !=
            state_publication.current_step or
        model_publication.visible_results !=
            state_publication.current_step or
        !std.mem.eql(
            u8,
            &model_publication.artifact_sha256,
            &manifest.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &model_publication.previous_result_sha256,
            &state_publication.previous_result_sha256,
        ) or
        std.mem.allEqual(u8, &previous_plan_sha256, 0))
        return Error.InvalidLatentBinding;
    const state_bytes = state_publication.state_bytes;
    const publication_bytes = std.math.mul(
        u64,
        state_bytes,
        2,
    ) catch return Error.InvalidLatentBinding;
    return model.makeExecutionPlanV1(
        manifest,
        .diffuse_step,
        .{
            .request_epoch = state_publication.request_epoch,
            .generation = generation,
            .batch_items = 1,
            .publication_next_sequence = model_publication.next_sequence,
            .maximum_absolute_output = 255,
            .claim = .{
                .capsule_bytes = manifest.weight_bytes,
                .activation_bytes = state_bytes,
                .partial_bytes = state_bytes,
                .output_journal_bytes = publication_bytes,
                .staging_bytes = state_bytes,
                .queue_slots = 1,
            },
            .media_object_sha256 = model.sha256(
                "latent target image",
            ),
            .processor_state_sha256 = state_publication.publication_sha256,
            .processor_bundle_sha256 = model.sha256(
                "latent scheduler bundle",
            ),
            .cache_bundle_sha256 = model.sha256(
                "latent cache bundle",
            ),
            .cache_payload_sha256 = state_publication.current_state_sha256,
            .ownership_sha256 = model.sha256(
                "latent state ownership",
            ),
            .challenge_sha256 = state_publication.challenge_sha256,
            .previous_plan_sha256 = previous_plan_sha256,
            .input_schema_sha256 = model.sha256(
                "four u8 conditioning deltas",
            ),
            .output_schema_sha256 = model.sha256(
                "four u8 next latent",
            ),
            .scratch_bytes = state_bytes,
        },
    );
}

pub fn referenceAdapterV1(
    manifest: model.ArtifactManifestV1,
    context: *anyopaque,
) Error!AdapterV1 {
    return .{
        .context = context,
        .descriptor = try makeAdapterDescriptorV1(
            manifest,
            model.sha256("reference exact latent denoise v1"),
        ),
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateCandidateV1,
    };
}

pub fn validateLatentAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    state_publication: StatePublicationV1,
) Error!void {
    try validateLatentManifestV1(manifest);
    try stateful.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &latent_step_support,
    );
    try validateLatentPlanV1(
        manifest,
        plan,
        state_publication,
    );
}

fn validateLatentManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    if (manifest.family != .image_generation or
        manifest.input_kind != .latent_tensor or
        manifest.output_kind != .media_chunk or
        manifest.numerical_policy != .exact_integer or
        manifest.max_batch_items != 1 or
        manifest.input_features != manifest.output_dimensions or
        manifest.input_element_bytes != @sizeOf(u8) or
        manifest.output_element_bytes != @sizeOf(u8) or
        manifest.weight_element_bytes != @sizeOf(u8) or
        manifest.weight_elements != 1 or manifest.weight_bytes != 1)
        return Error.InvalidLatentBinding;
}

fn validateLatentPlanV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    state_publication: StatePublicationV1,
) Error!void {
    try stateful.validateStatePublicationV1(state_publication);
    if (plan.family != .image_generation or
        plan.operation != .diffuse_step or
        plan.input_kind != .latent_tensor or
        plan.output_kind != .media_chunk or
        plan.numerical_policy != .exact_integer or
        plan.batch_items != 1 or
        plan.input_features != manifest.input_features or
        plan.output_dimensions != manifest.output_dimensions or
        plan.input_bytes != state_publication.state_bytes or
        plan.output_bytes != state_publication.state_bytes or
        plan.required_capabilities != model.no_capabilities or
        !std.mem.eql(
            u8,
            &plan.artifact_sha256,
            &state_publication.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.challenge_sha256,
            &state_publication.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.processor_state_sha256,
            &state_publication.publication_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.cache_payload_sha256,
            &state_publication.current_state_sha256,
        ))
        return Error.InvalidLatentBinding;
}

pub fn validateLatentBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    state_publication: StatePublicationV1,
    conditioning: []const u8,
    current_state: []const u8,
) Error!void {
    try validateLatentManifestV1(manifest);
    try validateLatentPlanV1(manifest, plan, state_publication);
    if (conditioning.len != plan.input_bytes or
        current_state.len != state_publication.state_bytes or
        !std.mem.eql(
            u8,
            &model.sha256(current_state),
            &state_publication.current_state_sha256,
        ))
        return Error.InvalidLatentBinding;
}

pub fn referenceExecuteV1(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    conditioning: []const u8,
    current_state: []const u8,
    candidate_output: []u8,
    candidate_state: []u8,
) anyerror!void {
    _ = context;
    if (weights.len != 1 or conditioning.len != plan.input_bytes or
        current_state.len != plan.output_bytes or
        candidate_output.len != plan.output_bytes or
        candidate_state.len != plan.output_bytes)
        return Error.InvalidLatentBinding;
    for (
        current_state,
        conditioning,
        candidate_state,
        candidate_output,
    ) |current, condition, *next_state, *output| {
        const delta = std.math.mul(
            u16,
            condition,
            weights[0],
        ) catch return Error.CandidateInvalid;
        if (delta > current) return Error.CandidateInvalid;
        const next: u8 = @intCast(current - delta);
        next_state.* = next;
        output.* = next;
    }
}

pub fn validateCandidateV1(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    current_state: []const u8,
    candidate_output: []const u8,
    candidate_state: []const u8,
) anyerror!void {
    _ = context;
    if (current_state.len != plan.output_bytes or
        candidate_output.len != plan.output_bytes or
        candidate_state.len != plan.output_bytes or
        !std.mem.eql(u8, candidate_output, candidate_state))
        return Error.CandidateInvalid;
    for (current_state, candidate_state) |current, next| {
        if (next > current or next > plan.maximum_absolute_output)
            return Error.CandidateInvalid;
    }
}

const TestFixture = struct {
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    model_publication: model.PublicationStateV1,
    state_publication: StatePublicationV1,
    weights: [1]u8,
    conditioning: [4]u8,
    current_state: [4]u8,

    fn init() !TestFixture {
        const reference = try makeReferenceFixtureV1();
        return .{
            .manifest = reference.manifest,
            .plan = reference.plan,
            .model_publication = reference.model_publication,
            .state_publication = reference.state_publication,
            .weights = reference_weights,
            .conditioning = reference_conditioning,
            .current_state = reference_initial_state,
        };
    }
};

const TestRuntime = struct {
    slots: [4]resource_bank.Slot = [_]resource_bank.Slot{.{}} ** 4,
    roots: [4]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 4,
    nodes: [8]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 8,
};

fn testAdapter(
    fixture: *const TestFixture,
    context: *u8,
) !AdapterV1 {
    return referenceAdapterV1(fixture.manifest, context);
}

test "state publication wire is canonical and mutation complete" {
    const fixture = try TestFixture.init();
    var expected_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_root,
        "7f337b3f2ff044d1222f42da227b7a98" ++
            "1c25661019ba91b76ec30a53fcc304d2",
    );
    try std.testing.expectEqual(
        expected_root,
        fixture.state_publication.publication_sha256,
    );
    var encoded: [stateful.state_publication_bytes]u8 = undefined;
    _ = try stateful.encodeStatePublicationV1(
        fixture.state_publication,
        &encoded,
    );
    try std.testing.expectEqual(
        fixture.state_publication,
        try stateful.decodeStatePublicationV1(&encoded),
    );
    for (0..encoded.len) |index| {
        var mutated = encoded;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidStatePublication,
            stateful.decodeStatePublicationV1(&mutated),
        );
    }
}

test "latent step publishes result and retained state atomically" {
    var fixture = try TestFixture.init();
    var storage: TestRuntime = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        301,
    );
    var context: u8 = 1;
    const adapter = try testAdapter(&fixture, &context);
    var session: Session = .{};
    try session.initV1(
        &bank,
        50_000,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate_output: [4]u8 = undefined;
    var candidate_state: [4]u8 = undefined;
    var visible_output = [_]u8{0xa5} ** 4;
    var visible_next_state = [_]u8{0x5a} ** 4;
    const visible_output_before = visible_output;
    const visible_state_before = visible_next_state;
    const before = fixture.current_state;
    const prepared = try session.prepareV1(
        &fixture.weights,
        &fixture.conditioning,
        &fixture.current_state,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_next_state,
    );
    var expected_transition: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_transition,
        "efb7f3d05dc3c396756fcd53f38b8118" ++
            "ca286bff150733a6eb06b3dc0636a4db",
    );
    try std.testing.expectEqual(
        expected_transition,
        prepared.source_mapping_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &before,
        &fixture.current_state,
    );
    try std.testing.expectEqualSlices(
        u8,
        &visible_output_before,
        &visible_output,
    );
    try std.testing.expectEqualSlices(
        u8,
        &visible_state_before,
        &visible_next_state,
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 8, 16, 24, 32 },
        &candidate_state,
    );
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 8, 16, 24, 32 },
        &visible_next_state,
    );
    try std.testing.expectEqualSlices(
        u8,
        &visible_next_state,
        &visible_output,
    );
    try std.testing.expectEqualSlices(
        u8,
        &before,
        &fixture.current_state,
    );
    try std.testing.expectEqual(
        model.sha256(&visible_next_state),
        fixture.state_publication.current_state_sha256,
    );
    try stateful.validateStatePublicationV1(
        fixture.state_publication,
    );
    try std.testing.expect(std.mem.allEqual(u8, &candidate_output, 0));
    try std.testing.expect(std.mem.allEqual(u8, &candidate_state, 0));
    try std.testing.expectEqual(
        @as(u64, 1),
        fixture.state_publication.current_step,
    );
    try std.testing.expectEqual(
        committed.result_sha256,
        fixture.state_publication.previous_result_sha256,
    );
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}

test "latent step abort alias and drift preserve retained state" {
    var fixture = try TestFixture.init();
    var storage: TestRuntime = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        302,
    );
    var context: u8 = 1;
    const adapter = try testAdapter(&fixture, &context);
    var session: Session = .{};
    try session.initV1(
        &bank,
        50_001,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate_output: [4]u8 = undefined;
    var candidate_state: [4]u8 = undefined;
    var visible_output = [_]u8{0xa5} ** 4;
    var visible_next_state = [_]u8{0x5a} ** 4;
    const visible_output_before = visible_output;
    const visible_state_before = visible_next_state;
    const model_publication_before = fixture.model_publication;
    fixture.model_publication.next_sequence = 1;
    fixture.model_publication.visible_results = 1;
    fixture.model_publication.previous_result_sha256 =
        model.sha256("foreign previous result");
    try std.testing.expectError(
        Error.InvalidBinding,
        session.prepareV1(
            &fixture.weights,
            &fixture.conditioning,
            &fixture.current_state,
            &candidate_output,
            &candidate_state,
            &visible_output,
            &visible_next_state,
        ),
    );
    fixture.model_publication = model_publication_before;
    try std.testing.expectError(
        Error.InvalidBinding,
        session.prepareV1(
            &fixture.weights,
            &fixture.conditioning,
            &fixture.current_state,
            &candidate_output,
            &candidate_state,
            &candidate_output,
            &visible_next_state,
        ),
    );
    _ = try session.prepareV1(
        &fixture.weights,
        &fixture.conditioning,
        &fixture.current_state,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_next_state,
    );
    try session.abortV1();
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 10, 20, 30, 40 },
        &fixture.current_state,
    );
    try std.testing.expectEqualSlices(
        u8,
        &visible_output_before,
        &visible_output,
    );
    try std.testing.expectEqualSlices(
        u8,
        &visible_state_before,
        &visible_next_state,
    );
    _ = try session.prepareV1(
        &fixture.weights,
        &fixture.conditioning,
        &fixture.current_state,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_next_state,
    );
    candidate_state[0] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 10, 20, 30, 40 },
        &fixture.current_state,
    );
    try std.testing.expectEqualSlices(
        u8,
        &visible_output_before,
        &visible_output,
    );
    try std.testing.expectEqualSlices(
        u8,
        &visible_state_before,
        &visible_next_state,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.state_publication.current_step,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.model_publication.visible_results,
    );
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}
