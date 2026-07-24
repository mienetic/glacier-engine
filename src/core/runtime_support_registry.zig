const std = @import("std");
const model = @import("model_contract.zig");
const vision = @import("vision_encoder_adapter.zig");
const audio_window = @import("audio_window_adapter.zig");
const temporal_video = @import("temporal_video_adapter.zig");
const audio_transcript = @import("audio_transcript_adapter.zig");
const stateful_transcript = @import("stateful_transcript_adapter.zig");
const video_segment = @import("video_segment_adapter.zig");
const stateful_video = @import("stateful_video_adapter.zig");
const latent_step = @import("latent_step_adapter.zig");

pub const registry_abi: u64 = 0x4752_5352_0000_0001;
pub const max_profiles: usize = 64;

pub const LifecycleV1 = enum(u64) {
    stateless = 1,
    stateful = 2,
};

pub const EvidenceV1 = enum(u64) {
    retained_reference_fixture = 1,
};

/// A profile's ordinal is its immutable bit position in QueryResultV1.
/// Existing entries must never be reordered or repurposed; new profiles append.
pub const ProfileIndexV1 = enum(u6) {
    vision_encoder = 0,
    audio_window = 1,
    audio_transcript = 2,
    stateful_transcript = 3,
    temporal_video = 4,
    video_segment = 5,
    stateful_video = 6,
    latent_step = 7,
};

pub const ProfileV1 = struct {
    index: ProfileIndexV1,
    slug: []const u8,
    profile_abi: u64,
    lifecycle: LifecycleV1,
    evidence: EvidenceV1,
    support: model.SupportRecordV1,
};

pub const profiles = [_]ProfileV1{
    .{
        .index = .vision_encoder,
        .slug = "vision-encoder-reference",
        .profile_abi = vision.reference_adapter_abi,
        .lifecycle = .stateless,
        .evidence = .retained_reference_fixture,
        .support = vision.vision_support[0],
    },
    .{
        .index = .audio_window,
        .slug = "audio-window-reference",
        .profile_abi = audio_window.reference_adapter_abi,
        .lifecycle = .stateless,
        .evidence = .retained_reference_fixture,
        .support = audio_window.audio_support[0],
    },
    .{
        .index = .audio_transcript,
        .slug = "audio-transcript-reference",
        .profile_abi = audio_transcript.reference_adapter_abi,
        .lifecycle = .stateless,
        .evidence = .retained_reference_fixture,
        .support = audio_transcript.transcript_support[0],
    },
    .{
        .index = .stateful_transcript,
        .slug = "stateful-transcript-reference",
        .profile_abi = stateful_transcript.reference_adapter_abi,
        .lifecycle = .stateful,
        .evidence = .retained_reference_fixture,
        .support = stateful_transcript.transcript_state_support[0],
    },
    .{
        .index = .temporal_video,
        .slug = "temporal-video-reference",
        .profile_abi = temporal_video.reference_adapter_abi,
        .lifecycle = .stateless,
        .evidence = .retained_reference_fixture,
        .support = temporal_video.video_support[0],
    },
    .{
        .index = .video_segment,
        .slug = "video-segment-reference",
        .profile_abi = video_segment.reference_adapter_abi,
        .lifecycle = .stateless,
        .evidence = .retained_reference_fixture,
        .support = video_segment.video_segment_support[0],
    },
    .{
        .index = .stateful_video,
        .slug = "stateful-video-reference",
        .profile_abi = stateful_video.reference_adapter_abi,
        .lifecycle = .stateful,
        .evidence = .retained_reference_fixture,
        .support = stateful_video.video_state_support[0],
    },
    .{
        .index = .latent_step,
        .slug = "latent-step-reference",
        .profile_abi = latent_step.reference_adapter_abi,
        .lifecycle = .stateful,
        .evidence = .retained_reference_fixture,
        .support = latent_step.latent_step_support[0],
    },
};

pub const QueryV1 = struct {
    family: model.ModelFamilyIdV1,
    operation: model.OperationIdV1,
    input_kind: model.InputKindV1,
    output_kind: model.OutputKindV1,
    numerical_policy: model.NumericalPolicyV1,
    batch_items: u64,
    input_features: u64,
    output_dimensions: u64,
    required_capabilities: u64,
};

pub const QueryResultV1 = struct {
    matching_profile_mask: u64,
    deepest_unsupported_reason: ?model.UnsupportedReasonV1,
};

pub fn querySupportV1(query: QueryV1) QueryResultV1 {
    if (query.batch_items == 0 or
        query.input_features == 0 or
        query.output_dimensions == 0)
    {
        return .{
            .matching_profile_mask = 0,
            .deepest_unsupported_reason = .dimensions,
        };
    }

    var matching_profile_mask: u64 = 0;
    var deepest_unsupported_reason: model.UnsupportedReasonV1 = .family;

    for (profiles) |profile| {
        const unsupported = unsupportedReasonV1(profile.support, query);
        if (unsupported) |reason| {
            if (@intFromEnum(reason) >
                @intFromEnum(deepest_unsupported_reason))
            {
                deepest_unsupported_reason = reason;
            }
            continue;
        }

        const shift: u6 = @intCast(@intFromEnum(profile.index));
        matching_profile_mask |= @as(u64, 1) << shift;
    }

    return .{
        .matching_profile_mask = matching_profile_mask,
        .deepest_unsupported_reason = if (matching_profile_mask == 0)
            deepest_unsupported_reason
        else
            null,
    };
}

fn unsupportedReasonV1(
    support: model.SupportRecordV1,
    query: QueryV1,
) ?model.UnsupportedReasonV1 {
    if (support.family != query.family) return .family;
    if (support.operation != query.operation) return .operation;
    if (support.input_kind != query.input_kind) return .input_kind;
    if (support.output_kind != query.output_kind) return .output_kind;
    if (support.numerical_policy != query.numerical_policy)
        return .numerical_policy;
    if (query.batch_items > support.max_batch_items or
        query.input_features > support.max_input_features or
        query.output_dimensions > support.max_output_dimensions)
        return .dimensions;
    if (query.required_capabilities & ~support.allowed_capabilities != 0)
        return .capabilities;
    return null;
}

fn queryFor(
    support: model.SupportRecordV1,
    batch_items: u64,
    input_features: u64,
    output_dimensions: u64,
    required_capabilities: u64,
) QueryV1 {
    return .{
        .family = support.family,
        .operation = support.operation,
        .input_kind = support.input_kind,
        .output_kind = support.output_kind,
        .numerical_policy = support.numerical_policy,
        .batch_items = batch_items,
        .input_features = input_features,
        .output_dimensions = output_dimensions,
        .required_capabilities = required_capabilities,
    };
}

comptime {
    if (profiles.len == 0 or profiles.len > max_profiles)
        @compileError("runtime support registry must contain 1 through 64 profiles");

    if (vision.vision_support.len != 1 or
        audio_window.audio_support.len != 1 or
        temporal_video.video_support.len != 1 or
        audio_transcript.transcript_support.len != 1 or
        stateful_transcript.transcript_state_support.len != 1 or
        video_segment.video_segment_support.len != 1 or
        stateful_video.video_state_support.len != 1 or
        latent_step.latent_step_support.len != 1)
    {
        @compileError(
            "each additional adapter support row needs an appended runtime profile",
        );
    }

    for (profiles, 0..) |profile, ordinal| {
        if (@intFromEnum(profile.index) != ordinal)
            @compileError("runtime support profile indices must remain contiguous");
        if (profile.slug.len == 0)
            @compileError("runtime support profile slug must be nonempty");
        if (profile.profile_abi == 0)
            @compileError("runtime support profile ABI must be nonzero");
        if (profile.support.max_batch_items == 0 or
            profile.support.max_input_features == 0 or
            profile.support.max_output_dimensions == 0)
        {
            @compileError("runtime support profile dimensions must be nonzero");
        }
        for (profiles[0..ordinal]) |previous| {
            if (previous.profile_abi == profile.profile_abi)
                @compileError("runtime support profile ABI must be unique");
            if (std.mem.eql(u8, previous.slug, profile.slug))
                @compileError("runtime support profile slug must be unique");
        }
    }
}

test "registry profiles are append-only views of adapter support constants" {
    try std.testing.expectEqual(@as(usize, 8), profiles.len);
    const expected_slugs = [_][]const u8{
        "vision-encoder-reference",
        "audio-window-reference",
        "audio-transcript-reference",
        "stateful-transcript-reference",
        "temporal-video-reference",
        "video-segment-reference",
        "stateful-video-reference",
        "latent-step-reference",
    };
    const expected_lifecycles = [_]LifecycleV1{
        .stateless,
        .stateless,
        .stateless,
        .stateful,
        .stateless,
        .stateless,
        .stateful,
        .stateful,
    };
    for (profiles, expected_slugs, expected_lifecycles, 0..) |
        profile,
        expected_slug,
        expected_lifecycle,
        ordinal,
    | {
        try std.testing.expectEqual(
            ordinal,
            @as(usize, @intFromEnum(profile.index)),
        );
        try std.testing.expectEqualStrings(expected_slug, profile.slug);
        try std.testing.expectEqual(expected_lifecycle, profile.lifecycle);
        try std.testing.expectEqual(
            EvidenceV1.retained_reference_fixture,
            profile.evidence,
        );
    }

    try std.testing.expectEqual(
        vision.reference_adapter_abi,
        profiles[0].profile_abi,
    );
    try std.testing.expectEqual(vision.vision_support[0], profiles[0].support);
    try std.testing.expectEqual(
        audio_window.reference_adapter_abi,
        profiles[1].profile_abi,
    );
    try std.testing.expectEqual(
        audio_window.audio_support[0],
        profiles[1].support,
    );
    try std.testing.expectEqual(
        audio_transcript.reference_adapter_abi,
        profiles[2].profile_abi,
    );
    try std.testing.expectEqual(
        audio_transcript.transcript_support[0],
        profiles[2].support,
    );
    try std.testing.expectEqual(
        stateful_transcript.reference_adapter_abi,
        profiles[3].profile_abi,
    );
    try std.testing.expectEqual(
        stateful_transcript.transcript_state_support[0],
        profiles[3].support,
    );
    try std.testing.expectEqual(
        temporal_video.reference_adapter_abi,
        profiles[4].profile_abi,
    );
    try std.testing.expectEqual(
        temporal_video.video_support[0],
        profiles[4].support,
    );
    try std.testing.expectEqual(
        video_segment.reference_adapter_abi,
        profiles[5].profile_abi,
    );
    try std.testing.expectEqual(
        video_segment.video_segment_support[0],
        profiles[5].support,
    );
    try std.testing.expectEqual(
        stateful_video.reference_adapter_abi,
        profiles[6].profile_abi,
    );
    try std.testing.expectEqual(
        stateful_video.video_state_support[0],
        profiles[6].support,
    );
    try std.testing.expectEqual(
        latent_step.reference_adapter_abi,
        profiles[7].profile_abi,
    );
    try std.testing.expectEqual(
        latent_step.latent_step_support[0],
        profiles[7].support,
    );
}

test "query scans every profile and returns every compatible bit" {
    const support = profiles[2].support;
    const result = querySupportV1(queryFor(support, 1, 1, 1, 0));
    const stateless_bit = @as(u64, 1) <<
        @intFromEnum(ProfileIndexV1.audio_transcript);
    const stateful_bit = @as(u64, 1) <<
        @intFromEnum(ProfileIndexV1.stateful_transcript);
    try std.testing.expectEqual(
        stateless_bit | stateful_bit,
        result.matching_profile_mask,
    );
    try std.testing.expectEqual(
        @as(?model.UnsupportedReasonV1, null),
        result.deepest_unsupported_reason,
    );
}

test "query returns the deepest unsupported prefix reason" {
    const support = profiles[0].support;
    const baseline = queryFor(support, 1, 1, 1, 0);
    const cases = [_]struct {
        query: QueryV1,
        reason: model.UnsupportedReasonV1,
    }{
        .{
            .query = .{
                .family = .autoregressive,
                .operation = baseline.operation,
                .input_kind = baseline.input_kind,
                .output_kind = baseline.output_kind,
                .numerical_policy = baseline.numerical_policy,
                .batch_items = baseline.batch_items,
                .input_features = baseline.input_features,
                .output_dimensions = baseline.output_dimensions,
                .required_capabilities = baseline.required_capabilities,
            },
            .reason = .family,
        },
        .{
            .query = .{
                .family = baseline.family,
                .operation = .route,
                .input_kind = baseline.input_kind,
                .output_kind = baseline.output_kind,
                .numerical_policy = baseline.numerical_policy,
                .batch_items = baseline.batch_items,
                .input_features = baseline.input_features,
                .output_dimensions = baseline.output_dimensions,
                .required_capabilities = baseline.required_capabilities,
            },
            .reason = .operation,
        },
        .{
            .query = .{
                .family = baseline.family,
                .operation = baseline.operation,
                .input_kind = .dense_tensor,
                .output_kind = baseline.output_kind,
                .numerical_policy = baseline.numerical_policy,
                .batch_items = baseline.batch_items,
                .input_features = baseline.input_features,
                .output_dimensions = baseline.output_dimensions,
                .required_capabilities = baseline.required_capabilities,
            },
            .reason = .input_kind,
        },
        .{
            .query = .{
                .family = baseline.family,
                .operation = baseline.operation,
                .input_kind = baseline.input_kind,
                .output_kind = .class_scores,
                .numerical_policy = baseline.numerical_policy,
                .batch_items = baseline.batch_items,
                .input_features = baseline.input_features,
                .output_dimensions = baseline.output_dimensions,
                .required_capabilities = baseline.required_capabilities,
            },
            .reason = .output_kind,
        },
        .{
            .query = .{
                .family = baseline.family,
                .operation = baseline.operation,
                .input_kind = baseline.input_kind,
                .output_kind = baseline.output_kind,
                .numerical_policy = .strict_float32,
                .batch_items = baseline.batch_items,
                .input_features = baseline.input_features,
                .output_dimensions = baseline.output_dimensions,
                .required_capabilities = baseline.required_capabilities,
            },
            .reason = .numerical_policy,
        },
        .{
            .query = queryFor(
                support,
                support.max_batch_items + 1,
                1,
                1,
                0,
            ),
            .reason = .dimensions,
        },
        .{
            .query = queryFor(
                support,
                1,
                1,
                1,
                support.allowed_capabilities | 1,
            ),
            .reason = .capabilities,
        },
    };

    for (cases) |case| {
        const result = querySupportV1(case.query);
        try std.testing.expectEqual(@as(u64, 0), result.matching_profile_mask);
        try std.testing.expectEqual(
            case.reason,
            result.deepest_unsupported_reason.?,
        );
    }
}

test "query reports zero dimensions without matching a profile" {
    const support = profiles[0].support;
    inline for (.{
        queryFor(support, 0, 1, 1, 0),
        queryFor(support, 1, 0, 1, 0),
        queryFor(support, 1, 1, 0, 0),
    }) |query| {
        const result = querySupportV1(query);
        try std.testing.expectEqual(@as(u64, 0), result.matching_profile_mask);
        try std.testing.expectEqual(
            model.UnsupportedReasonV1.dimensions,
            result.deepest_unsupported_reason.?,
        );
    }
}
