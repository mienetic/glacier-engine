//! Typed audio-window encoder over live processor-cache ownership.
//!
//! The retained backend is an exact signed-integer fixture. It exercises
//! sample/window/hop lineage and stateless publication, not speech quality.

const std = @import("std");
const media = @import("media_contract.zig");
const processor = @import("media_processor_state.zig");
const processor_cache = @import("media_processor_cache.zig");
const model = @import("model_contract.zig");
const stateless = @import("stateless_model_adapter.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const reference_adapter_abi: u64 = 0x4741_5745_0000_0001;
pub const audio_support = [_]model.SupportRecordV1{.{
    .family = .audio_understanding,
    .operation = .encode,
    .input_kind = .audio_feature_i16,
    .output_kind = .embedding_i32,
    .numerical_policy = .exact_integer,
    .max_batch_items = 4_096,
    .max_input_features = 16_384,
    .max_output_dimensions = 16_384,
    .allowed_capabilities = model.no_capabilities,
}};

const source_mapping_domain =
    "glacier-audio-window-source-mapping-v1\x00";

pub const Error = stateless.Error || processor.Error ||
    processor_cache.Error || error{
    InvalidAudioBinding,
};

pub const AdapterDescriptorV1 = stateless.AdapterDescriptorV1;
pub const AdapterV1 = stateless.AdapterV1;
pub const Phase = stateless.Phase;

pub const Session = struct {
    inner: stateless.Session = .{},

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        publication_state: *model.PublicationStateV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        adapter: AdapterV1,
    ) Error!void {
        try validateAudioAdapterV1(adapter, manifest, plan);
        try self.inner.initV1(
            bank,
            owner_key,
            publication_state,
            manifest,
            plan,
            adapter,
            &audio_support,
        );
    }

    pub fn prepareV1(
        self: *Session,
        processor_bundle: *const processor.DecodedBundleV1,
        cache_bundle: *const processor_cache.DecodedBundleV1,
        cache_session: *const processor_cache.RestoreSession,
        weights: []const u8,
        audio_features: []const u8,
        candidate: []u8,
        visible_output: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateAudioBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            processor_bundle,
            cache_bundle,
            audio_features,
        );
        try cache_session.validateActivePayloadV1(1, audio_features);
        const source_mapping_sha256 = try sourceMappingRootV1(
            self.inner.plan,
            processor_bundle.states[1],
        );
        return self.inner.prepareV1(
            weights,
            audio_features,
            source_mapping_sha256,
            candidate,
            visible_output,
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
    try validateAudioManifestV1(manifest);
    return stateless.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .encode,
        model.no_capabilities,
        implementation_sha256,
    );
}

pub fn validateAudioAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateAudioManifestV1(manifest);
    try stateless.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &audio_support,
    );
}

fn validateAudioManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    const expected_weight_elements = std.math.mul(
        u64,
        manifest.input_features,
        manifest.output_dimensions,
    ) catch return Error.InvalidAudioBinding;
    if (manifest.family != .audio_understanding or
        manifest.input_kind != .audio_feature_i16 or
        manifest.output_kind != .embedding_i32 or
        manifest.numerical_policy != .exact_integer or
        manifest.input_element_bytes != @sizeOf(i16) or
        manifest.output_element_bytes != @sizeOf(i32) or
        manifest.weight_element_bytes != @sizeOf(i16) or
        manifest.weight_elements != expected_weight_elements)
        return Error.InvalidAudioBinding;
}

pub fn validateAudioBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    processor_bundle: *const processor.DecodedBundleV1,
    cache_bundle: *const processor_cache.DecodedBundleV1,
    audio_features: []const u8,
) Error!void {
    try validateAudioManifestV1(manifest);
    const audio_state = processor_bundle.states[1];
    processor_cache.validateBindingV1(
        cache_bundle,
        processor_bundle,
        processor_bundle.bundle_sha256,
    ) catch return Error.InvalidAudioBinding;
    if (audio_state.kind != .audio or
        plan.family != .audio_understanding or
        plan.operation != .encode or
        plan.input_kind != .audio_feature_i16 or
        plan.output_kind != .embedding_i32 or
        plan.numerical_policy != .exact_integer or
        plan.request_epoch != audio_state.request_epoch or
        plan.generation != audio_state.generation or
        plan.batch_items != audio_state.produced_units or
        plan.input_features != audio_state.parameters[4] or
        plan.input_element_bytes != audio_state.parameters[6] or
        audio_state.parameters[5] != 0 or
        audio_features.len != plan.input_bytes or
        !std.mem.eql(u8, audio_features, cache_bundle.payloads[1]) or
        !std.mem.eql(
            u8,
            &model.sha256(audio_features),
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &audio_state.cache_content_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &audio_state.media_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &audio_state.state_sha256,
            &plan.processor_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &processor_bundle.bundle_sha256,
            &plan.processor_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &cache_bundle.bundle_sha256,
            &plan.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &audio_state.ownership_receipt_sha256,
            &plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &audio_state.challenge_sha256,
            &plan.challenge_sha256,
        ) or
        manifest.input_features != plan.input_features or
        manifest.output_dimensions != plan.output_dimensions or
        plan.output_element_bytes != @sizeOf(i32) or
        plan.scratch_bytes != plan.output_bytes or
        plan.claim.capsule_bytes != plan.weight_bytes or
        plan.claim.activation_bytes != plan.input_bytes or
        plan.claim.partial_bytes != plan.scratch_bytes or
        plan.claim.output_journal_bytes != plan.output_bytes or
        plan.claim.queue_slots != 1 or plan.claim.kv_bytes != 0 or
        plan.claim.logits_bytes != 0 or plan.claim.staging_bytes != 0 or
        plan.claim.device_bytes != 0 or plan.claim.io_bytes != 0)
        return Error.InvalidAudioBinding;
}

pub fn referenceExecuteV1(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    candidate: []u8,
) anyerror!void {
    _ = context;
    if (plan.input_element_bytes != @sizeOf(i16) or
        plan.output_element_bytes != @sizeOf(i32) or
        weights.len != plan.weight_bytes or input.len != plan.input_bytes or
        candidate.len != plan.output_bytes)
        return Error.InvalidAudioBinding;
    const batch_items = std.math.cast(usize, plan.batch_items) orelse
        return Error.InvalidAudioBinding;
    const input_features = std.math.cast(usize, plan.input_features) orelse
        return Error.InvalidAudioBinding;
    const output_dimensions = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.InvalidAudioBinding;
    for (0..batch_items) |batch| {
        for (0..output_dimensions) |dimension| {
            var accumulator: i64 = 0;
            for (0..input_features) |feature| {
                const input_offset =
                    (batch * input_features + feature) * @sizeOf(i16);
                const weight_offset =
                    (dimension * input_features + feature) * @sizeOf(i16);
                const input_value: i64 = std.mem.readInt(
                    i16,
                    input[input_offset .. input_offset + 2][0..2],
                    .little,
                );
                const weight_value: i64 = std.mem.readInt(
                    i16,
                    weights[weight_offset .. weight_offset + 2][0..2],
                    .little,
                );
                accumulator = std.math.add(
                    i64,
                    accumulator,
                    std.math.mul(
                        i64,
                        input_value,
                        weight_value,
                    ) catch return Error.CandidateInvalid,
                ) catch return Error.CandidateInvalid;
            }
            if (accumulator < std.math.minInt(i32) or
                accumulator > std.math.maxInt(i32))
                return Error.CandidateInvalid;
            const output_offset =
                (batch * output_dimensions + dimension) * @sizeOf(i32);
            std.mem.writeInt(
                i32,
                candidate[output_offset .. output_offset + 4][0..4],
                @intCast(accumulator),
                .little,
            );
        }
    }
}

pub fn validateCandidateV1(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
) anyerror!void {
    _ = context;
    if (candidate.len != plan.output_bytes or
        plan.output_element_bytes != @sizeOf(i32) or
        candidate.len % @sizeOf(i32) != 0)
        return Error.CandidateInvalid;
    for (0..candidate.len / @sizeOf(i32)) |index| {
        const offset = index * @sizeOf(i32);
        const value = std.mem.readInt(
            i32,
            candidate[offset .. offset + 4][0..4],
            .little,
        );
        const magnitude: u64 = if (value < 0)
            @intCast(-@as(i64, value))
        else
            @intCast(value);
        if (magnitude > plan.maximum_absolute_output)
            return Error.CandidateInvalid;
    }
}

pub fn sourceMappingRootV1(
    plan: model.ExecutionPlanV1,
    audio_state: processor.ProcessorStateV1,
) Error!Digest {
    if (audio_state.kind != .audio or
        !std.mem.eql(
            u8,
            &processor.processorStateRootV1(audio_state),
            &audio_state.state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &audio_state.state_sha256,
            &plan.processor_state_sha256,
        ))
        return Error.InvalidAudioBinding;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_mapping_domain);
    hash.update(&plan.media_object_sha256);
    hash.update(&plan.processor_state_sha256);
    hash.update(&plan.cache_payload_sha256);
    hashU64(&hash, audio_state.timeline_base.numerator);
    hashU64(&hash, audio_state.timeline_base.denominator);
    hashU64(&hash, audio_state.cursor_units);
    hashU64(&hash, audio_state.produced_units);
    for (audio_state.parameters) |value| hashU64(&hash, value);
    hashU64(&hash, plan.batch_items);
    hashU64(&hash, plan.input_features);
    return hash.finalResult();
}

fn hashU64(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

const TestFixture = struct {
    processor_storage: [processor.processor_bundle_bytes]u8,
    cache_storage: [
        processor_cache.cache_payload_offset +
            11 + processor_cache.cache_bundle_footer_bytes
    ]u8,
    processor_bundle: processor.DecodedBundleV1,
    cache_bundle: processor_cache.DecodedBundleV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    publication_state: model.PublicationStateV1,
    weights: [8]u8,
    image_cache: [2]u8,
    audio_features: [8]u8,
    video_cache: [1]u8,

    fn rebind(self: *TestFixture) !void {
        self.processor_bundle =
            try processor.decodeBundleV1(&self.processor_storage);
        self.cache_bundle =
            try processor_cache.decodeBundleV1(&self.cache_storage);
    }

    fn init() !TestFixture {
        const image_cache = [_]u8{ 1, 2 };
        const audio_features = [_]u8{
            100,  0,
            200,  0,
            0xd4, 0xfe,
            0x90, 0x01,
        };
        const video_cache = [_]u8{3};
        const request_epoch: u64 = 121;
        const generation: u64 = 4;
        const challenge = model.sha256("audio challenge");
        const image_state = try processor.makeImageStateV1(.{
            .kind = .image,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 31_001,
            .timeline_base = .{ .numerator = 0, .denominator = 1 },
            .media_object_sha256 = model.sha256("image media"),
            .processor_plan_sha256 = model.sha256("image processor"),
            .previous_state_sha256 = model.sha256("previous image state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&image_cache),
            .output_chain_sha256 = model.sha256("image output"),
            .ownership_receipt_sha256 = model.sha256("image ownership"),
            .decoder_state_sha256 = model.sha256("image decoder"),
        }, 1, 2, 1, 1, 1, 1, 1);
        const audio_state = try processor.makeAudioStateV1(.{
            .kind = .audio,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 31_002,
            .timeline_base = .{ .numerator = 1, .denominator = 16_000 },
            .media_object_sha256 = model.sha256("audio media"),
            .processor_plan_sha256 = model.sha256("audio processor"),
            .previous_state_sha256 = model.sha256("previous audio state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&audio_features),
            .output_chain_sha256 = model.sha256("audio output"),
            .ownership_receipt_sha256 = model.sha256("audio ownership"),
            .decoder_state_sha256 = model.sha256("audio decoder"),
        }, 2, 16_000, 1, 4, 4, 2, 2);
        const video_state = try processor.makeVideoStateV1(.{
            .kind = .video,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 31_003,
            .timeline_base = .{ .numerator = 1, .denominator = 48_000 },
            .media_object_sha256 = model.sha256("video media"),
            .processor_plan_sha256 = model.sha256("video processor"),
            .previous_state_sha256 = model.sha256("previous video state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&video_cache),
            .output_chain_sha256 = model.sha256("video output"),
            .ownership_receipt_sha256 = model.sha256("video ownership"),
            .decoder_state_sha256 = model.sha256("video decoder"),
        }, 1, 1, 0, 1, 0);
        const states = [_]processor.ProcessorStateV1{
            image_state,
            audio_state,
            video_state,
        };
        const sync = try processor.makeSyncStateV1(states, .{
            .generation = generation,
            .request_epoch = request_epoch,
            .master_ticks_per_second = 48_000,
            .maximum_skew_ticks = 24,
            .challenge_sha256 = challenge,
            .sync_policy_sha256 = model.sha256("audio sync policy"),
            .previous_sync_sha256 = model.sha256("previous sync"),
        });
        var processor_storage: [processor.processor_bundle_bytes]u8 =
            undefined;
        _ = try processor.encodeBundleV1(
            states,
            sync,
            &processor_storage,
        );
        const processor_bundle =
            try processor.decodeBundleV1(&processor_storage);
        var cache_storage: [
            processor_cache.cache_payload_offset +
                11 + processor_cache.cache_bundle_footer_bytes
        ]u8 = undefined;
        _ = try processor_cache.encodeBundleV1(
            processor_bundle,
            .{
                .processor_bundle_sha256 = processor_bundle.bundle_sha256,
                .previous_cache_bundle_sha256 = model.sha256("previous audio cache bundle"),
                .source_bank_epoch = 110,
                .restore_bank_epoch = 111,
                .restore_owner_key_base = 32_000,
                .restore_tree_key_base = 33_000,
                .restore_authority_key_base = 34_000,
                .tenant_key = 35_000,
                .publication_next_sequence = 5,
            },
            .{ &image_cache, &audio_features, &video_cache },
            &cache_storage,
        );
        const cache_bundle =
            try processor_cache.decodeBundleV1(&cache_storage);
        var weights: [8]u8 = undefined;
        inline for ([_]i16{ 1, 2, -1, 3 }, 0..) |value, index|
            std.mem.writeInt(
                i16,
                weights[index * 2 .. index * 2 + 2][0..2],
                value,
                .little,
            );
        const manifest = try model.makeArtifactManifestV1(
            .audio_understanding,
            0x4155_4449_4f00_0001,
            .audio_feature_i16,
            .embedding_i32,
            .exact_integer,
            2,
            2,
            2,
            2,
            4,
            2,
            &weights,
            model.sha256("audio fixture metadata"),
            model.sha256("fixture-only license"),
        );
        const claim: resource_bank.Claim = .{
            .capsule_bytes = weights.len,
            .activation_bytes = audio_features.len,
            .partial_bytes = 16,
            .output_journal_bytes = 16,
            .queue_slots = 1,
        };
        const plan = try model.makeExecutionPlanV1(
            manifest,
            .encode,
            .{
                .request_epoch = request_epoch,
                .generation = generation,
                .batch_items = 2,
                .publication_next_sequence = 0,
                .maximum_absolute_output = 10_000,
                .claim = claim,
                .media_object_sha256 = audio_state.media_object_sha256,
                .processor_state_sha256 = audio_state.state_sha256,
                .processor_bundle_sha256 = processor_bundle.bundle_sha256,
                .cache_bundle_sha256 = cache_bundle.bundle_sha256,
                .cache_payload_sha256 = audio_state.cache_content_sha256,
                .ownership_sha256 = audio_state.ownership_receipt_sha256,
                .challenge_sha256 = challenge,
                .previous_plan_sha256 = model.sha256("previous audio plan"),
                .input_schema_sha256 = model.sha256("two windows by two i16 bins"),
                .output_schema_sha256 = model.sha256("two windows by two i32 embedding"),
                .scratch_bytes = 16,
            },
        );
        const publication_state =
            try model.initializePublicationStateV1(
                request_epoch,
                manifest.artifact_sha256,
            );
        var value: TestFixture = undefined;
        value.processor_storage = processor_storage;
        value.cache_storage = cache_storage;
        value.processor_bundle =
            try processor.decodeBundleV1(&value.processor_storage);
        value.cache_bundle =
            try processor_cache.decodeBundleV1(&value.cache_storage);
        value.manifest = manifest;
        value.plan = plan;
        value.publication_state = publication_state;
        value.weights = weights;
        value.image_cache = image_cache;
        value.audio_features = audio_features;
        value.video_cache = video_cache;
        return value;
    }
};

const TestRuntime = struct {
    slots: [8]resource_bank.Slot = [_]resource_bank.Slot{.{}} ** 8,
    roots: [8]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8,
    nodes: [12]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 12,
};

test "audio adapter publishes exact window embeddings and releases" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var storage: TestRuntime = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        fixture.cache_bundle.restore_bank_epoch,
    );
    var cache_session: processor_cache.RestoreSession = .{};
    try cache_session.prepareV1(
        &bank,
        fixture.cache_bundle,
        fixture.cache_bundle.bundle_sha256,
    );
    try cache_session.commitMaterializedV1(.{
        &fixture.image_cache,
        &fixture.audio_features,
        &fixture.video_cache,
    });
    const descriptor = try makeAdapterDescriptorV1(
        fixture.manifest,
        model.sha256("reference exact audio projection v1"),
    );
    var context: u8 = 1;
    const adapter: AdapterV1 = .{
        .context = &context,
        .descriptor = descriptor,
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateCandidateV1,
    };
    var session: Session = .{};
    try session.initV1(
        &bank,
        36_000,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [16]u8 = undefined;
    var output: [16]u8 = undefined;
    const prepared = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.audio_features,
        &candidate,
        &output,
    );
    var expected_mapping: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_mapping,
        "b65fce1e3bd5486b480cd700b7e8b586" ++
            "ebd6f0d14a65ab172af4d7a4c9e6cedd",
    );
    try std.testing.expectEqual(
        expected_mapping,
        prepared.source_mapping_sha256,
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    const expected = [_]i32{ 500, 500, 500, 1500 };
    for (expected, 0..) |value, index| {
        const offset = index * 4;
        try std.testing.expectEqual(
            value,
            std.mem.readInt(
                i32,
                candidate[offset .. offset + 4][0..4],
                .little,
            ),
        );
    }
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expectEqualSlices(
        u8,
        &prepared.output_sha256,
        &model.sha256(&output),
    );
    try session.closeAndRelease();
    try cache_session.closeAndRelease();
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}

test "audio adapter abort and candidate drift preserve publication" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var storage: TestRuntime = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        fixture.cache_bundle.restore_bank_epoch,
    );
    var cache_session: processor_cache.RestoreSession = .{};
    try cache_session.prepareV1(
        &bank,
        fixture.cache_bundle,
        fixture.cache_bundle.bundle_sha256,
    );
    try cache_session.commitMaterializedV1(.{
        &fixture.image_cache,
        &fixture.audio_features,
        &fixture.video_cache,
    });
    const descriptor = try makeAdapterDescriptorV1(
        fixture.manifest,
        model.sha256("reference exact audio projection v1"),
    );
    var context: u8 = 1;
    const adapter: AdapterV1 = .{
        .context = &context,
        .descriptor = descriptor,
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateCandidateV1,
    };
    var session: Session = .{};
    try session.initV1(
        &bank,
        36_001,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [16]u8 = undefined;
    var output: [16]u8 = undefined;
    _ = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.audio_features,
        &candidate,
        &output,
    );
    try session.abortV1();
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    _ = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.audio_features,
        &candidate,
        &output,
    );
    candidate[0] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.publication_state.visible_results,
    );
    try session.closeAndRelease();
    try cache_session.closeAndRelease();
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}

test "audio adapter rejects context-bearing and foreign feature caches" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var foreign = fixture.audio_features;
    foreign[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidAudioBinding,
        validateAudioBindingsV1(
            fixture.manifest,
            fixture.plan,
            &fixture.processor_bundle,
            &fixture.cache_bundle,
            &foreign,
        ),
    );
    var mutated_state = fixture.processor_bundle.states[1];
    mutated_state.cursor_units += 1;
    try std.testing.expectError(
        Error.InvalidAudioBinding,
        sourceMappingRootV1(fixture.plan, mutated_state),
    );
    var context_state = fixture.processor_bundle.states[1];
    context_state.parameters[5] = 1;
    context_state.state_sha256 =
        processor.processorStateRootV1(context_state);
    var context_bundle = fixture.processor_bundle;
    context_bundle.states[1] = context_state;
    try std.testing.expectError(
        Error.InvalidAudioBinding,
        validateAudioBindingsV1(
            fixture.manifest,
            fixture.plan,
            &context_bundle,
            &fixture.cache_bundle,
            &fixture.audio_features,
        ),
    );
}
