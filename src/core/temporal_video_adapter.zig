//! Typed temporal-video encoder over an owned processor-cache window.
//!
//! The retained exact-integer fixture gathers a caller-declared frame
//! selection into charged scratch before entering the shared stateless model
//! lifecycle. It proves timeline, keyframe, eviction, and publication
//! bindings; it is not production video understanding.

const std = @import("std");
const media = @import("media_contract.zig");
const processor = @import("media_processor_state.zig");
const processor_cache = @import("media_processor_cache.zig");
const model = @import("model_contract.zig");
const stateless = @import("stateless_model_adapter.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const reference_adapter_abi: u64 = 0x4754_5645_0000_0001;
pub const video_support = [_]model.SupportRecordV1{.{
    .family = .video_understanding,
    .operation = .encode,
    .input_kind = .video_feature_u8,
    .output_kind = .embedding_i32,
    .numerical_policy = .exact_integer,
    .max_batch_items = 4_096,
    .max_input_features = 1_048_576,
    .max_output_dimensions = 16_384,
    .allowed_capabilities = model.no_capabilities,
}};

const selection_domain =
    "glacier-temporal-video-selection-v1\x00";
const source_mapping_domain =
    "glacier-temporal-video-source-mapping-v1\x00";

pub const Error = stateless.Error || processor.Error ||
    processor_cache.Error || media.Error || error{
    InvalidVideoBinding,
};

pub const AdapterDescriptorV1 = stateless.AdapterDescriptorV1;
pub const AdapterV1 = stateless.AdapterV1;
pub const Phase = stateless.Phase;

pub const TemporalSelectionV1 = struct {
    first_frame: u64,
    frame_count: u64,
    frame_stride: u64,
    last_frame: u64,
    keyframe_ordinal: u64,
    eviction_boundary: u64,
    cache_generation: u64,
    target_base: media.TimeBaseV1,
    target_start_tick: u64,
    target_end_tick: u64,
    selection_sha256: Digest,
};

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
        try validateVideoAdapterV1(adapter, manifest, plan);
        try self.inner.initV1(
            bank,
            owner_key,
            publication_state,
            manifest,
            plan,
            adapter,
            &video_support,
        );
    }

    pub fn prepareV1(
        self: *Session,
        processor_bundle: *const processor.DecodedBundleV1,
        cache_bundle: *const processor_cache.DecodedBundleV1,
        cache_session: *const processor_cache.RestoreSession,
        selection: TemporalSelectionV1,
        weights: []const u8,
        video_cache: []const u8,
        selected_input: []u8,
        candidate: []u8,
        visible_output: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateVideoBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            processor_bundle,
            cache_bundle,
            selection,
            video_cache,
        );
        try cache_session.validateActivePayloadV1(2, video_cache);
        defer @memset(selected_input, 0);
        const selected = try materializeSelectionV1(
            self.inner.plan,
            processor_bundle.states[2],
            selection,
            video_cache,
            selected_input,
        );
        const source_mapping_sha256 = try sourceMappingRootV1(
            self.inner.plan,
            processor_bundle.states[2],
            selection,
        );
        return self.inner.prepareV1(
            weights,
            selected,
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

pub fn makeTemporalSelectionV1(
    video_state: processor.ProcessorStateV1,
    first_frame: u64,
    frame_count: u64,
    frame_stride: u64,
    target_base: media.TimeBaseV1,
) Error!TemporalSelectionV1 {
    if (frame_count == 0 or frame_stride == 0)
        return Error.InvalidVideoBinding;
    const last_frame = std.math.add(
        u64,
        first_frame,
        std.math.mul(
            u64,
            frame_count - 1,
            frame_stride,
        ) catch return Error.InvalidVideoBinding,
    ) catch return Error.InvalidVideoBinding;
    const source_end = std.math.add(
        u64,
        last_frame,
        1,
    ) catch return Error.InvalidVideoBinding;
    const target = media.mapSpanExactV1(.{
        .start = .{
            .ticks = first_frame,
            .base = video_state.timeline_base,
        },
        .end = .{
            .ticks = source_end,
            .base = video_state.timeline_base,
        },
    }, target_base) catch return Error.InvalidVideoBinding;
    var selection: TemporalSelectionV1 = .{
        .first_frame = first_frame,
        .frame_count = frame_count,
        .frame_stride = frame_stride,
        .last_frame = last_frame,
        .keyframe_ordinal = video_state.parameters[4],
        .eviction_boundary = video_state.parameters[6],
        .cache_generation = video_state.parameters[5],
        .target_base = target_base,
        .target_start_tick = target.start.ticks,
        .target_end_tick = target.end.ticks,
        .selection_sha256 = [_]u8{0} ** 32,
    };
    selection.selection_sha256 =
        temporalSelectionRootUncheckedV1(video_state, selection);
    try validateTemporalSelectionV1(video_state, selection);
    return selection;
}

pub fn validateTemporalSelectionV1(
    video_state: processor.ProcessorStateV1,
    selection: TemporalSelectionV1,
) Error!void {
    processor.validateDecodedStateV1(video_state) catch
        return Error.InvalidVideoBinding;
    const p = video_state.parameters;
    if (video_state.kind != .video or
        !std.mem.eql(
            u8,
            &processor.processorStateRootV1(video_state),
            &video_state.state_sha256,
        ) or
        selection.frame_count == 0 or
        selection.frame_stride == 0 or
        selection.first_frame < p[2] or
        selection.last_frame >= p[3] or
        selection.keyframe_ordinal != p[4] or
        selection.keyframe_ordinal > selection.first_frame or
        selection.eviction_boundary != p[6] or
        selection.cache_generation != p[5] or
        selection.target_start_tick >= selection.target_end_tick)
        return Error.InvalidVideoBinding;
    const expected_last = std.math.add(
        u64,
        selection.first_frame,
        std.math.mul(
            u64,
            selection.frame_count - 1,
            selection.frame_stride,
        ) catch return Error.InvalidVideoBinding,
    ) catch return Error.InvalidVideoBinding;
    if (selection.last_frame != expected_last)
        return Error.InvalidVideoBinding;
    const source_end = std.math.add(
        u64,
        selection.last_frame,
        1,
    ) catch return Error.InvalidVideoBinding;
    const expected_target = media.mapSpanExactV1(.{
        .start = .{
            .ticks = selection.first_frame,
            .base = video_state.timeline_base,
        },
        .end = .{
            .ticks = source_end,
            .base = video_state.timeline_base,
        },
    }, selection.target_base) catch
        return Error.InvalidVideoBinding;
    if (selection.target_start_tick != expected_target.start.ticks or
        selection.target_end_tick != expected_target.end.ticks or
        !std.mem.eql(
            u8,
            &temporalSelectionRootUncheckedV1(
                video_state,
                selection,
            ),
            &selection.selection_sha256,
        ))
        return Error.InvalidVideoBinding;
}

pub fn selectedFrameBytesV1(
    video_state: processor.ProcessorStateV1,
    selection: TemporalSelectionV1,
) Error!u64 {
    try validateTemporalSelectionV1(video_state, selection);
    return std.math.mul(
        u64,
        selection.frame_count,
        video_state.parameters[1],
    ) catch return Error.InvalidVideoBinding;
}

pub fn materializeSelectedFramesV1(
    video_state: processor.ProcessorStateV1,
    selection: TemporalSelectionV1,
    video_cache: []const u8,
    selected_input: []u8,
) Error![]u8 {
    const selected_bytes = try selectedFrameBytesV1(
        video_state,
        selection,
    );
    const bytes_per_entry = std.math.cast(
        usize,
        video_state.parameters[1],
    ) orelse return Error.InvalidVideoBinding;
    if (selected_input.len != selected_bytes or
        video_cache.len != video_state.cache_bytes or
        !std.mem.eql(
            u8,
            &model.sha256(video_cache),
            &video_state.cache_content_sha256,
        ))
        return Error.InvalidVideoBinding;
    @memset(selected_input, 0);
    for (0..std.math.cast(
        usize,
        selection.frame_count,
    ) orelse return Error.InvalidVideoBinding) |index| {
        const frame = std.math.add(
            u64,
            selection.first_frame,
            std.math.mul(
                u64,
                index,
                selection.frame_stride,
            ) catch return Error.InvalidVideoBinding,
        ) catch return Error.InvalidVideoBinding;
        const relative = std.math.sub(
            u64,
            frame,
            video_state.parameters[2],
        ) catch return Error.InvalidVideoBinding;
        const source_offset = std.math.cast(
            usize,
            std.math.mul(
                u64,
                relative,
                video_state.parameters[1],
            ) catch return Error.InvalidVideoBinding,
        ) orelse return Error.InvalidVideoBinding;
        const destination_offset = std.math.mul(
            usize,
            index,
            bytes_per_entry,
        ) catch return Error.InvalidVideoBinding;
        const source_end = std.math.add(
            usize,
            source_offset,
            bytes_per_entry,
        ) catch return Error.InvalidVideoBinding;
        const destination_end = std.math.add(
            usize,
            destination_offset,
            bytes_per_entry,
        ) catch return Error.InvalidVideoBinding;
        if (source_end > video_cache.len or
            destination_end > selected_input.len)
            return Error.InvalidVideoBinding;
        @memcpy(
            selected_input[destination_offset..destination_end],
            video_cache[source_offset..source_end],
        );
    }
    return selected_input;
}

pub fn makeAdapterDescriptorV1(
    manifest: model.ArtifactManifestV1,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    try validateVideoManifestV1(manifest);
    return stateless.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .encode,
        model.no_capabilities,
        implementation_sha256,
    );
}

pub fn validateVideoAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateVideoManifestV1(manifest);
    try stateless.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &video_support,
    );
}

fn validateVideoManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    const expected_weight_elements = std.math.mul(
        u64,
        manifest.input_features,
        manifest.output_dimensions,
    ) catch return Error.InvalidVideoBinding;
    if (manifest.family != .video_understanding or
        manifest.input_kind != .video_feature_u8 or
        manifest.output_kind != .embedding_i32 or
        manifest.numerical_policy != .exact_integer or
        manifest.input_element_bytes != @sizeOf(u8) or
        manifest.output_element_bytes != @sizeOf(i32) or
        manifest.weight_element_bytes != @sizeOf(i8) or
        manifest.weight_elements != expected_weight_elements)
        return Error.InvalidVideoBinding;
}

pub fn validateVideoBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    processor_bundle: *const processor.DecodedBundleV1,
    cache_bundle: *const processor_cache.DecodedBundleV1,
    selection: TemporalSelectionV1,
    video_cache: []const u8,
) Error!void {
    try validateVideoManifestV1(manifest);
    const video_state = processor_bundle.states[2];
    processor_cache.validateBindingV1(
        cache_bundle,
        processor_bundle,
        processor_bundle.bundle_sha256,
    ) catch return Error.InvalidVideoBinding;
    validateTemporalSelectionV1(
        video_state,
        selection,
    ) catch return Error.InvalidVideoBinding;
    if (plan.family != .video_understanding or
        plan.operation != .encode or
        plan.input_kind != .video_feature_u8 or
        plan.output_kind != .embedding_i32 or
        plan.numerical_policy != .exact_integer or
        plan.request_epoch != video_state.request_epoch or
        plan.generation != video_state.generation or
        plan.batch_items != selection.frame_count or
        plan.input_features != video_state.parameters[1] or
        video_cache.len != video_state.cache_bytes or
        !std.mem.eql(u8, video_cache, cache_bundle.payloads[2]) or
        !std.mem.eql(
            u8,
            &model.sha256(video_cache),
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.cache_content_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.media_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.state_sha256,
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
            &video_state.ownership_receipt_sha256,
            &plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.challenge_sha256,
            &plan.challenge_sha256,
        ) or
        manifest.input_features != plan.input_features or
        manifest.output_dimensions != plan.output_dimensions or
        plan.input_element_bytes != @sizeOf(u8) or
        plan.output_element_bytes != @sizeOf(i32) or
        plan.scratch_bytes != plan.output_bytes or
        plan.claim.capsule_bytes != plan.weight_bytes or
        plan.claim.activation_bytes != plan.input_bytes or
        plan.claim.partial_bytes != plan.scratch_bytes or
        plan.claim.output_journal_bytes != plan.output_bytes or
        plan.claim.staging_bytes != plan.input_bytes or
        plan.claim.queue_slots != 1 or plan.claim.kv_bytes != 0 or
        plan.claim.logits_bytes != 0 or plan.claim.device_bytes != 0 or
        plan.claim.io_bytes != 0)
        return Error.InvalidVideoBinding;
}

pub fn materializeSelectionV1(
    plan: model.ExecutionPlanV1,
    video_state: processor.ProcessorStateV1,
    selection: TemporalSelectionV1,
    video_cache: []const u8,
    selected_input: []u8,
) Error![]u8 {
    try validateTemporalSelectionV1(video_state, selection);
    const input_bytes = std.math.cast(
        usize,
        plan.input_bytes,
    ) orelse return Error.InvalidVideoBinding;
    if (selected_input.len != input_bytes or
        video_cache.len != video_state.cache_bytes or
        plan.batch_items != selection.frame_count or
        plan.input_features != video_state.parameters[1] or
        !std.mem.eql(
            u8,
            &model.sha256(video_cache),
            &video_state.cache_content_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.cache_content_sha256,
            &plan.cache_payload_sha256,
        ))
        return Error.InvalidVideoBinding;
    return materializeSelectedFramesV1(
        video_state,
        selection,
        video_cache,
        selected_input,
    );
}

pub fn referenceExecuteV1(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    candidate: []u8,
) anyerror!void {
    _ = context;
    if (plan.input_element_bytes != @sizeOf(u8) or
        plan.output_element_bytes != @sizeOf(i32) or
        weights.len != plan.weight_bytes or input.len != plan.input_bytes or
        candidate.len != plan.output_bytes)
        return Error.InvalidVideoBinding;
    const batch_items = std.math.cast(usize, plan.batch_items) orelse
        return Error.InvalidVideoBinding;
    const input_features = std.math.cast(usize, plan.input_features) orelse
        return Error.InvalidVideoBinding;
    const output_dimensions = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.InvalidVideoBinding;
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
            const output_offset =
                (batch * output_dimensions + dimension) *
                @sizeOf(i32);
            std.mem.writeInt(
                i32,
                candidate[output_offset .. output_offset + @sizeOf(i32)][0..@sizeOf(i32)],
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
            candidate[offset .. offset + @sizeOf(i32)][0..@sizeOf(i32)],
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
    video_state: processor.ProcessorStateV1,
    selection: TemporalSelectionV1,
) Error!Digest {
    try validateTemporalSelectionV1(video_state, selection);
    if (!std.mem.eql(
        u8,
        &video_state.state_sha256,
        &plan.processor_state_sha256,
    ))
        return Error.InvalidVideoBinding;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_mapping_domain);
    hash.update(&plan.media_object_sha256);
    hash.update(&plan.processor_state_sha256);
    hash.update(&plan.cache_payload_sha256);
    hash.update(&selection.selection_sha256);
    hashU64(&hash, video_state.timeline_base.numerator);
    hashU64(&hash, video_state.timeline_base.denominator);
    hashU64(&hash, video_state.cursor_units);
    hashU64(&hash, video_state.produced_units);
    hashU64(&hash, video_state.cache_entries);
    hashU64(&hash, video_state.cache_bytes);
    for (video_state.parameters) |value| hashU64(&hash, value);
    hashU64(&hash, plan.batch_items);
    hashU64(&hash, plan.input_features);
    return hash.finalResult();
}

fn temporalSelectionRootUncheckedV1(
    video_state: processor.ProcessorStateV1,
    selection: TemporalSelectionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(selection_domain);
    hash.update(&video_state.state_sha256);
    inline for (.{
        selection.first_frame,
        selection.frame_count,
        selection.frame_stride,
        selection.last_frame,
        selection.keyframe_ordinal,
        selection.eviction_boundary,
        selection.cache_generation,
        selection.target_base.numerator,
        selection.target_base.denominator,
        selection.target_start_tick,
        selection.target_end_tick,
    }) |value| hashU64(&hash, value);
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
            18 + processor_cache.cache_bundle_footer_bytes
    ]u8,
    processor_bundle: processor.DecodedBundleV1,
    cache_bundle: processor_cache.DecodedBundleV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    publication_state: model.PublicationStateV1,
    selection: TemporalSelectionV1,
    weights: [4]u8,
    image_cache: [2]u8,
    audio_cache: [8]u8,
    video_cache: [8]u8,

    fn rebind(self: *TestFixture) !void {
        self.processor_bundle =
            try processor.decodeBundleV1(&self.processor_storage);
        self.cache_bundle =
            try processor_cache.decodeBundleV1(&self.cache_storage);
    }

    fn init() !TestFixture {
        const image_cache = [_]u8{ 1, 2 };
        const audio_cache = [_]u8{0} ** 8;
        const video_cache = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
        const request_epoch: u64 = 221;
        const generation: u64 = 7;
        const challenge = model.sha256("video challenge");
        const image_state = try processor.makeImageStateV1(.{
            .kind = .image,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 41_001,
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
            .stream_key = 41_002,
            .timeline_base = .{ .numerator = 1, .denominator = 30_000 },
            .media_object_sha256 = model.sha256("audio media"),
            .processor_plan_sha256 = model.sha256("audio processor"),
            .previous_state_sha256 = model.sha256("previous audio state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&audio_cache),
            .output_chain_sha256 = model.sha256("audio output"),
            .ownership_receipt_sha256 = model.sha256("audio ownership"),
            .decoder_state_sha256 = model.sha256("audio decoder"),
        }, 2, 30_000, 1, 4, 4, 2, 2);
        const video_state = try processor.makeVideoStateV1(.{
            .kind = .video,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 41_003,
            .timeline_base = .{ .numerator = 1, .denominator = 30 },
            .media_object_sha256 = model.sha256("video media"),
            .processor_plan_sha256 = model.sha256("video processor"),
            .previous_state_sha256 = model.sha256("previous video state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&video_cache),
            .output_chain_sha256 = model.sha256("video output"),
            .ownership_receipt_sha256 = model.sha256("video ownership"),
            .decoder_state_sha256 = model.sha256("video decoder"),
        }, 4, 2, 10, 14, 10);
        const states = [_]processor.ProcessorStateV1{
            image_state,
            audio_state,
            video_state,
        };
        const sync = try processor.makeSyncStateV1(states, .{
            .generation = generation,
            .request_epoch = request_epoch,
            .master_ticks_per_second = 90_000,
            .maximum_skew_ticks = 50_000,
            .challenge_sha256 = challenge,
            .sync_policy_sha256 = model.sha256("video sync policy"),
            .previous_sync_sha256 = model.sha256("previous video sync"),
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
                18 + processor_cache.cache_bundle_footer_bytes
        ]u8 = undefined;
        _ = try processor_cache.encodeBundleV1(
            processor_bundle,
            .{
                .processor_bundle_sha256 = processor_bundle.bundle_sha256,
                .previous_cache_bundle_sha256 = model.sha256("previous video cache bundle"),
                .source_bank_epoch = 210,
                .restore_bank_epoch = 211,
                .restore_owner_key_base = 42_000,
                .restore_tree_key_base = 43_000,
                .restore_authority_key_base = 44_000,
                .tenant_key = 45_000,
                .publication_next_sequence = 5,
            },
            .{ &image_cache, &audio_cache, &video_cache },
            &cache_storage,
        );
        const cache_bundle =
            try processor_cache.decodeBundleV1(&cache_storage);
        const weights = [_]u8{ 1, 2, 0xff, 3 };
        const manifest = try model.makeArtifactManifestV1(
            .video_understanding,
            0x5649_4445_4f00_0001,
            .video_feature_u8,
            .embedding_i32,
            .exact_integer,
            2,
            2,
            2,
            1,
            4,
            1,
            &weights,
            model.sha256("video fixture metadata"),
            model.sha256("fixture-only license"),
        );
        const selection = try makeTemporalSelectionV1(
            video_state,
            10,
            2,
            2,
            .{ .numerator = 1, .denominator = 90_000 },
        );
        const claim: resource_bank.Claim = .{
            .capsule_bytes = weights.len,
            .activation_bytes = 4,
            .partial_bytes = 16,
            .output_journal_bytes = 16,
            .staging_bytes = 4,
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
                .maximum_absolute_output = 100,
                .claim = claim,
                .media_object_sha256 = video_state.media_object_sha256,
                .processor_state_sha256 = video_state.state_sha256,
                .processor_bundle_sha256 = processor_bundle.bundle_sha256,
                .cache_bundle_sha256 = cache_bundle.bundle_sha256,
                .cache_payload_sha256 = video_state.cache_content_sha256,
                .ownership_sha256 = video_state.ownership_receipt_sha256,
                .challenge_sha256 = challenge,
                .previous_plan_sha256 = model.sha256("previous video plan"),
                .input_schema_sha256 = model.sha256("two strided frames by two u8 features"),
                .output_schema_sha256 = model.sha256("two frames by two i32 embedding"),
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
        value.selection = selection;
        value.weights = weights;
        value.image_cache = image_cache;
        value.audio_cache = audio_cache;
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

test "temporal video adapter gathers publishes and releases exactly" {
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
        &fixture.audio_cache,
        &fixture.video_cache,
    });
    const descriptor = try makeAdapterDescriptorV1(
        fixture.manifest,
        model.sha256("reference temporal video projection v1"),
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
        46_000,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var selected_input: [4]u8 = undefined;
    var candidate: [16]u8 = undefined;
    var output: [16]u8 = undefined;
    const prepared = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        fixture.selection,
        &fixture.weights,
        &fixture.video_cache,
        &selected_input,
        &candidate,
        &output,
    );
    var expected_mapping: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_mapping,
        "cbdf30f05789216a9a4c3e57d91eed91" ++
            "4f8a970a90edc3ecf3fde6db17eeb1ed",
    );
    try std.testing.expectEqual(
        expected_mapping,
        prepared.source_mapping_sha256,
    );
    try std.testing.expect(std.mem.allEqual(u8, &selected_input, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    const expected = [_]i32{ 5, 5, 17, 13 };
    for (expected, 0..) |value, index| {
        const offset = index * @sizeOf(i32);
        try std.testing.expectEqual(
            value,
            std.mem.readInt(
                i32,
                candidate[offset .. offset + @sizeOf(i32)][0..@sizeOf(i32)],
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

test "temporal video adapter rejects stale selection and candidate drift" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var stale = fixture.selection;
    stale.eviction_boundary += 1;
    try std.testing.expectError(
        Error.InvalidVideoBinding,
        validateTemporalSelectionV1(
            fixture.processor_bundle.states[2],
            stale,
        ),
    );
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
        &fixture.audio_cache,
        &fixture.video_cache,
    });
    const descriptor = try makeAdapterDescriptorV1(
        fixture.manifest,
        model.sha256("reference temporal video projection v1"),
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
        46_001,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var selected_input: [4]u8 = undefined;
    var candidate: [16]u8 = undefined;
    var output: [16]u8 = undefined;
    _ = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        fixture.selection,
        &fixture.weights,
        &fixture.video_cache,
        &selected_input,
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
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try session.closeAndRelease();
    try cache_session.closeAndRelease();
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}
