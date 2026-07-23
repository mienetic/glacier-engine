//! A bounded typed vision-encoder adapter over materialized media caches.
//!
//! The retained backend is an exact integer fixture. It proves adapter
//! lifecycle, ownership, cancellation, and typed result publication; it is not
//! a production vision model or a quality benchmark.

const std = @import("std");
const media = @import("media_contract.zig");
const processor = @import("media_processor_state.zig");
const processor_cache = @import("media_processor_cache.zig");
const model = @import("model_contract.zig");
const stateless = @import("stateless_model_adapter.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const reference_adapter_abi: u64 = 0x4756_454e_0000_0001;
pub const vision_support = [_]model.SupportRecordV1{.{
    .family = .vision_understanding,
    .operation = .encode,
    .input_kind = .image_feature_u8,
    .output_kind = .embedding_i32,
    .numerical_policy = .exact_integer,
    .max_batch_items = 64,
    .max_input_features = 65_536,
    .max_output_dimensions = 16_384,
    .allowed_capabilities = model.no_capabilities,
}};

const source_mapping_domain =
    "glacier-vision-encoder-source-mapping-v1\x00";

pub const Error = stateless.Error || processor.Error ||
    processor_cache.Error || error{
    InvalidBinding,
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
        try validateAdapterForPlanV1(adapter, manifest, plan);
        try self.inner.initV1(
            bank,
            owner_key,
            publication_state,
            manifest,
            plan,
            adapter,
            &vision_support,
        );
    }

    pub fn prepareV1(
        self: *Session,
        processor_bundle: *const processor.DecodedBundleV1,
        cache_bundle: *const processor_cache.DecodedBundleV1,
        cache_session: *const processor_cache.RestoreSession,
        weights: []const u8,
        image_features: []const u8,
        candidate: []u8,
        visible_output: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateVisionBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            processor_bundle,
            cache_bundle,
            image_features,
        );
        try cache_session.validateActivePayloadV1(0, image_features);
        const source_mapping_sha256 = try sourceMappingRootV1(
            self.inner.plan,
            processor_bundle.states[0],
        );
        return self.inner.prepareV1(
            weights,
            image_features,
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
    adapter_abi: u64,
    manifest: model.ArtifactManifestV1,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    try validateVisionManifestV1(manifest);
    return stateless.makeAdapterDescriptorV1(
        adapter_abi,
        manifest,
        .encode,
        model.no_capabilities,
        implementation_sha256,
    );
}

pub fn adapterDescriptorRootV1(
    descriptor: AdapterDescriptorV1,
) Digest {
    return stateless.adapterDescriptorRootV1(descriptor);
}

pub fn validateAdapterForPlanV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateVisionManifestV1(manifest);
    try stateless.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &vision_support,
    );
}

fn validateVisionManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    const expected_weight_elements = std.math.mul(
        u64,
        manifest.input_features,
        manifest.output_dimensions,
    ) catch return Error.InvalidAdapter;
    if (manifest.family != .vision_understanding or
        manifest.input_kind != .image_feature_u8 or
        manifest.output_kind != .embedding_i32 or
        manifest.numerical_policy != .exact_integer or
        manifest.input_element_bytes != @sizeOf(u8) or
        manifest.output_element_bytes != @sizeOf(i32) or
        manifest.weight_element_bytes != @sizeOf(i8) or
        manifest.weight_elements != expected_weight_elements)
        return Error.InvalidAdapter;
}

pub fn validateVisionBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    processor_bundle: *const processor.DecodedBundleV1,
    cache_bundle: *const processor_cache.DecodedBundleV1,
    image_features: []const u8,
) Error!void {
    try validateVisionManifestV1(manifest);
    const image_state = processor_bundle.states[0];
    processor_cache.validateBindingV1(
        cache_bundle,
        processor_bundle,
        processor_bundle.bundle_sha256,
    ) catch return Error.InvalidBinding;
    if (image_state.kind != .image or
        plan.family != .vision_understanding or
        plan.operation != .encode or
        plan.input_kind != .image_feature_u8 or
        plan.output_kind != .embedding_i32 or
        plan.numerical_policy != .exact_integer or
        plan.request_epoch != image_state.request_epoch or
        plan.generation != image_state.generation or
        image_features.len != plan.input_bytes or
        !std.mem.eql(u8, image_features, cache_bundle.payloads[0]) or
        !std.mem.eql(
            u8,
            &model.sha256(image_features),
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &image_state.cache_content_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &image_state.media_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &image_state.state_sha256,
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
            &image_state.ownership_receipt_sha256,
            &plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &image_state.challenge_sha256,
            &plan.challenge_sha256,
        ) or
        manifest.input_features != plan.input_features or
        manifest.output_dimensions != plan.output_dimensions)
        return Error.InvalidBinding;
    if (plan.input_element_bytes != 1 or
        plan.output_element_bytes != @sizeOf(i32) or
        plan.scratch_bytes != plan.output_bytes or
        plan.claim.capsule_bytes != plan.weight_bytes or
        plan.claim.activation_bytes != plan.input_bytes or
        plan.claim.partial_bytes != plan.scratch_bytes or
        plan.claim.output_journal_bytes != plan.output_bytes or
        plan.claim.queue_slots != 1 or plan.claim.kv_bytes != 0 or
        plan.claim.logits_bytes != 0 or plan.claim.staging_bytes != 0 or
        plan.claim.device_bytes != 0 or plan.claim.io_bytes != 0)
        return Error.InvalidBinding;
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

pub fn referenceExecuteV1(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    candidate: []u8,
) anyerror!void {
    _ = context;
    if (weights.len != plan.weight_bytes or
        input.len != plan.input_bytes or
        candidate.len != plan.output_bytes)
        return Error.InvalidBinding;
    const batch_items = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.InvalidBinding;
    const input_features = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidBinding;
    const output_dimensions = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.InvalidBinding;
    for (0..batch_items) |batch| {
        for (0..output_dimensions) |dimension| {
            var accumulator: i64 = 0;
            for (0..input_features) |feature| {
                const input_value: i64 =
                    input[batch * input_features + feature];
                const weight_value: i8 = @bitCast(
                    weights[dimension * input_features + feature],
                );
                accumulator = std.math.add(
                    i64,
                    accumulator,
                    input_value * @as(i64, weight_value),
                ) catch return Error.CandidateInvalid;
            }
            if (accumulator < std.math.minInt(i32) or
                accumulator > std.math.maxInt(i32))
                return Error.CandidateInvalid;
            const output_index = batch * output_dimensions + dimension;
            const offset = output_index * @sizeOf(i32);
            std.mem.writeInt(
                i32,
                candidate[offset .. offset + 4][0..4],
                @intCast(accumulator),
                .little,
            );
        }
    }
}

pub fn sourceMappingRootV1(
    plan: model.ExecutionPlanV1,
    image_state: processor.ProcessorStateV1,
) Error!Digest {
    try processor.validateDecodedStateV1(image_state);
    if (image_state.kind != .image or
        !std.mem.eql(
            u8,
            &image_state.state_sha256,
            &plan.processor_state_sha256,
        ))
        return Error.InvalidBinding;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_mapping_domain);
    hash.update(&plan.media_object_sha256);
    hash.update(&plan.processor_state_sha256);
    hash.update(&plan.cache_payload_sha256);
    hashU64(&hash, image_state.cursor_units);
    hashU64(&hash, image_state.produced_units);
    for (image_state.parameters) |value| hashU64(&hash, value);
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
            10 + processor_cache.cache_bundle_footer_bytes
    ]u8,
    processor_bundle: processor.DecodedBundleV1,
    cache_bundle: processor_cache.DecodedBundleV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    publication_state: model.PublicationStateV1,
    weights: [8]u8,
    image_features: [8]u8,
    audio_features: [1]u8,
    video_features: [1]u8,

    fn rebind(self: *TestFixture) !void {
        self.processor_bundle =
            try processor.decodeBundleV1(&self.processor_storage);
        self.cache_bundle =
            try processor_cache.decodeBundleV1(&self.cache_storage);
    }

    fn init() !TestFixture {
        const image_features = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
        const audio_features = [_]u8{9};
        const video_features = [_]u8{10};
        const request_epoch: u64 = 91;
        const generation: u64 = 3;
        const challenge = model.sha256("vision challenge");
        const image_state = try processor.makeImageStateV1(.{
            .kind = .image,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 1001,
            .timeline_base = .{ .numerator = 0, .denominator = 1 },
            .media_object_sha256 = model.sha256("image media"),
            .processor_plan_sha256 = model.sha256("image processor"),
            .previous_state_sha256 = model.sha256("previous image state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&image_features),
            .output_chain_sha256 = model.sha256("image output"),
            .ownership_receipt_sha256 = model.sha256("image ownership"),
            .decoder_state_sha256 = model.sha256("image decoder"),
        }, 1, 2, 2, 2, 2, 2, 1);
        const audio_state = try processor.makeAudioStateV1(.{
            .kind = .audio,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 1002,
            .timeline_base = .{ .numerator = 1, .denominator = 48_000 },
            .media_object_sha256 = model.sha256("audio media"),
            .processor_plan_sha256 = model.sha256("audio processor"),
            .previous_state_sha256 = model.sha256("previous audio state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&audio_features),
            .output_chain_sha256 = model.sha256("audio output"),
            .ownership_receipt_sha256 = model.sha256("audio ownership"),
            .decoder_state_sha256 = model.sha256("audio decoder"),
        }, 1, 48_000, 1, 2, 2, 1, 1);
        const video_state = try processor.makeVideoStateV1(.{
            .kind = .video,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 1003,
            .timeline_base = .{ .numerator = 1, .denominator = 48_000 },
            .media_object_sha256 = model.sha256("video media"),
            .processor_plan_sha256 = model.sha256("video processor"),
            .previous_state_sha256 = model.sha256("previous video state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&video_features),
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
            .maximum_skew_ticks = 2,
            .challenge_sha256 = challenge,
            .sync_policy_sha256 = model.sha256("sync policy"),
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
                10 + processor_cache.cache_bundle_footer_bytes
        ]u8 = undefined;
        _ = try processor_cache.encodeBundleV1(
            processor_bundle,
            .{
                .processor_bundle_sha256 = processor_bundle.bundle_sha256,
                .previous_cache_bundle_sha256 = model.sha256("previous cache bundle"),
                .source_bank_epoch = 80,
                .restore_bank_epoch = 81,
                .restore_owner_key_base = 20_000,
                .restore_tree_key_base = 21_000,
                .restore_authority_key_base = 22_000,
                .tenant_key = 23_000,
                .publication_next_sequence = 4,
            },
            .{ &image_features, &audio_features, &video_features },
            &cache_storage,
        );
        const cache_bundle =
            try processor_cache.decodeBundleV1(&cache_storage);
        const weights = [_]u8{
            1,
            2,
            3,
            4,
            @bitCast(@as(i8, -1)),
            @bitCast(@as(i8, -2)),
            1,
            2,
        };
        const manifest = try model.makeArtifactManifestV1(
            .vision_understanding,
            0x5649_5349_4f4e_0001,
            .image_feature_u8,
            .embedding_i32,
            .exact_integer,
            2,
            4,
            2,
            1,
            4,
            1,
            &weights,
            model.sha256("vision fixture metadata"),
            model.sha256("fixture-only license"),
        );
        const claim: resource_bank.Claim = .{
            .capsule_bytes = weights.len,
            .activation_bytes = image_features.len,
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
                .media_object_sha256 = image_state.media_object_sha256,
                .processor_state_sha256 = image_state.state_sha256,
                .processor_bundle_sha256 = processor_bundle.bundle_sha256,
                .cache_bundle_sha256 = cache_bundle.bundle_sha256,
                .cache_payload_sha256 = image_state.cache_content_sha256,
                .ownership_sha256 = image_state.ownership_receipt_sha256,
                .challenge_sha256 = challenge,
                .previous_plan_sha256 = model.sha256("previous vision plan"),
                .input_schema_sha256 = model.sha256("two by four u8"),
                .output_schema_sha256 = model.sha256("two by two i32"),
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
        value.weights = weights;
        value.image_features = image_features;
        value.audio_features = audio_features;
        value.video_features = video_features;
        value.manifest = manifest;
        value.plan = plan;
        value.publication_state = publication_state;
        return value;
    }
};

test "vision adapter publishes exact typed embedding and releases ownership" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var slots = [_]resource_bank.Slot{.{}} ** 8;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
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
        &fixture.image_features,
        &fixture.audio_features,
        &fixture.video_features,
    });
    const descriptor = try makeAdapterDescriptorV1(
        reference_adapter_abi,
        fixture.manifest,
        model.sha256("reference exact integer projection v1"),
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
        30_000,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [16]u8 = [_]u8{0xaa} ** 16;
    var output: [16]u8 = [_]u8{0xbb} ** 16;
    const prepared = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.image_features,
        &candidate,
        &output,
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    const expected = [_]i32{ 30, 6, 70, 6 };
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
    try std.testing.expectEqual(
        @as(u64, 1),
        fixture.publication_state.visible_results,
    );
    try session.closeAndRelease();
    try cache_session.closeAndRelease();
    const snapshot = try bank.snapshotV3();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 0), snapshot.live_allocations);
}

test "vision adapter abort and candidate drift never publish" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var slots = [_]resource_bank.Slot{.{}} ** 8;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
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
        &fixture.image_features,
        &fixture.audio_features,
        &fixture.video_features,
    });
    const descriptor = try makeAdapterDescriptorV1(
        reference_adapter_abi,
        fixture.manifest,
        model.sha256("reference exact integer projection v1"),
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
        30_001,
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
        &fixture.image_features,
        &candidate,
        &output,
    );
    try session.abortV1();
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.publication_state.visible_results,
    );
    _ = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.image_features,
        &candidate,
        &output,
    );
    candidate[0] ^= 1;
    try std.testing.expectError(Error.CandidateDrift, session.commitV1());
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.publication_state.visible_results,
    );
    try session.closeAndRelease();
    try cache_session.closeAndRelease();
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}

test "vision adapter rejects foreign cache and unsupported capability" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var slots = [_]resource_bank.Slot{.{}} ** 8;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
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
        &fixture.image_features,
        &fixture.audio_features,
        &fixture.video_features,
    });
    const descriptor = try makeAdapterDescriptorV1(
        reference_adapter_abi,
        fixture.manifest,
        model.sha256("reference exact integer projection v1"),
    );
    var context: u8 = 1;
    const adapter: AdapterV1 = .{
        .context = &context,
        .descriptor = descriptor,
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateCandidateV1,
    };
    var unsupported = fixture.plan;
    unsupported.required_capabilities = 1;
    try std.testing.expectError(
        Error.UnsupportedCapabilities,
        model.requireSupportV1(&vision_support, unsupported),
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        30_002,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var foreign = fixture.image_features;
    foreign[0] ^= 1;
    var candidate: [16]u8 = undefined;
    var output: [16]u8 = undefined;
    try std.testing.expectError(
        Error.InvalidBinding,
        session.prepareV1(
            &fixture.processor_bundle,
            &fixture.cache_bundle,
            &cache_session,
            &fixture.weights,
            &foreign,
            &candidate,
            &output,
        ),
    );
    try std.testing.expectEqual(Phase.idle, session.inner.phase);
    try session.closeAndRelease();
    try cache_session.closeAndRelease();
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}
