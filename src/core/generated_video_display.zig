const std = @import("std");
const media = @import("media_contract.zig");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;

pub const state_abi: u64 = 1;
pub const state_body_bytes: usize = 480;
pub const state_bytes: usize = state_body_bytes + 32;

pub const manifest_abi: u64 = 1;
pub const manifest_body_bytes: usize = 704;
pub const manifest_bytes: usize = manifest_body_bytes + 32;

pub const provenance_abi: u64 = 1;
pub const provenance_body_bytes: usize = 608;
pub const provenance_bytes: usize = provenance_body_bytes + 32;

pub const result_abi: u64 = 1;
pub const result_body_bytes: usize = 640;
pub const result_bytes: usize = result_body_bytes + 32;

pub const observation_abi: u64 = 1;
pub const observation_body_bytes: usize = 288;
pub const observation_bytes: usize = observation_body_bytes + 32;

pub const ack_plan_abi: u64 = 1;
pub const ack_plan_body_bytes: usize = 448;
pub const ack_plan_bytes: usize = ack_plan_body_bytes + 32;

pub const ack_result_abi: u64 = 1;
pub const ack_result_body_bytes: usize = 480;
pub const ack_result_bytes: usize = ack_result_body_bytes + 32;

pub const runtime_abi: u64 = 1;
pub const raw_video_semantic_abi: u64 = 1;
pub const raw_container_id: u64 = 1;
pub const gray8_frame_codec_id: u64 = 1;
pub const reference_renderer_abi: u64 = 1;
pub const reference_renderer_payload = "gray8-frame-fill-v1";
pub const frames_per_segment: u64 = 2;
pub const maximum_dimension: u64 = 4096;
pub const maximum_channels: u64 = 1;
pub const maximum_time_denominator: u64 = 1_000_000_000;
pub const maximum_duration_ticks: u64 = 1_000_000_000;
pub const maximum_segment_duration_ticks: u64 =
    maximum_duration_ticks * frames_per_segment;
pub const maximum_source_bytes: u64 = 16 * 1024 * 1024;
pub const maximum_output_bytes: u64 = 256 * 1024 * 1024;

const state_wire = WireConfig{
    .magic = "GLVIDST1".*,
    .abi = state_abi,
    .body_bytes = state_body_bytes,
    .total_bytes = state_bytes,
    .domain = "glacier.generated-video-state.v1",
};
const manifest_wire = WireConfig{
    .magic = "GLVIDMF1".*,
    .abi = manifest_abi,
    .body_bytes = manifest_body_bytes,
    .total_bytes = manifest_bytes,
    .domain = "glacier.generated-video-manifest.v1",
};
const provenance_wire = WireConfig{
    .magic = "GLVIDPV1".*,
    .abi = provenance_abi,
    .body_bytes = provenance_body_bytes,
    .total_bytes = provenance_bytes,
    .domain = "glacier.generated-video-provenance.v1",
};
const result_wire = WireConfig{
    .magic = "GLVIDRS1".*,
    .abi = result_abi,
    .body_bytes = result_body_bytes,
    .total_bytes = result_bytes,
    .domain = "glacier.generated-video-result.v1",
};
const observation_wire = WireConfig{
    .magic = "GLVIDOB1".*,
    .abi = observation_abi,
    .body_bytes = observation_body_bytes,
    .total_bytes = observation_bytes,
    .domain = "glacier.display-observation.v1",
};
const ack_plan_wire = WireConfig{
    .magic = "GLVIDAP1".*,
    .abi = ack_plan_abi,
    .body_bytes = ack_plan_body_bytes,
    .total_bytes = ack_plan_bytes,
    .domain = "glacier.display-ack-plan.v1",
};
const ack_result_wire = WireConfig{
    .magic = "GLVIDAR1".*,
    .abi = ack_result_abi,
    .body_bytes = ack_result_body_bytes,
    .total_bytes = ack_result_bytes,
    .domain = "glacier.display-ack-result.v1",
};

const source_provenance_domain =
    "glacier.generated-video-source-provenance.v1";
const resource_domain = "glacier.generated-video-resource.v1";

const WireConfig = struct {
    magic: [8]u8,
    abi: u64,
    body_bytes: usize,
    total_bytes: usize,
    domain: []const u8,
};

pub const Error = error{
    InvalidState,
    InvalidStateRoot,
    InvalidManifest,
    InvalidManifestRoot,
    InvalidProvenance,
    InvalidProvenanceRoot,
    InvalidResult,
    InvalidResultRoot,
    InvalidObservation,
    InvalidObservationRoot,
    InvalidAckPlan,
    InvalidAckPlanRoot,
    InvalidAckResult,
    InvalidAckResultRoot,
    InvalidWire,
    InvalidBinding,
    InvalidMedia,
    ArithmeticOverflow,
    BufferTooSmall,
    BufferAlias,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
    CandidateInvalid,
    CandidateDrift,
    DisplayPending,
    NoDisplayPending,
};

pub const GeneratedVideoStateV1 = struct {
    request_epoch: u64,
    generation: u64,
    width: u64,
    height: u64,
    channels: u64,
    bytes_per_channel: u64,
    next_segment_index: u64,
    next_frame_ordinal: u64,
    next_start_tick: u64,
    visible_segments: u64,
    visible_frames: u64,
    visible_end_tick: u64,
    displayed_segments: u64,
    displayed_frames: u64,
    displayed_end_tick: u64,
    display_sequence: u64,
    pending: u64,
    pending_segment_index: u64,
    pending_first_frame: u64,
    pending_frame_count: u64,
    pending_start_tick: u64,
    pending_end_tick: u64,
    artifact_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    previous_publication_result_sha256: Digest,
    previous_ack_result_sha256: Digest,
    pending_publication_result_sha256: Digest,
    pending_output_sha256: Digest,
    challenge_sha256: Digest,
    state_sha256: Digest,
};

pub const GeneratedVideoManifestV1 = struct {
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    first_frame_ordinal: u64,
    frame_count: u64,
    width: u64,
    height: u64,
    channels: u64,
    bytes_per_channel: u64,
    row_stride: u64,
    frame_bytes: u64,
    total_output_bytes: u64,
    time_base_numerator: u64,
    time_base_denominator: u64,
    start_tick: u64,
    first_duration_ticks: u64,
    second_duration_ticks: u64,
    end_tick: u64,
    source_output_bytes: u64,
    maximum_output_bytes: u64,
    publication_sequence: u64,
    visible_segments_before: u64,
    visible_segments_after: u64,
    visible_frames_before: u64,
    visible_frames_after: u64,
    visible_end_tick_before: u64,
    visible_end_tick_after: u64,
    logical_units: u64,
    required_capabilities: u64,
    renderer_abi: u64,
    artifact_sha256: Digest,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    renderer_payload_sha256: Digest,
    renderer_implementation_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    previous_publication_result_sha256: Digest,
    media_object_sha256: Digest,
    state_before_sha256: Digest,
    first_frame_sha256: Digest,
    second_frame_sha256: Digest,
    manifest_sha256: Digest,
};

pub const GeneratedVideoProvenanceV1 = struct {
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    first_frame_ordinal: u64,
    frame_count: u64,
    width: u64,
    height: u64,
    channels: u64,
    bytes_per_channel: u64,
    row_stride: u64,
    frame_bytes: u64,
    total_output_bytes: u64,
    time_base_numerator: u64,
    time_base_denominator: u64,
    start_tick: u64,
    first_duration_ticks: u64,
    second_duration_ticks: u64,
    end_tick: u64,
    source_output_bytes: u64,
    renderer_abi: u64,
    manifest_sha256: Digest,
    artifact_sha256: Digest,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    renderer_payload_sha256: Digest,
    renderer_implementation_sha256: Digest,
    media_object_sha256: Digest,
    first_frame_sha256: Digest,
    second_frame_sha256: Digest,
    output_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    provenance_sha256: Digest,
};

pub const GeneratedVideoResultV1 = struct {
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    first_frame_ordinal: u64,
    frame_count: u64,
    end_frame_ordinal: u64,
    start_tick: u64,
    end_tick: u64,
    width: u64,
    height: u64,
    channels: u64,
    bytes_per_channel: u64,
    total_output_bytes: u64,
    publication_sequence: u64,
    visible_segments_before: u64,
    visible_segments_after: u64,
    visible_frames_before: u64,
    visible_frames_after: u64,
    visible_end_tick_before: u64,
    visible_end_tick_after: u64,
    manifest_sha256: Digest,
    provenance_sha256: Digest,
    artifact_sha256: Digest,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    media_object_sha256: Digest,
    first_frame_sha256: Digest,
    second_frame_sha256: Digest,
    output_sha256: Digest,
    resource_receipt_sha256: Digest,
    state_before_sha256: Digest,
    previous_publication_result_sha256: Digest,
    renderer_implementation_sha256: Digest,
    challenge_sha256: Digest,
    result_sha256: Digest,
};

pub const DisplayObservationV1 = struct {
    request_epoch: u64,
    display_sequence: u64,
    segment_index: u64,
    first_frame_ordinal: u64,
    frame_count: u64,
    consumed_frames: u64,
    start_tick: u64,
    end_tick: u64,
    width: u64,
    height: u64,
    channels: u64,
    bytes_per_channel: u64,
    publication_result_sha256: Digest,
    output_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    challenge_sha256: Digest,
    observation_sha256: Digest,
};

pub const DisplayAckPlanV1 = struct {
    request_epoch: u64,
    generation: u64,
    display_sequence: u64,
    segment_index: u64,
    first_frame_ordinal: u64,
    frame_count: u64,
    end_frame_ordinal: u64,
    start_tick: u64,
    end_tick: u64,
    consumed_frames: u64,
    displayed_segments_before: u64,
    displayed_segments_after: u64,
    displayed_frames_before: u64,
    displayed_frames_after: u64,
    displayed_end_tick_before: u64,
    displayed_end_tick_after: u64,
    state_before_sha256: Digest,
    publication_result_sha256: Digest,
    output_sha256: Digest,
    observation_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    challenge_sha256: Digest,
    previous_publication_result_sha256: Digest,
    previous_ack_result_sha256: Digest,
    plan_sha256: Digest,
};

pub const DisplayAckResultV1 = struct {
    request_epoch: u64,
    generation: u64,
    display_sequence: u64,
    segment_index: u64,
    first_frame_ordinal: u64,
    frame_count: u64,
    end_frame_ordinal: u64,
    start_tick: u64,
    end_tick: u64,
    consumed_frames: u64,
    displayed_segments_before: u64,
    displayed_segments_after: u64,
    displayed_frames_before: u64,
    displayed_frames_after: u64,
    displayed_end_tick_before: u64,
    displayed_end_tick_after: u64,
    plan_sha256: Digest,
    observation_sha256: Digest,
    state_before_sha256: Digest,
    publication_result_sha256: Digest,
    output_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    challenge_sha256: Digest,
    previous_publication_result_sha256: Digest,
    previous_ack_result_sha256: Digest,
    result_sha256: Digest,
};

pub const RendererV1 = struct {
    renderer_abi: u64,
    maximum_source_bytes: u64,
    maximum_output_bytes: u64,
    required_capabilities: u64,
    implementation_sha256: Digest,
    context: *anyopaque,
    execute: *const fn (
        context: *anyopaque,
        manifest: *const GeneratedVideoManifestV1,
        source_output: []const u8,
        renderer_payload: []const u8,
        output: []u8,
    ) anyerror!void,
    validate: *const fn (
        context: *anyopaque,
        manifest: *const GeneratedVideoManifestV1,
        source_output: []const u8,
        renderer_payload: []const u8,
        output: []const u8,
    ) anyerror!void,
};

pub fn initializeStateV1(
    request_epoch: u64,
    width: u64,
    height: u64,
    channels: u64,
    artifact_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
) Error!GeneratedVideoStateV1 {
    var state = GeneratedVideoStateV1{
        .request_epoch = request_epoch,
        .generation = 0,
        .width = width,
        .height = height,
        .channels = channels,
        .bytes_per_channel = 1,
        .next_segment_index = 0,
        .next_frame_ordinal = 0,
        .next_start_tick = 0,
        .visible_segments = 0,
        .visible_frames = 0,
        .visible_end_tick = 0,
        .displayed_segments = 0,
        .displayed_frames = 0,
        .displayed_end_tick = 0,
        .display_sequence = 0,
        .pending = 0,
        .pending_segment_index = 0,
        .pending_first_frame = 0,
        .pending_frame_count = 0,
        .pending_start_tick = 0,
        .pending_end_tick = 0,
        .artifact_sha256 = artifact_sha256,
        .tenant_scope_sha256 = tenant_scope_sha256,
        .metadata_policy_sha256 = metadata_policy_sha256,
        .previous_publication_result_sha256 = [_]u8{0} ** 32,
        .previous_ack_result_sha256 = [_]u8{0} ** 32,
        .pending_publication_result_sha256 = [_]u8{0} ** 32,
        .pending_output_sha256 = [_]u8{0} ** 32,
        .challenge_sha256 = challenge_sha256,
        .state_sha256 = [_]u8{0} ** 32,
    };
    state.state_sha256 = stateRootV1(state);
    try validateStateV1(state);
    return state;
}

pub fn validateStateV1(state: GeneratedVideoStateV1) Error!void {
    const expected_generation = checkedAdd(
        state.visible_segments,
        state.displayed_segments,
    ) catch return Error.InvalidState;
    const expected_visible_frames = checkedMul(
        state.visible_segments,
        frames_per_segment,
    ) catch return Error.InvalidState;
    const expected_displayed_frames = checkedMul(
        state.displayed_segments,
        frames_per_segment,
    ) catch return Error.InvalidState;
    if (state.request_epoch == 0 or
        state.generation != expected_generation or
        state.width == 0 or state.width > maximum_dimension or
        state.height == 0 or state.height > maximum_dimension or
        state.channels == 0 or state.channels > maximum_channels or
        state.bytes_per_channel != 1 or
        state.visible_frames != expected_visible_frames or
        state.displayed_frames != expected_displayed_frames or
        state.next_segment_index != state.visible_segments or
        state.next_frame_ordinal != state.visible_frames or
        state.next_start_tick != state.visible_end_tick or
        state.display_sequence != state.displayed_segments or
        state.displayed_segments > state.visible_segments or
        state.displayed_frames > state.visible_frames or
        state.displayed_end_tick > state.visible_end_tick or
        isZero(state.artifact_sha256) or
        isZero(state.tenant_scope_sha256) or
        isZero(state.metadata_policy_sha256) or
        isZero(state.challenge_sha256))
        return Error.InvalidState;
    if ((state.visible_segments == 0) !=
        isZero(state.previous_publication_result_sha256))
        return Error.InvalidState;
    if ((state.displayed_segments == 0) !=
        isZero(state.previous_ack_result_sha256))
        return Error.InvalidState;
    if (state.pending == 0) {
        if (state.visible_segments != state.displayed_segments or
            state.visible_frames != state.displayed_frames or
            state.visible_end_tick != state.displayed_end_tick or
            state.pending_segment_index != 0 or
            state.pending_first_frame != 0 or
            state.pending_frame_count != 0 or
            state.pending_start_tick != 0 or
            state.pending_end_tick != 0 or
            !isZero(state.pending_publication_result_sha256) or
            !isZero(state.pending_output_sha256))
            return Error.InvalidState;
    } else if (state.pending == 1) {
        const expected_segments = checkedAdd(
            state.displayed_segments,
            1,
        ) catch return Error.InvalidState;
        const expected_frames = checkedAdd(
            state.displayed_frames,
            state.pending_frame_count,
        ) catch return Error.InvalidState;
        const pending_duration = checkedSub(
            state.pending_end_tick,
            state.pending_start_tick,
        ) catch return Error.InvalidState;
        if (state.pending_frame_count != frames_per_segment or
            state.visible_segments != expected_segments or
            state.visible_frames != expected_frames or
            state.pending_segment_index != state.displayed_segments or
            state.pending_first_frame != state.displayed_frames or
            state.pending_start_tick != state.displayed_end_tick or
            state.pending_end_tick != state.visible_end_tick or
            state.pending_end_tick <= state.pending_start_tick or
            pending_duration > maximum_segment_duration_ticks or
            isZero(state.pending_publication_result_sha256) or
            isZero(state.pending_output_sha256))
            return Error.InvalidState;
    } else {
        return Error.InvalidState;
    }
    if (!digestEqual(state.state_sha256, stateRootV1(state)))
        return Error.InvalidStateRoot;
}

pub fn makeManifestV1(
    state_value: GeneratedVideoStateV1,
    first_duration_ticks: u64,
    second_duration_ticks: u64,
    source_output_bytes: u64,
    maximum_renderer_output_bytes: u64,
    required_capabilities: u64,
    renderer_abi_value: u64,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    renderer_payload_sha256: Digest,
    renderer_implementation_sha256: Digest,
    media_object_sha256: Digest,
    first_frame_sha256: Digest,
    second_frame_sha256: Digest,
) Error!GeneratedVideoManifestV1 {
    const state = state_value;
    try validateStateV1(state);
    if (state.pending != 0)
        return Error.DisplayPending;
    const row_stride = try checkedMul(
        try checkedMul(state.width, state.channels),
        state.bytes_per_channel,
    );
    const frame_bytes_value = try checkedMul(row_stride, state.height);
    const total_bytes = try checkedMul(
        frame_bytes_value,
        frames_per_segment,
    );
    const end_tick = try checkedAdd(
        try checkedAdd(state.next_start_tick, first_duration_ticks),
        second_duration_ticks,
    );
    const visible_segments_after = try checkedAdd(
        state.visible_segments,
        1,
    );
    const visible_frames_after = try checkedAdd(
        state.visible_frames,
        frames_per_segment,
    );
    const logical_units = try checkedMul(
        try checkedMul(
            try checkedMul(state.width, state.height),
            state.channels,
        ),
        frames_per_segment,
    );
    var manifest = GeneratedVideoManifestV1{
        .request_epoch = state.request_epoch,
        .generation = try checkedAdd(state.generation, 1),
        .segment_index = state.next_segment_index,
        .first_frame_ordinal = state.next_frame_ordinal,
        .frame_count = frames_per_segment,
        .width = state.width,
        .height = state.height,
        .channels = state.channels,
        .bytes_per_channel = state.bytes_per_channel,
        .row_stride = row_stride,
        .frame_bytes = frame_bytes_value,
        .total_output_bytes = total_bytes,
        .time_base_numerator = 1,
        .time_base_denominator = 1_000,
        .start_tick = state.next_start_tick,
        .first_duration_ticks = first_duration_ticks,
        .second_duration_ticks = second_duration_ticks,
        .end_tick = end_tick,
        .source_output_bytes = source_output_bytes,
        .maximum_output_bytes = maximum_renderer_output_bytes,
        .publication_sequence = state.next_segment_index,
        .visible_segments_before = state.visible_segments,
        .visible_segments_after = visible_segments_after,
        .visible_frames_before = state.visible_frames,
        .visible_frames_after = visible_frames_after,
        .visible_end_tick_before = state.visible_end_tick,
        .visible_end_tick_after = end_tick,
        .logical_units = logical_units,
        .required_capabilities = required_capabilities,
        .renderer_abi = renderer_abi_value,
        .artifact_sha256 = state.artifact_sha256,
        .source_result_sha256 = source_result_sha256,
        .source_output_sha256 = source_output_sha256,
        .renderer_payload_sha256 = renderer_payload_sha256,
        .renderer_implementation_sha256 = renderer_implementation_sha256,
        .tenant_scope_sha256 = state.tenant_scope_sha256,
        .metadata_policy_sha256 = state.metadata_policy_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .previous_publication_result_sha256 = state.previous_publication_result_sha256,
        .media_object_sha256 = media_object_sha256,
        .state_before_sha256 = state.state_sha256,
        .first_frame_sha256 = first_frame_sha256,
        .second_frame_sha256 = second_frame_sha256,
        .manifest_sha256 = [_]u8{0} ** 32,
    };
    manifest.manifest_sha256 = manifestRootV1(manifest);
    try validateManifestV1(manifest);
    return manifest;
}

pub fn validateManifestV1(
    manifest: GeneratedVideoManifestV1,
) Error!void {
    const expected_generation = checkedAdd(
        checkedMul(
            manifest.segment_index,
            2,
        ) catch return Error.InvalidManifest,
        1,
    ) catch return Error.InvalidManifest;
    const expected_first_frame = checkedMul(
        manifest.segment_index,
        frames_per_segment,
    ) catch return Error.InvalidManifest;
    const row_stride = checkedMul(
        checkedMul(
            manifest.width,
            manifest.channels,
        ) catch return Error.InvalidManifest,
        manifest.bytes_per_channel,
    ) catch return Error.InvalidManifest;
    const frame_bytes_value = checkedMul(
        row_stride,
        manifest.height,
    ) catch return Error.InvalidManifest;
    const total_bytes = checkedMul(
        frame_bytes_value,
        manifest.frame_count,
    ) catch return Error.InvalidManifest;
    const first_end = checkedAdd(
        manifest.start_tick,
        manifest.first_duration_ticks,
    ) catch return Error.InvalidManifest;
    const end_tick = checkedAdd(
        first_end,
        manifest.second_duration_ticks,
    ) catch return Error.InvalidManifest;
    const visible_segments_after = checkedAdd(
        manifest.visible_segments_before,
        1,
    ) catch return Error.InvalidManifest;
    const visible_frames_after = checkedAdd(
        manifest.visible_frames_before,
        manifest.frame_count,
    ) catch return Error.InvalidManifest;
    const logical_units = checkedMul(
        checkedMul(
            checkedMul(
                manifest.width,
                manifest.height,
            ) catch return Error.InvalidManifest,
            manifest.channels,
        ) catch return Error.InvalidManifest,
        manifest.frame_count,
    ) catch return Error.InvalidManifest;
    if (manifest.request_epoch == 0 or
        manifest.generation != expected_generation or
        manifest.frame_count != frames_per_segment or
        manifest.first_frame_ordinal != expected_first_frame or
        manifest.width == 0 or manifest.width > maximum_dimension or
        manifest.height == 0 or manifest.height > maximum_dimension or
        manifest.channels == 0 or manifest.channels > maximum_channels or
        manifest.bytes_per_channel != 1 or
        manifest.row_stride != row_stride or
        manifest.frame_bytes != frame_bytes_value or
        manifest.total_output_bytes != total_bytes or
        manifest.total_output_bytes == 0 or
        manifest.total_output_bytes > maximum_output_bytes or
        manifest.time_base_numerator != 1 or
        manifest.time_base_denominator == 0 or
        manifest.time_base_denominator > maximum_time_denominator or
        manifest.first_duration_ticks == 0 or
        manifest.first_duration_ticks > maximum_duration_ticks or
        manifest.second_duration_ticks == 0 or
        manifest.second_duration_ticks > maximum_duration_ticks or
        manifest.end_tick != end_tick or
        manifest.source_output_bytes == 0 or
        manifest.source_output_bytes > maximum_source_bytes or
        manifest.maximum_output_bytes < manifest.total_output_bytes or
        manifest.maximum_output_bytes > maximum_output_bytes or
        manifest.publication_sequence != manifest.segment_index or
        manifest.visible_segments_before != manifest.segment_index or
        manifest.visible_segments_after != visible_segments_after or
        manifest.visible_frames_before !=
            manifest.first_frame_ordinal or
        manifest.visible_frames_after != visible_frames_after or
        manifest.visible_end_tick_before != manifest.start_tick or
        manifest.visible_end_tick_after != manifest.end_tick or
        manifest.logical_units != logical_units or
        manifest.renderer_abi == 0 or
        isZero(manifest.artifact_sha256) or
        isZero(manifest.source_result_sha256) or
        isZero(manifest.source_output_sha256) or
        isZero(manifest.renderer_payload_sha256) or
        isZero(manifest.renderer_implementation_sha256) or
        isZero(manifest.tenant_scope_sha256) or
        isZero(manifest.metadata_policy_sha256) or
        isZero(manifest.challenge_sha256) or
        isZero(manifest.media_object_sha256) or
        isZero(manifest.state_before_sha256) or
        isZero(manifest.first_frame_sha256) or
        isZero(manifest.second_frame_sha256))
        return Error.InvalidManifest;
    if ((manifest.segment_index == 0) !=
        isZero(manifest.previous_publication_result_sha256))
        return Error.InvalidManifest;
    if (!digestEqual(
        manifest.manifest_sha256,
        manifestRootV1(manifest),
    ))
        return Error.InvalidManifestRoot;
}

pub fn sourceProvenanceRootV1(
    manifest: GeneratedVideoManifestV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_provenance_domain);
    inline for (.{
        manifest.request_epoch,
        manifest.segment_index,
        manifest.first_frame_ordinal,
        manifest.frame_count,
        manifest.width,
        manifest.height,
        manifest.channels,
        manifest.bytes_per_channel,
        manifest.row_stride,
        manifest.frame_bytes,
        manifest.total_output_bytes,
        manifest.time_base_numerator,
        manifest.time_base_denominator,
        manifest.start_tick,
        manifest.first_duration_ticks,
        manifest.second_duration_ticks,
        manifest.end_tick,
        manifest.source_output_bytes,
        manifest.renderer_abi,
    }) |scalar|
        hashU64(&hash, scalar);
    inline for (.{
        manifest.artifact_sha256,
        manifest.source_result_sha256,
        manifest.source_output_sha256,
        manifest.renderer_payload_sha256,
        manifest.renderer_implementation_sha256,
        manifest.tenant_scope_sha256,
        manifest.metadata_policy_sha256,
        manifest.challenge_sha256,
        manifest.first_frame_sha256,
        manifest.second_frame_sha256,
    }) |digest|
        hash.update(&digest);
    return hash.finalResult();
}

pub fn validatePublicationBindingsV1(
    manifest: GeneratedVideoManifestV1,
    state: GeneratedVideoStateV1,
    media_object: media.MediaObjectV1,
    renderer_payload: []const u8,
    renderer: RendererV1,
) Error!void {
    try validateManifestV1(manifest);
    try validateStateV1(state);
    const generation = checkedAdd(
        state.generation,
        1,
    ) catch return Error.InvalidBinding;
    if (state.pending != 0 or
        manifest.request_epoch != state.request_epoch or
        manifest.generation != generation or
        manifest.segment_index != state.next_segment_index or
        manifest.first_frame_ordinal != state.next_frame_ordinal or
        manifest.width != state.width or
        manifest.height != state.height or
        manifest.channels != state.channels or
        manifest.bytes_per_channel != state.bytes_per_channel or
        manifest.start_tick != state.next_start_tick or
        manifest.visible_segments_before != state.visible_segments or
        manifest.visible_frames_before != state.visible_frames or
        manifest.visible_end_tick_before != state.visible_end_tick or
        !digestEqual(
            manifest.artifact_sha256,
            state.artifact_sha256,
        ) or
        !digestEqual(
            manifest.tenant_scope_sha256,
            state.tenant_scope_sha256,
        ) or
        !digestEqual(
            manifest.metadata_policy_sha256,
            state.metadata_policy_sha256,
        ) or
        !digestEqual(
            manifest.challenge_sha256,
            state.challenge_sha256,
        ) or
        !digestEqual(
            manifest.previous_publication_result_sha256,
            state.previous_publication_result_sha256,
        ) or
        !digestEqual(
            manifest.state_before_sha256,
            state.state_sha256,
        ))
        return Error.InvalidBinding;
    if (renderer.renderer_abi != manifest.renderer_abi or
        renderer.maximum_source_bytes < manifest.source_output_bytes or
        renderer.maximum_output_bytes < manifest.total_output_bytes or
        renderer.required_capabilities !=
            manifest.required_capabilities or
        isZero(renderer.implementation_sha256) or
        !digestEqual(
            renderer.implementation_sha256,
            manifest.renderer_implementation_sha256,
        ) or
        !digestEqual(
            model.sha256(renderer_payload),
            manifest.renderer_payload_sha256,
        ))
        return Error.InvalidBinding;
    var media_wire_storage: [media.descriptor_bytes]u8 = undefined;
    const media_wire = media.encodeMediaObjectV1(
        media_object,
        &media_wire_storage,
    ) catch return Error.InvalidMedia;
    const media_root = media.mediaObjectSha256V1(
        media_wire,
    ) catch return Error.InvalidMedia;
    if (!digestEqual(manifest.media_object_sha256, media_root) or
        media_object.kind != .video or
        media_object.semantic_abi != raw_video_semantic_abi or
        media_object.container_id != raw_container_id or
        media_object.codec_id != gray8_frame_codec_id or
        media_object.byte_length != manifest.total_output_bytes or
        media_object.axes[0] != manifest.width or
        media_object.axes[1] != manifest.height or
        media_object.axes[2] != manifest.frame_count or
        media_object.time_base.numerator !=
            manifest.time_base_numerator or
        media_object.time_base.denominator !=
            manifest.time_base_denominator or
        !digestEqual(
            media_object.tenant_scope_sha256,
            manifest.tenant_scope_sha256,
        ) or
        !digestEqual(
            media_object.metadata_policy_sha256,
            manifest.metadata_policy_sha256,
        ) or
        !digestEqual(
            media_object.provenance_sha256,
            sourceProvenanceRootV1(manifest),
        ))
        return Error.InvalidMedia;
}

pub fn makeProvenanceV1(
    manifest: GeneratedVideoManifestV1,
    output_sha256: Digest,
) Error!GeneratedVideoProvenanceV1 {
    try validateManifestV1(manifest);
    if (isZero(output_sha256))
        return Error.InvalidProvenance;
    var provenance = GeneratedVideoProvenanceV1{
        .request_epoch = manifest.request_epoch,
        .generation = manifest.generation,
        .segment_index = manifest.segment_index,
        .first_frame_ordinal = manifest.first_frame_ordinal,
        .frame_count = manifest.frame_count,
        .width = manifest.width,
        .height = manifest.height,
        .channels = manifest.channels,
        .bytes_per_channel = manifest.bytes_per_channel,
        .row_stride = manifest.row_stride,
        .frame_bytes = manifest.frame_bytes,
        .total_output_bytes = manifest.total_output_bytes,
        .time_base_numerator = manifest.time_base_numerator,
        .time_base_denominator = manifest.time_base_denominator,
        .start_tick = manifest.start_tick,
        .first_duration_ticks = manifest.first_duration_ticks,
        .second_duration_ticks = manifest.second_duration_ticks,
        .end_tick = manifest.end_tick,
        .source_output_bytes = manifest.source_output_bytes,
        .renderer_abi = manifest.renderer_abi,
        .manifest_sha256 = manifest.manifest_sha256,
        .artifact_sha256 = manifest.artifact_sha256,
        .source_result_sha256 = manifest.source_result_sha256,
        .source_output_sha256 = manifest.source_output_sha256,
        .renderer_payload_sha256 = manifest.renderer_payload_sha256,
        .renderer_implementation_sha256 = manifest.renderer_implementation_sha256,
        .media_object_sha256 = manifest.media_object_sha256,
        .first_frame_sha256 = manifest.first_frame_sha256,
        .second_frame_sha256 = manifest.second_frame_sha256,
        .output_sha256 = output_sha256,
        .tenant_scope_sha256 = manifest.tenant_scope_sha256,
        .metadata_policy_sha256 = manifest.metadata_policy_sha256,
        .challenge_sha256 = manifest.challenge_sha256,
        .provenance_sha256 = [_]u8{0} ** 32,
    };
    provenance.provenance_sha256 =
        provenanceRootV1(provenance);
    try validateProvenanceV1(provenance);
    return provenance;
}

pub fn validateProvenanceV1(
    provenance: GeneratedVideoProvenanceV1,
) Error!void {
    const expected_generation = checkedAdd(
        checkedMul(
            provenance.segment_index,
            2,
        ) catch return Error.InvalidProvenance,
        1,
    ) catch return Error.InvalidProvenance;
    const expected_first_frame = checkedMul(
        provenance.segment_index,
        frames_per_segment,
    ) catch return Error.InvalidProvenance;
    const row_stride = checkedMul(
        checkedMul(
            provenance.width,
            provenance.channels,
        ) catch return Error.InvalidProvenance,
        provenance.bytes_per_channel,
    ) catch return Error.InvalidProvenance;
    const frame_bytes_value = checkedMul(
        row_stride,
        provenance.height,
    ) catch return Error.InvalidProvenance;
    const total_bytes = checkedMul(
        frame_bytes_value,
        provenance.frame_count,
    ) catch return Error.InvalidProvenance;
    const end_tick = checkedAdd(
        checkedAdd(
            provenance.start_tick,
            provenance.first_duration_ticks,
        ) catch return Error.InvalidProvenance,
        provenance.second_duration_ticks,
    ) catch return Error.InvalidProvenance;
    if (provenance.request_epoch == 0 or
        provenance.generation != expected_generation or
        provenance.frame_count != frames_per_segment or
        provenance.first_frame_ordinal != expected_first_frame or
        provenance.width == 0 or
        provenance.width > maximum_dimension or
        provenance.height == 0 or
        provenance.height > maximum_dimension or
        provenance.channels == 0 or
        provenance.channels > maximum_channels or
        provenance.bytes_per_channel != 1 or
        provenance.row_stride != row_stride or
        provenance.frame_bytes != frame_bytes_value or
        provenance.total_output_bytes != total_bytes or
        provenance.total_output_bytes == 0 or
        provenance.total_output_bytes > maximum_output_bytes or
        provenance.time_base_numerator != 1 or
        provenance.time_base_denominator == 0 or
        provenance.time_base_denominator >
            maximum_time_denominator or
        provenance.first_duration_ticks == 0 or
        provenance.first_duration_ticks > maximum_duration_ticks or
        provenance.second_duration_ticks == 0 or
        provenance.second_duration_ticks > maximum_duration_ticks or
        provenance.end_tick != end_tick or
        provenance.source_output_bytes == 0 or
        provenance.source_output_bytes > maximum_source_bytes or
        provenance.renderer_abi == 0 or
        isZero(provenance.manifest_sha256) or
        isZero(provenance.artifact_sha256) or
        isZero(provenance.source_result_sha256) or
        isZero(provenance.source_output_sha256) or
        isZero(provenance.renderer_payload_sha256) or
        isZero(provenance.renderer_implementation_sha256) or
        isZero(provenance.media_object_sha256) or
        isZero(provenance.first_frame_sha256) or
        isZero(provenance.second_frame_sha256) or
        isZero(provenance.output_sha256) or
        isZero(provenance.tenant_scope_sha256) or
        isZero(provenance.metadata_policy_sha256) or
        isZero(provenance.challenge_sha256))
        return Error.InvalidProvenance;
    if (!digestEqual(
        provenance.provenance_sha256,
        provenanceRootV1(provenance),
    ))
        return Error.InvalidProvenanceRoot;
}

pub fn validateProvenanceBindingV1(
    manifest: GeneratedVideoManifestV1,
    provenance: GeneratedVideoProvenanceV1,
) Error!void {
    try validateManifestV1(manifest);
    try validateProvenanceV1(provenance);
    if (provenance.request_epoch != manifest.request_epoch or
        provenance.generation != manifest.generation or
        provenance.segment_index != manifest.segment_index or
        provenance.first_frame_ordinal !=
            manifest.first_frame_ordinal or
        provenance.frame_count != manifest.frame_count or
        provenance.width != manifest.width or
        provenance.height != manifest.height or
        provenance.channels != manifest.channels or
        provenance.bytes_per_channel != manifest.bytes_per_channel or
        provenance.row_stride != manifest.row_stride or
        provenance.frame_bytes != manifest.frame_bytes or
        provenance.total_output_bytes != manifest.total_output_bytes or
        provenance.time_base_numerator !=
            manifest.time_base_numerator or
        provenance.time_base_denominator !=
            manifest.time_base_denominator or
        provenance.start_tick != manifest.start_tick or
        provenance.first_duration_ticks !=
            manifest.first_duration_ticks or
        provenance.second_duration_ticks !=
            manifest.second_duration_ticks or
        provenance.end_tick != manifest.end_tick or
        provenance.source_output_bytes !=
            manifest.source_output_bytes or
        provenance.renderer_abi != manifest.renderer_abi or
        !digestEqual(
            provenance.manifest_sha256,
            manifest.manifest_sha256,
        ) or
        !digestEqual(
            provenance.artifact_sha256,
            manifest.artifact_sha256,
        ) or
        !digestEqual(
            provenance.source_result_sha256,
            manifest.source_result_sha256,
        ) or
        !digestEqual(
            provenance.source_output_sha256,
            manifest.source_output_sha256,
        ) or
        !digestEqual(
            provenance.renderer_payload_sha256,
            manifest.renderer_payload_sha256,
        ) or
        !digestEqual(
            provenance.renderer_implementation_sha256,
            manifest.renderer_implementation_sha256,
        ) or
        !digestEqual(
            provenance.media_object_sha256,
            manifest.media_object_sha256,
        ) or
        !digestEqual(
            provenance.first_frame_sha256,
            manifest.first_frame_sha256,
        ) or
        !digestEqual(
            provenance.second_frame_sha256,
            manifest.second_frame_sha256,
        ) or
        !digestEqual(
            provenance.tenant_scope_sha256,
            manifest.tenant_scope_sha256,
        ) or
        !digestEqual(
            provenance.metadata_policy_sha256,
            manifest.metadata_policy_sha256,
        ) or
        !digestEqual(
            provenance.challenge_sha256,
            manifest.challenge_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn makeResultV1(
    manifest: GeneratedVideoManifestV1,
    provenance: GeneratedVideoProvenanceV1,
    receipt: resource_bank.Receipt,
) Error!GeneratedVideoResultV1 {
    try validateProvenanceBindingV1(manifest, provenance);
    var result = GeneratedVideoResultV1{
        .request_epoch = manifest.request_epoch,
        .generation = manifest.generation,
        .segment_index = manifest.segment_index,
        .first_frame_ordinal = manifest.first_frame_ordinal,
        .frame_count = manifest.frame_count,
        .end_frame_ordinal = manifest.visible_frames_after,
        .start_tick = manifest.start_tick,
        .end_tick = manifest.end_tick,
        .width = manifest.width,
        .height = manifest.height,
        .channels = manifest.channels,
        .bytes_per_channel = manifest.bytes_per_channel,
        .total_output_bytes = manifest.total_output_bytes,
        .publication_sequence = manifest.publication_sequence,
        .visible_segments_before = manifest.visible_segments_before,
        .visible_segments_after = manifest.visible_segments_after,
        .visible_frames_before = manifest.visible_frames_before,
        .visible_frames_after = manifest.visible_frames_after,
        .visible_end_tick_before = manifest.visible_end_tick_before,
        .visible_end_tick_after = manifest.visible_end_tick_after,
        .manifest_sha256 = manifest.manifest_sha256,
        .provenance_sha256 = provenance.provenance_sha256,
        .artifact_sha256 = manifest.artifact_sha256,
        .source_result_sha256 = manifest.source_result_sha256,
        .source_output_sha256 = manifest.source_output_sha256,
        .media_object_sha256 = manifest.media_object_sha256,
        .first_frame_sha256 = manifest.first_frame_sha256,
        .second_frame_sha256 = manifest.second_frame_sha256,
        .output_sha256 = provenance.output_sha256,
        .resource_receipt_sha256 = resourceReceiptRootV1(
            receipt,
            manifest.request_epoch,
            manifest.manifest_sha256,
            manifest.renderer_implementation_sha256,
        ),
        .state_before_sha256 = manifest.state_before_sha256,
        .previous_publication_result_sha256 = manifest.previous_publication_result_sha256,
        .renderer_implementation_sha256 = manifest.renderer_implementation_sha256,
        .challenge_sha256 = manifest.challenge_sha256,
        .result_sha256 = [_]u8{0} ** 32,
    };
    result.result_sha256 = resultRootV1(result);
    try validateResultV1(result);
    return result;
}

pub fn validateResultV1(result: GeneratedVideoResultV1) Error!void {
    const expected_generation = checkedAdd(
        checkedMul(
            result.segment_index,
            2,
        ) catch return Error.InvalidResult,
        1,
    ) catch return Error.InvalidResult;
    const expected_first_frame = checkedMul(
        result.segment_index,
        frames_per_segment,
    ) catch return Error.InvalidResult;
    const end_frame = checkedAdd(
        result.first_frame_ordinal,
        result.frame_count,
    ) catch return Error.InvalidResult;
    const duration = checkedSub(
        result.end_tick,
        result.start_tick,
    ) catch return Error.InvalidResult;
    const row_stride = checkedMul(
        checkedMul(
            result.width,
            result.channels,
        ) catch return Error.InvalidResult,
        result.bytes_per_channel,
    ) catch return Error.InvalidResult;
    const frame_bytes = checkedMul(
        row_stride,
        result.height,
    ) catch return Error.InvalidResult;
    const total_output_bytes = checkedMul(
        frame_bytes,
        result.frame_count,
    ) catch return Error.InvalidResult;
    const visible_segments_after = checkedAdd(
        result.visible_segments_before,
        1,
    ) catch return Error.InvalidResult;
    const visible_frames_after = checkedAdd(
        result.visible_frames_before,
        result.frame_count,
    ) catch return Error.InvalidResult;
    if (result.request_epoch == 0 or
        result.generation != expected_generation or
        result.frame_count != frames_per_segment or
        result.first_frame_ordinal != expected_first_frame or
        result.end_frame_ordinal != end_frame or
        result.end_tick <= result.start_tick or
        duration > maximum_segment_duration_ticks or
        result.width == 0 or result.width > maximum_dimension or
        result.height == 0 or result.height > maximum_dimension or
        result.channels == 0 or result.channels > maximum_channels or
        result.bytes_per_channel != 1 or
        result.total_output_bytes != total_output_bytes or
        result.total_output_bytes == 0 or
        result.total_output_bytes > maximum_output_bytes or
        result.publication_sequence != result.segment_index or
        result.visible_segments_before != result.segment_index or
        result.visible_segments_after != visible_segments_after or
        result.visible_frames_before != result.first_frame_ordinal or
        result.visible_frames_after != visible_frames_after or
        result.visible_end_tick_before != result.start_tick or
        result.visible_end_tick_after != result.end_tick or
        isZero(result.manifest_sha256) or
        isZero(result.provenance_sha256) or
        isZero(result.artifact_sha256) or
        isZero(result.source_result_sha256) or
        isZero(result.source_output_sha256) or
        isZero(result.media_object_sha256) or
        isZero(result.first_frame_sha256) or
        isZero(result.second_frame_sha256) or
        isZero(result.output_sha256) or
        isZero(result.resource_receipt_sha256) or
        isZero(result.state_before_sha256) or
        isZero(result.renderer_implementation_sha256) or
        isZero(result.challenge_sha256))
        return Error.InvalidResult;
    if ((result.segment_index == 0) !=
        isZero(result.previous_publication_result_sha256))
        return Error.InvalidResult;
    if (!digestEqual(result.result_sha256, resultRootV1(result)))
        return Error.InvalidResultRoot;
}

pub fn validateResultBindingV1(
    manifest: GeneratedVideoManifestV1,
    provenance: GeneratedVideoProvenanceV1,
    result: GeneratedVideoResultV1,
) Error!void {
    try validateProvenanceBindingV1(manifest, provenance);
    try validateResultV1(result);
    if (result.request_epoch != manifest.request_epoch or
        result.generation != manifest.generation or
        result.segment_index != manifest.segment_index or
        result.first_frame_ordinal != manifest.first_frame_ordinal or
        result.frame_count != manifest.frame_count or
        result.end_frame_ordinal != manifest.visible_frames_after or
        result.start_tick != manifest.start_tick or
        result.end_tick != manifest.end_tick or
        result.width != manifest.width or
        result.height != manifest.height or
        result.channels != manifest.channels or
        result.bytes_per_channel != manifest.bytes_per_channel or
        result.total_output_bytes != manifest.total_output_bytes or
        result.publication_sequence != manifest.publication_sequence or
        result.visible_segments_before !=
            manifest.visible_segments_before or
        result.visible_segments_after !=
            manifest.visible_segments_after or
        result.visible_frames_before != manifest.visible_frames_before or
        result.visible_frames_after != manifest.visible_frames_after or
        result.visible_end_tick_before !=
            manifest.visible_end_tick_before or
        result.visible_end_tick_after !=
            manifest.visible_end_tick_after or
        !digestEqual(result.manifest_sha256, manifest.manifest_sha256) or
        !digestEqual(
            result.provenance_sha256,
            provenance.provenance_sha256,
        ) or
        !digestEqual(result.artifact_sha256, manifest.artifact_sha256) or
        !digestEqual(
            result.source_result_sha256,
            manifest.source_result_sha256,
        ) or
        !digestEqual(
            result.source_output_sha256,
            manifest.source_output_sha256,
        ) or
        !digestEqual(
            result.media_object_sha256,
            manifest.media_object_sha256,
        ) or
        !digestEqual(
            result.first_frame_sha256,
            manifest.first_frame_sha256,
        ) or
        !digestEqual(
            result.second_frame_sha256,
            manifest.second_frame_sha256,
        ) or
        !digestEqual(result.output_sha256, provenance.output_sha256) or
        !digestEqual(
            result.state_before_sha256,
            manifest.state_before_sha256,
        ) or
        !digestEqual(
            result.previous_publication_result_sha256,
            manifest.previous_publication_result_sha256,
        ) or
        !digestEqual(
            result.renderer_implementation_sha256,
            manifest.renderer_implementation_sha256,
        ) or
        !digestEqual(
            result.challenge_sha256,
            manifest.challenge_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn stateAfterPublicationV1(
    state: GeneratedVideoStateV1,
    manifest: GeneratedVideoManifestV1,
    result: GeneratedVideoResultV1,
) Error!GeneratedVideoStateV1 {
    try validateStateV1(state);
    try validateManifestV1(manifest);
    try validateResultV1(result);
    if (state.pending != 0 or
        !digestEqual(
            manifest.state_before_sha256,
            state.state_sha256,
        ) or
        !digestEqual(result.manifest_sha256, manifest.manifest_sha256) or
        !digestEqual(
            result.previous_publication_result_sha256,
            state.previous_publication_result_sha256,
        ))
        return Error.InvalidBinding;
    var next = state;
    next.generation = manifest.generation;
    next.next_segment_index = manifest.visible_segments_after;
    next.next_frame_ordinal = manifest.visible_frames_after;
    next.next_start_tick = manifest.end_tick;
    next.visible_segments = manifest.visible_segments_after;
    next.visible_frames = manifest.visible_frames_after;
    next.visible_end_tick = manifest.end_tick;
    next.pending = 1;
    next.pending_segment_index = manifest.segment_index;
    next.pending_first_frame = manifest.first_frame_ordinal;
    next.pending_frame_count = manifest.frame_count;
    next.pending_start_tick = manifest.start_tick;
    next.pending_end_tick = manifest.end_tick;
    next.previous_publication_result_sha256 = result.result_sha256;
    next.pending_publication_result_sha256 = result.result_sha256;
    next.pending_output_sha256 = result.output_sha256;
    next.state_sha256 = [_]u8{0} ** 32;
    next.state_sha256 = stateRootV1(next);
    try validateStateV1(next);
    return next;
}

pub fn makeDisplayObservationV1(
    state: GeneratedVideoStateV1,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
) Error!DisplayObservationV1 {
    try validateStateV1(state);
    if (state.pending != 1)
        return Error.NoDisplayPending;
    if (isZero(sink_implementation_sha256) or
        isZero(sink_instance_sha256))
        return Error.InvalidObservation;
    var observation = DisplayObservationV1{
        .request_epoch = state.request_epoch,
        .display_sequence = state.display_sequence,
        .segment_index = state.pending_segment_index,
        .first_frame_ordinal = state.pending_first_frame,
        .frame_count = state.pending_frame_count,
        .consumed_frames = state.pending_frame_count,
        .start_tick = state.pending_start_tick,
        .end_tick = state.pending_end_tick,
        .width = state.width,
        .height = state.height,
        .channels = state.channels,
        .bytes_per_channel = state.bytes_per_channel,
        .publication_result_sha256 = state.pending_publication_result_sha256,
        .output_sha256 = state.pending_output_sha256,
        .sink_implementation_sha256 = sink_implementation_sha256,
        .sink_instance_sha256 = sink_instance_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .observation_sha256 = [_]u8{0} ** 32,
    };
    observation.observation_sha256 =
        observationRootV1(observation);
    try validateDisplayObservationV1(observation);
    return observation;
}

pub fn validateDisplayObservationV1(
    observation: DisplayObservationV1,
) Error!void {
    _ = checkedAdd(
        observation.first_frame_ordinal,
        observation.frame_count,
    ) catch return Error.InvalidObservation;
    const expected_first_frame = checkedMul(
        observation.segment_index,
        frames_per_segment,
    ) catch return Error.InvalidObservation;
    const duration = checkedSub(
        observation.end_tick,
        observation.start_tick,
    ) catch return Error.InvalidObservation;
    if (observation.request_epoch == 0 or
        observation.display_sequence != observation.segment_index or
        observation.frame_count != frames_per_segment or
        observation.first_frame_ordinal != expected_first_frame or
        observation.consumed_frames == 0 or
        observation.consumed_frames > observation.frame_count or
        observation.end_tick <= observation.start_tick or
        duration > maximum_segment_duration_ticks or
        observation.width == 0 or
        observation.width > maximum_dimension or
        observation.height == 0 or
        observation.height > maximum_dimension or
        observation.channels == 0 or
        observation.channels > maximum_channels or
        observation.bytes_per_channel != 1 or
        isZero(observation.publication_result_sha256) or
        isZero(observation.output_sha256) or
        isZero(observation.sink_implementation_sha256) or
        isZero(observation.sink_instance_sha256) or
        isZero(observation.challenge_sha256))
        return Error.InvalidObservation;
    if (!digestEqual(
        observation.observation_sha256,
        observationRootV1(observation),
    ))
        return Error.InvalidObservationRoot;
}

pub fn makeDisplayAckPlanV1(
    state: GeneratedVideoStateV1,
    publication_result: GeneratedVideoResultV1,
    observation: DisplayObservationV1,
) Error!DisplayAckPlanV1 {
    try validateStateV1(state);
    try validateResultV1(publication_result);
    try validateDisplayObservationV1(observation);
    if (state.pending != 1)
        return Error.NoDisplayPending;
    const generation = try checkedAdd(state.generation, 1);
    const displayed_segments_after = try checkedAdd(
        state.displayed_segments,
        1,
    );
    const displayed_frames_after = try checkedAdd(
        state.displayed_frames,
        state.pending_frame_count,
    );
    if (observation.consumed_frames != state.pending_frame_count or
        observation.request_epoch != state.request_epoch or
        observation.display_sequence != state.display_sequence or
        observation.segment_index != state.pending_segment_index or
        observation.first_frame_ordinal != state.pending_first_frame or
        observation.frame_count != state.pending_frame_count or
        observation.start_tick != state.pending_start_tick or
        observation.end_tick != state.pending_end_tick or
        observation.width != state.width or
        observation.height != state.height or
        observation.channels != state.channels or
        observation.bytes_per_channel != state.bytes_per_channel or
        !digestEqual(
            observation.publication_result_sha256,
            state.pending_publication_result_sha256,
        ) or
        !digestEqual(
            observation.output_sha256,
            state.pending_output_sha256,
        ) or
        !digestEqual(
            observation.challenge_sha256,
            state.challenge_sha256,
        ) or
        !digestEqual(
            publication_result.result_sha256,
            state.pending_publication_result_sha256,
        ) or
        !digestEqual(
            publication_result.output_sha256,
            state.pending_output_sha256,
        ))
        return Error.InvalidObservation;
    var plan = DisplayAckPlanV1{
        .request_epoch = state.request_epoch,
        .generation = generation,
        .display_sequence = state.display_sequence,
        .segment_index = state.pending_segment_index,
        .first_frame_ordinal = state.pending_first_frame,
        .frame_count = state.pending_frame_count,
        .end_frame_ordinal = displayed_frames_after,
        .start_tick = state.pending_start_tick,
        .end_tick = state.pending_end_tick,
        .consumed_frames = observation.consumed_frames,
        .displayed_segments_before = state.displayed_segments,
        .displayed_segments_after = displayed_segments_after,
        .displayed_frames_before = state.displayed_frames,
        .displayed_frames_after = displayed_frames_after,
        .displayed_end_tick_before = state.displayed_end_tick,
        .displayed_end_tick_after = state.pending_end_tick,
        .state_before_sha256 = state.state_sha256,
        .publication_result_sha256 = publication_result.result_sha256,
        .output_sha256 = publication_result.output_sha256,
        .observation_sha256 = observation.observation_sha256,
        .sink_implementation_sha256 = observation.sink_implementation_sha256,
        .sink_instance_sha256 = observation.sink_instance_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .previous_publication_result_sha256 = state.previous_publication_result_sha256,
        .previous_ack_result_sha256 = state.previous_ack_result_sha256,
        .plan_sha256 = [_]u8{0} ** 32,
    };
    plan.plan_sha256 = ackPlanRootV1(plan);
    try validateDisplayAckPlanV1(plan);
    return plan;
}

pub fn validateDisplayAckPlanV1(
    plan: DisplayAckPlanV1,
) Error!void {
    const expected_generation = checkedMul(
        checkedAdd(
            plan.segment_index,
            1,
        ) catch return Error.InvalidAckPlan,
        2,
    ) catch return Error.InvalidAckPlan;
    const expected_first_frame = checkedMul(
        plan.segment_index,
        frames_per_segment,
    ) catch return Error.InvalidAckPlan;
    const end_frame = checkedAdd(
        plan.first_frame_ordinal,
        plan.frame_count,
    ) catch return Error.InvalidAckPlan;
    const duration = checkedSub(
        plan.end_tick,
        plan.start_tick,
    ) catch return Error.InvalidAckPlan;
    const displayed_segments_after = checkedAdd(
        plan.displayed_segments_before,
        1,
    ) catch return Error.InvalidAckPlan;
    const displayed_frames_after = checkedAdd(
        plan.displayed_frames_before,
        plan.frame_count,
    ) catch return Error.InvalidAckPlan;
    if (plan.request_epoch == 0 or
        plan.generation != expected_generation or
        plan.frame_count != frames_per_segment or
        plan.first_frame_ordinal != expected_first_frame or
        plan.consumed_frames != plan.frame_count or
        plan.end_frame_ordinal != end_frame or
        plan.end_tick <= plan.start_tick or
        duration > maximum_segment_duration_ticks or
        plan.display_sequence != plan.displayed_segments_before or
        plan.segment_index != plan.displayed_segments_before or
        plan.first_frame_ordinal != plan.displayed_frames_before or
        plan.displayed_segments_after != displayed_segments_after or
        plan.displayed_frames_after != displayed_frames_after or
        plan.displayed_end_tick_before != plan.start_tick or
        plan.displayed_end_tick_after != plan.end_tick or
        isZero(plan.state_before_sha256) or
        isZero(plan.publication_result_sha256) or
        isZero(plan.output_sha256) or
        isZero(plan.observation_sha256) or
        isZero(plan.sink_implementation_sha256) or
        isZero(plan.sink_instance_sha256) or
        isZero(plan.challenge_sha256) or
        isZero(plan.previous_publication_result_sha256))
        return Error.InvalidAckPlan;
    if ((plan.displayed_segments_before == 0) !=
        isZero(plan.previous_ack_result_sha256))
        return Error.InvalidAckPlan;
    if (!digestEqual(plan.plan_sha256, ackPlanRootV1(plan)))
        return Error.InvalidAckPlanRoot;
}

pub fn validateDisplayAckBindingsV1(
    state: GeneratedVideoStateV1,
    publication_result: GeneratedVideoResultV1,
    observation: DisplayObservationV1,
    plan: DisplayAckPlanV1,
) Error!void {
    try validateStateV1(state);
    try validateResultV1(publication_result);
    try validateDisplayObservationV1(observation);
    try validateDisplayAckPlanV1(plan);
    const expected = try makeDisplayAckPlanV1(
        state,
        publication_result,
        observation,
    );
    if (!std.meta.eql(plan, expected))
        return Error.InvalidBinding;
}

pub fn makeDisplayAckResultV1(
    state: GeneratedVideoStateV1,
    publication_result: GeneratedVideoResultV1,
    observation: DisplayObservationV1,
    plan: DisplayAckPlanV1,
) Error!DisplayAckResultV1 {
    try validateDisplayAckBindingsV1(
        state,
        publication_result,
        observation,
        plan,
    );
    var result = DisplayAckResultV1{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .display_sequence = plan.display_sequence,
        .segment_index = plan.segment_index,
        .first_frame_ordinal = plan.first_frame_ordinal,
        .frame_count = plan.frame_count,
        .end_frame_ordinal = plan.end_frame_ordinal,
        .start_tick = plan.start_tick,
        .end_tick = plan.end_tick,
        .consumed_frames = plan.consumed_frames,
        .displayed_segments_before = plan.displayed_segments_before,
        .displayed_segments_after = plan.displayed_segments_after,
        .displayed_frames_before = plan.displayed_frames_before,
        .displayed_frames_after = plan.displayed_frames_after,
        .displayed_end_tick_before = plan.displayed_end_tick_before,
        .displayed_end_tick_after = plan.displayed_end_tick_after,
        .plan_sha256 = plan.plan_sha256,
        .observation_sha256 = observation.observation_sha256,
        .state_before_sha256 = state.state_sha256,
        .publication_result_sha256 = publication_result.result_sha256,
        .output_sha256 = publication_result.output_sha256,
        .sink_implementation_sha256 = observation.sink_implementation_sha256,
        .sink_instance_sha256 = observation.sink_instance_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .previous_publication_result_sha256 = state.previous_publication_result_sha256,
        .previous_ack_result_sha256 = state.previous_ack_result_sha256,
        .result_sha256 = [_]u8{0} ** 32,
    };
    result.result_sha256 = ackResultRootV1(result);
    try validateDisplayAckResultV1(result);
    return result;
}

pub fn validateDisplayAckResultV1(
    result: DisplayAckResultV1,
) Error!void {
    const expected_generation = checkedMul(
        checkedAdd(
            result.segment_index,
            1,
        ) catch return Error.InvalidAckResult,
        2,
    ) catch return Error.InvalidAckResult;
    const expected_first_frame = checkedMul(
        result.segment_index,
        frames_per_segment,
    ) catch return Error.InvalidAckResult;
    const end_frame = checkedAdd(
        result.first_frame_ordinal,
        result.frame_count,
    ) catch return Error.InvalidAckResult;
    const duration = checkedSub(
        result.end_tick,
        result.start_tick,
    ) catch return Error.InvalidAckResult;
    const displayed_segments_after = checkedAdd(
        result.displayed_segments_before,
        1,
    ) catch return Error.InvalidAckResult;
    const displayed_frames_after = checkedAdd(
        result.displayed_frames_before,
        result.frame_count,
    ) catch return Error.InvalidAckResult;
    if (result.request_epoch == 0 or
        result.generation != expected_generation or
        result.frame_count != frames_per_segment or
        result.first_frame_ordinal != expected_first_frame or
        result.consumed_frames != result.frame_count or
        result.end_frame_ordinal != end_frame or
        result.end_tick <= result.start_tick or
        duration > maximum_segment_duration_ticks or
        result.display_sequence != result.displayed_segments_before or
        result.segment_index != result.displayed_segments_before or
        result.first_frame_ordinal != result.displayed_frames_before or
        result.displayed_segments_after != displayed_segments_after or
        result.displayed_frames_after != displayed_frames_after or
        result.displayed_end_tick_before != result.start_tick or
        result.displayed_end_tick_after != result.end_tick or
        isZero(result.plan_sha256) or
        isZero(result.observation_sha256) or
        isZero(result.state_before_sha256) or
        isZero(result.publication_result_sha256) or
        isZero(result.output_sha256) or
        isZero(result.sink_implementation_sha256) or
        isZero(result.sink_instance_sha256) or
        isZero(result.challenge_sha256) or
        isZero(result.previous_publication_result_sha256))
        return Error.InvalidAckResult;
    if ((result.displayed_segments_before == 0) !=
        isZero(result.previous_ack_result_sha256))
        return Error.InvalidAckResult;
    if (!digestEqual(
        result.result_sha256,
        ackResultRootV1(result),
    ))
        return Error.InvalidAckResultRoot;
}

pub fn acknowledgeDisplayV1(
    state: *GeneratedVideoStateV1,
    publication_result: GeneratedVideoResultV1,
    observation: DisplayObservationV1,
    plan: DisplayAckPlanV1,
) Error!DisplayAckResultV1 {
    const result = try makeDisplayAckResultV1(
        state.*,
        publication_result,
        observation,
        plan,
    );
    var next = state.*;
    next.generation = plan.generation;
    next.displayed_segments = plan.displayed_segments_after;
    next.displayed_frames = plan.displayed_frames_after;
    next.displayed_end_tick = plan.displayed_end_tick_after;
    next.display_sequence = try checkedAdd(plan.display_sequence, 1);
    next.pending = 0;
    next.pending_segment_index = 0;
    next.pending_first_frame = 0;
    next.pending_frame_count = 0;
    next.pending_start_tick = 0;
    next.pending_end_tick = 0;
    next.pending_publication_result_sha256 = [_]u8{0} ** 32;
    next.pending_output_sha256 = [_]u8{0} ** 32;
    next.previous_ack_result_sha256 = result.result_sha256;
    next.state_sha256 = [_]u8{0} ** 32;
    next.state_sha256 = stateRootV1(next);
    try validateStateV1(next);
    state.* = next;
    return result;
}

pub fn encodeStateV1(
    value: GeneratedVideoStateV1,
    output: []u8,
) Error![]const u8 {
    try validateStateV1(value);
    return encodeRecordV1(
        GeneratedVideoStateV1,
        state_wire,
        value,
        output,
    );
}

pub fn decodeStateV1(input: []const u8) Error!GeneratedVideoStateV1 {
    const value = try decodeRecordV1(
        GeneratedVideoStateV1,
        state_wire,
        input,
    );
    try validateStateV1(value);
    return value;
}

pub fn encodeManifestV1(
    value: GeneratedVideoManifestV1,
    output: []u8,
) Error![]const u8 {
    try validateManifestV1(value);
    return encodeRecordV1(
        GeneratedVideoManifestV1,
        manifest_wire,
        value,
        output,
    );
}

pub fn decodeManifestV1(
    input: []const u8,
) Error!GeneratedVideoManifestV1 {
    const value = try decodeRecordV1(
        GeneratedVideoManifestV1,
        manifest_wire,
        input,
    );
    try validateManifestV1(value);
    return value;
}

pub fn encodeProvenanceV1(
    value: GeneratedVideoProvenanceV1,
    output: []u8,
) Error![]const u8 {
    try validateProvenanceV1(value);
    return encodeRecordV1(
        GeneratedVideoProvenanceV1,
        provenance_wire,
        value,
        output,
    );
}

pub fn decodeProvenanceV1(
    input: []const u8,
) Error!GeneratedVideoProvenanceV1 {
    const value = try decodeRecordV1(
        GeneratedVideoProvenanceV1,
        provenance_wire,
        input,
    );
    try validateProvenanceV1(value);
    return value;
}

pub fn encodeResultV1(
    value: GeneratedVideoResultV1,
    output: []u8,
) Error![]const u8 {
    try validateResultV1(value);
    return encodeRecordV1(
        GeneratedVideoResultV1,
        result_wire,
        value,
        output,
    );
}

pub fn decodeResultV1(
    input: []const u8,
) Error!GeneratedVideoResultV1 {
    const value = try decodeRecordV1(
        GeneratedVideoResultV1,
        result_wire,
        input,
    );
    try validateResultV1(value);
    return value;
}

pub fn encodeDisplayObservationV1(
    value: DisplayObservationV1,
    output: []u8,
) Error![]const u8 {
    try validateDisplayObservationV1(value);
    return encodeRecordV1(
        DisplayObservationV1,
        observation_wire,
        value,
        output,
    );
}

pub fn decodeDisplayObservationV1(
    input: []const u8,
) Error!DisplayObservationV1 {
    const value = try decodeRecordV1(
        DisplayObservationV1,
        observation_wire,
        input,
    );
    try validateDisplayObservationV1(value);
    return value;
}

pub fn encodeDisplayAckPlanV1(
    value: DisplayAckPlanV1,
    output: []u8,
) Error![]const u8 {
    try validateDisplayAckPlanV1(value);
    return encodeRecordV1(
        DisplayAckPlanV1,
        ack_plan_wire,
        value,
        output,
    );
}

pub fn decodeDisplayAckPlanV1(
    input: []const u8,
) Error!DisplayAckPlanV1 {
    const value = try decodeRecordV1(
        DisplayAckPlanV1,
        ack_plan_wire,
        input,
    );
    try validateDisplayAckPlanV1(value);
    return value;
}

pub fn encodeDisplayAckResultV1(
    value: DisplayAckResultV1,
    output: []u8,
) Error![]const u8 {
    try validateDisplayAckResultV1(value);
    return encodeRecordV1(
        DisplayAckResultV1,
        ack_result_wire,
        value,
        output,
    );
}

pub fn decodeDisplayAckResultV1(
    input: []const u8,
) Error!DisplayAckResultV1 {
    const value = try decodeRecordV1(
        DisplayAckResultV1,
        ack_result_wire,
        input,
    );
    try validateDisplayAckResultV1(value);
    return value;
}

pub fn stateRootV1(value: GeneratedVideoStateV1) Digest {
    return recordRootV1(GeneratedVideoStateV1, state_wire, value);
}

pub fn manifestRootV1(value: GeneratedVideoManifestV1) Digest {
    return recordRootV1(
        GeneratedVideoManifestV1,
        manifest_wire,
        value,
    );
}

pub fn provenanceRootV1(value: GeneratedVideoProvenanceV1) Digest {
    return recordRootV1(
        GeneratedVideoProvenanceV1,
        provenance_wire,
        value,
    );
}

pub fn resultRootV1(value: GeneratedVideoResultV1) Digest {
    return recordRootV1(GeneratedVideoResultV1, result_wire, value);
}

pub fn observationRootV1(value: DisplayObservationV1) Digest {
    return recordRootV1(
        DisplayObservationV1,
        observation_wire,
        value,
    );
}

pub fn ackPlanRootV1(value: DisplayAckPlanV1) Digest {
    return recordRootV1(DisplayAckPlanV1, ack_plan_wire, value);
}

pub fn ackResultRootV1(value: DisplayAckResultV1) Digest {
    return recordRootV1(
        DisplayAckResultV1,
        ack_result_wire,
        value,
    );
}

pub fn claimForManifestV1(
    manifest: GeneratedVideoManifestV1,
    renderer_payload_bytes: u64,
) Error!resource_bank.Claim {
    try validateManifestV1(manifest);
    const private_bytes = try checkedAdd(
        manifest.total_output_bytes,
        provenance_bytes + result_bytes,
    );
    return .{
        .capsule_bytes = renderer_payload_bytes,
        .kv_bytes = 0,
        .activation_bytes = manifest.source_output_bytes,
        .partial_bytes = private_bytes,
        .logits_bytes = 0,
        .output_journal_bytes = private_bytes,
        .staging_bytes = 0,
        .device_bytes = 0,
        .io_bytes = 0,
        .queue_slots = 1,
    };
}

pub fn resourceReceiptRootV1(
    receipt: resource_bank.Receipt,
    request_epoch: u64,
    manifest_sha256: Digest,
    renderer_implementation_sha256: Digest,
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
    hash.update(&manifest_sha256);
    hash.update(&renderer_implementation_sha256);
    return hash.finalResult();
}

pub fn referenceRendererImplementationSha256V1() Digest {
    return model.sha256(
        "reference exact gray8 frame-fill renderer v1",
    );
}

pub fn referenceRendererV1(context: *anyopaque) RendererV1 {
    return .{
        .renderer_abi = reference_renderer_abi,
        .maximum_source_bytes = maximum_source_bytes,
        .maximum_output_bytes = maximum_output_bytes,
        .required_capabilities = 0,
        .implementation_sha256 = referenceRendererImplementationSha256V1(),
        .context = context,
        .execute = renderReferenceFramesV1,
        .validate = validateReferenceFramesV1,
    };
}

pub fn renderReferenceFramesV1(
    _: *anyopaque,
    manifest: *const GeneratedVideoManifestV1,
    source_output: []const u8,
    renderer_payload: []const u8,
    output: []u8,
) anyerror!void {
    try validateManifestV1(manifest.*);
    if (!std.mem.eql(
        u8,
        renderer_payload,
        reference_renderer_payload,
    ) or
        manifest.renderer_abi != reference_renderer_abi or
        manifest.source_output_bytes != frames_per_segment or
        source_output.len != frames_per_segment or
        output.len != manifest.total_output_bytes)
        return Error.CandidateInvalid;
    const frame_bytes_value = std.math.cast(
        usize,
        manifest.frame_bytes,
    ) orelse return Error.ArithmeticOverflow;
    @memset(output[0..frame_bytes_value], source_output[0]);
    @memset(output[frame_bytes_value..], source_output[1]);
}

pub fn validateReferenceFramesV1(
    _: *anyopaque,
    manifest: *const GeneratedVideoManifestV1,
    source_output: []const u8,
    renderer_payload: []const u8,
    output: []const u8,
) anyerror!void {
    const output_bytes_value = std.math.cast(
        usize,
        manifest.total_output_bytes,
    ) orelse return Error.ArithmeticOverflow;
    if (output.len != output_bytes_value or
        source_output.len != frames_per_segment or
        manifest.source_output_bytes != frames_per_segment or
        !std.mem.eql(
            u8,
            renderer_payload,
            reference_renderer_payload,
        ))
        return Error.CandidateInvalid;
    const frame_bytes_value = std.math.cast(
        usize,
        manifest.frame_bytes,
    ) orelse return Error.ArithmeticOverflow;
    for (output[0..frame_bytes_value]) |pixel| {
        if (pixel != source_output[0])
            return Error.CandidateInvalid;
    }
    for (output[frame_bytes_value..]) |pixel| {
        if (pixel != source_output[1])
            return Error.CandidateInvalid;
    }
    if (!digestEqual(
        model.sha256(output[0..frame_bytes_value]),
        manifest.first_frame_sha256,
    ) or
        !digestEqual(
            model.sha256(output[frame_bytes_value..]),
            manifest.second_frame_sha256,
        ))
        return Error.CandidateInvalid;
}

fn encodeRecordV1(
    comptime T: type,
    comptime config: WireConfig,
    value: T,
    output: []u8,
) Error![]const u8 {
    if (output.len < config.total_bytes)
        return Error.BufferTooSmall;
    writeRecordBodyV1(T, config, value, output[0..config.body_bytes]);
    const fields = std.meta.fields(T);
    const root_field = fields[fields.len - 1];
    if (root_field.type != Digest)
        @compileError("wire root must be the final digest field");
    @memcpy(
        output[config.body_bytes..config.total_bytes],
        &@field(value, root_field.name),
    );
    return output[0..config.total_bytes];
}

fn decodeRecordV1(
    comptime T: type,
    comptime config: WireConfig,
    input: []const u8,
) Error!T {
    if (input.len != config.total_bytes or
        !std.mem.eql(u8, input[0..8], &config.magic) or
        readU64(input, 8) != config.abi or
        readU64(input, 16) != config.total_bytes or
        readU64(input, 24) != 0)
        return Error.InvalidWire;
    const expected_root = domainRoot(
        config.domain,
        input[0..config.body_bytes],
    );
    if (!std.mem.eql(
        u8,
        input[config.body_bytes..config.total_bytes],
        &expected_root,
    ))
        return Error.InvalidWire;
    var value: T = undefined;
    var offset: usize = 32;
    const fields = std.meta.fields(T);
    inline for (fields[0 .. fields.len - 1]) |field| {
        if (field.type == u64) {
            if (offset + 8 > config.body_bytes)
                return Error.InvalidWire;
            @field(value, field.name) = readU64(input, offset);
            offset += 8;
        } else if (field.type == Digest) {
            if (offset + 32 > config.body_bytes)
                return Error.InvalidWire;
            @memcpy(
                &@field(value, field.name),
                input[offset .. offset + 32],
            );
            offset += 32;
        } else {
            @compileError("unsupported canonical wire field type");
        }
    }
    for (input[offset..config.body_bytes]) |byte| {
        if (byte != 0)
            return Error.InvalidWire;
    }
    const root_field = fields[fields.len - 1];
    if (root_field.type != Digest)
        @compileError("wire root must be the final digest field");
    @memcpy(
        &@field(value, root_field.name),
        input[config.body_bytes..config.total_bytes],
    );
    return value;
}

fn recordRootV1(
    comptime T: type,
    comptime config: WireConfig,
    value: T,
) Digest {
    var body: [config.body_bytes]u8 = undefined;
    writeRecordBodyV1(T, config, value, &body);
    return domainRoot(config.domain, &body);
}

fn writeRecordBodyV1(
    comptime T: type,
    comptime config: WireConfig,
    value: T,
    output: []u8,
) void {
    std.debug.assert(output.len == config.body_bytes);
    @memset(output, 0);
    @memcpy(output[0..8], &config.magic);
    writeU64(output, 8, config.abi);
    writeU64(output, 16, config.total_bytes);
    writeU64(output, 24, 0);
    var offset: usize = 32;
    const fields = std.meta.fields(T);
    inline for (fields[0 .. fields.len - 1]) |field| {
        if (field.type == u64) {
            writeU64(output, offset, @field(value, field.name));
            offset += 8;
        } else if (field.type == Digest) {
            @memcpy(
                output[offset .. offset + 32],
                &@field(value, field.name),
            );
            offset += 32;
        } else {
            @compileError("unsupported canonical wire field type");
        }
    }
    std.debug.assert(offset <= config.body_bytes);
}

fn domainRoot(domain: []const u8, body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(body);
    return hash.finalResult();
}

const Phase = enum {
    idle,
    prepared,
    poisoned,
    closed,
};

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    state: *GeneratedVideoStateV1 = undefined,
    receipt: resource_bank.Receipt = undefined,
    manifest: GeneratedVideoManifestV1 = undefined,
    media_object: media.MediaObjectV1 = undefined,
    renderer: RendererV1 = undefined,
    renderer_payload: []const u8 = &[_]u8{},
    permit: ?resource_bank.PublicationPermit = null,
    prepared_provenance: ?GeneratedVideoProvenanceV1 = null,
    prepared_result: ?GeneratedVideoResultV1 = null,
    prepared_state_after: ?GeneratedVideoStateV1 = null,
    source_output: []const u8 = &[_]u8{},
    candidate_output: ?[]u8 = null,
    candidate_provenance: ?[]u8 = null,
    candidate_result: ?[]u8 = null,
    visible_output: ?[]u8 = null,
    visible_provenance: ?[]u8 = null,
    visible_result: ?[]u8 = null,
    expected_output_sha256: Digest = [_]u8{0} ** 32,
    expected_provenance_wire_sha256: Digest = [_]u8{0} ** 32,
    expected_result_wire_sha256: Digest = [_]u8{0} ** 32,
    expected_state_sha256: Digest = [_]u8{0} ** 32,
    next_resource_sequence: u64 = 0,
    initialized: bool = false,
    phase: Phase = .idle,

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        state: *GeneratedVideoStateV1,
        manifest: GeneratedVideoManifestV1,
        media_object: media.MediaObjectV1,
        renderer_payload: []const u8,
        renderer: RendererV1,
    ) Error!void {
        if (self.initialized or self.phase != .idle or owner_key == 0)
            return Error.InvalidState;
        try validatePublicationBindingsV1(
            manifest,
            state.*,
            media_object,
            renderer_payload,
            renderer,
        );
        const payload_bytes = std.math.cast(
            u64,
            renderer_payload.len,
        ) orelse return Error.ArithmeticOverflow;
        const claim = try claimForManifestV1(
            manifest,
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
            manifest.request_epoch,
            @intFromPtr(self),
        ) catch {
            bank.release(receipt) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        self.* = .{
            .bank = bank,
            .state = state,
            .receipt = receipt,
            .manifest = manifest,
            .media_object = media_object,
            .renderer = renderer,
            .renderer_payload = renderer_payload,
            .initialized = true,
        };
    }

    pub fn prepareV1(
        self: *Session,
        source_output: []const u8,
        candidate_output_storage: []u8,
        candidate_provenance_storage: []u8,
        candidate_result_storage: []u8,
        visible_output_storage: []u8,
        visible_provenance_storage: []u8,
        visible_result_storage: []u8,
    ) Error!GeneratedVideoResultV1 {
        if (!self.initialized or self.phase != .idle or
            self.permit != null)
            return Error.InvalidState;
        try validatePublicationBindingsV1(
            self.manifest,
            self.state.*,
            self.media_object,
            self.renderer_payload,
            self.renderer,
        );
        const output_bytes_value = std.math.cast(
            usize,
            self.manifest.total_output_bytes,
        ) orelse return Error.ArithmeticOverflow;
        if (source_output.len != self.manifest.source_output_bytes or
            candidate_output_storage.len < output_bytes_value or
            candidate_provenance_storage.len < provenance_bytes or
            candidate_result_storage.len < result_bytes or
            visible_output_storage.len < output_bytes_value or
            visible_provenance_storage.len < provenance_bytes or
            visible_result_storage.len < result_bytes)
            return Error.BufferTooSmall;
        if (!digestEqual(
            model.sha256(source_output),
            self.manifest.source_output_sha256,
        ))
            return Error.InvalidBinding;
        const candidate_output =
            candidate_output_storage[0..output_bytes_value];
        const candidate_provenance =
            candidate_provenance_storage[0..provenance_bytes];
        const candidate_result =
            candidate_result_storage[0..result_bytes];
        const visible_output =
            visible_output_storage[0..output_bytes_value];
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
            source_output,
            self.renderer_payload,
            std.mem.asBytes(&self.manifest),
            std.mem.asBytes(&self.media_object),
            std.mem.asBytes(self.state),
        };
        if (!buffersDisjoint(&mutable, &immutable))
            return Error.BufferAlias;
        @memset(candidate_output, 0);
        @memset(candidate_provenance, 0);
        @memset(candidate_result, 0);
        const permit = self.bank.beginPublication(
            self.receipt,
            self.manifest.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.permit = permit;
        self.source_output = source_output;
        self.candidate_output = candidate_output;
        self.candidate_provenance = candidate_provenance;
        self.candidate_result = candidate_result;
        self.visible_output = visible_output;
        self.visible_provenance = visible_provenance;
        self.visible_result = visible_result;
        self.phase = .prepared;
        self.renderer.execute(
            self.renderer.context,
            &self.manifest,
            source_output,
            self.renderer_payload,
            candidate_output,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateInvalid;
        };
        self.renderer.validate(
            self.renderer.context,
            &self.manifest,
            source_output,
            self.renderer_payload,
            candidate_output,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateInvalid;
        };
        const output_sha256 = model.sha256(candidate_output);
        if (!digestEqual(
            output_sha256,
            self.media_object.content_sha256,
        )) {
            try self.rollbackV1(permit);
            return Error.CandidateInvalid;
        }
        const provenance = makeProvenanceV1(
            self.manifest,
            output_sha256,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidProvenance;
        };
        var provenance_storage: [provenance_bytes]u8 = undefined;
        _ = encodeProvenanceV1(
            provenance,
            &provenance_storage,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidProvenance;
        };
        @memcpy(candidate_provenance, &provenance_storage);
        const result = makeResultV1(
            self.manifest,
            provenance,
            self.receipt,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidResult;
        };
        var result_storage: [result_bytes]u8 = undefined;
        _ = encodeResultV1(result, &result_storage) catch {
            try self.rollbackV1(permit);
            return Error.InvalidResult;
        };
        @memcpy(candidate_result, &result_storage);
        const state_after = stateAfterPublicationV1(
            self.state.*,
            self.manifest,
            result,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidState;
        };
        self.prepared_provenance = provenance;
        self.prepared_result = result;
        self.prepared_state_after = state_after;
        self.expected_output_sha256 = output_sha256;
        self.expected_provenance_wire_sha256 =
            model.sha256(candidate_provenance);
        self.expected_result_wire_sha256 =
            model.sha256(candidate_result);
        self.expected_state_sha256 = self.state.state_sha256;
        return result;
    }

    pub fn commitV1(self: *Session) Error!GeneratedVideoResultV1 {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse
            return Error.InvalidState;
        const expected_provenance =
            self.prepared_provenance orelse
            return Error.InvalidState;
        const expected_result = self.prepared_result orelse
            return Error.InvalidState;
        const expected_state_after =
            self.prepared_state_after orelse
            return Error.InvalidState;
        const candidate_output = self.candidate_output orelse
            return Error.InvalidState;
        const candidate_provenance =
            self.candidate_provenance orelse
            return Error.InvalidState;
        const candidate_result = self.candidate_result orelse
            return Error.InvalidState;
        const visible_output = self.visible_output orelse
            return Error.InvalidState;
        const visible_provenance = self.visible_provenance orelse
            return Error.InvalidState;
        const visible_result = self.visible_result orelse
            return Error.InvalidState;
        self.bank.validatePublication(permit) catch {
            try self.rollbackV1(permit);
            return Error.ResourceReceiptInvalid;
        };
        validatePublicationBindingsV1(
            self.manifest,
            self.state.*,
            self.media_object,
            self.renderer_payload,
            self.renderer,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!digestEqual(
            self.state.state_sha256,
            self.expected_state_sha256,
        ) or
            !digestEqual(
                model.sha256(self.source_output),
                self.manifest.source_output_sha256,
            ) or
            !digestEqual(
                model.sha256(candidate_output),
                self.expected_output_sha256,
            ) or
            !digestEqual(
                model.sha256(candidate_provenance),
                self.expected_provenance_wire_sha256,
            ) or
            !digestEqual(
                model.sha256(candidate_result),
                self.expected_result_wire_sha256,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        self.renderer.validate(
            self.renderer.context,
            &self.manifest,
            self.source_output,
            self.renderer_payload,
            candidate_output,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const decoded_provenance = decodeProvenanceV1(
            candidate_provenance,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const decoded_result = decodeResultV1(
            candidate_result,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const reconstructed_provenance = makeProvenanceV1(
            self.manifest,
            model.sha256(candidate_output),
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const reconstructed_result = makeResultV1(
            self.manifest,
            reconstructed_provenance,
            self.receipt,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const reconstructed_state_after = stateAfterPublicationV1(
            self.state.*,
            self.manifest,
            reconstructed_result,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.meta.eql(decoded_provenance, expected_provenance) or
            !std.meta.eql(
                decoded_provenance,
                reconstructed_provenance,
            ) or
            !std.meta.eql(decoded_result, expected_result) or
            !std.meta.eql(decoded_result, reconstructed_result) or
            !std.meta.eql(
                expected_state_after,
                reconstructed_state_after,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        @memcpy(visible_output, candidate_output);
        @memcpy(visible_provenance, candidate_provenance);
        @memcpy(visible_result, candidate_result);
        self.state.* = reconstructed_state_after;
        self.bank.commitPublicationAssumeValid(permit);
        self.next_resource_sequence = permit.sequence + 1;
        self.scrubCandidatesV1();
        self.clearPreparedV1();
        self.phase = .idle;
        return decoded_result;
    }

    pub fn abortV1(self: *Session) Error!void {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse
            return Error.InvalidState;
        try self.rollbackV1(permit);
    }

    pub fn closeAndRelease(self: *Session) Error!void {
        if (!self.initialized or self.phase != .idle)
            return Error.InvalidState;
        self.bank.closePublicationSession(
            self.receipt,
            self.manifest.request_epoch,
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
        if (self.candidate_output) |bytes| @memset(bytes, 0);
        if (self.candidate_provenance) |bytes| @memset(bytes, 0);
        if (self.candidate_result) |bytes| @memset(bytes, 0);
    }

    fn clearPreparedV1(self: *Session) void {
        self.permit = null;
        self.prepared_provenance = null;
        self.prepared_result = null;
        self.prepared_state_after = null;
        self.source_output = &[_]u8{};
        self.candidate_output = null;
        self.candidate_provenance = null;
        self.candidate_result = null;
        self.visible_output = null;
        self.visible_provenance = null;
        self.visible_result = null;
        self.expected_output_sha256 = [_]u8{0} ** 32;
        self.expected_provenance_wire_sha256 = [_]u8{0} ** 32;
        self.expected_result_wire_sha256 = [_]u8{0} ** 32;
        self.expected_state_sha256 = [_]u8{0} ** 32;
    }
};

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

fn slicesOverlap(left: []const u8, right: []const u8) bool {
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
    return left_start < right_end and right_start < left_end;
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn checkedMul(left: u64, right: u64) Error!u64 {
    return std.math.mul(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn checkedSub(left: u64, right: u64) Error!u64 {
    return std.math.sub(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
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
    var storage: [8]u8 = undefined;
    std.mem.writeInt(u64, &storage, value, .little);
    hash.update(&storage);
}

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    inline for (.{
        claim.capsule_bytes,
        claim.kv_bytes,
        claim.activation_bytes,
        claim.partial_bytes,
        claim.logits_bytes,
        claim.output_journal_bytes,
        claim.staging_bytes,
        claim.device_bytes,
        claim.io_bytes,
        claim.queue_slots,
    }) |value|
        hashU64(hash, value);
}

fn isZero(digest: Digest) bool {
    return std.mem.eql(u8, &digest, &([_]u8{0} ** 32));
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn digestFromHex(hex: []const u8) !Digest {
    var digest: Digest = undefined;
    _ = try std.fmt.hexToBytes(&digest, hex);
    return digest;
}

const TestStorage = struct {
    slots: [8]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 8,
    roots: [8]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8,
    nodes: [16]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 16,
};

const TestChunk = struct {
    manifest: GeneratedVideoManifestV1,
    media_object: media.MediaObjectV1,
    output: [8]u8,
};

fn makeTestState() !GeneratedVideoStateV1 {
    return initializeStateV1(
        81_001,
        2,
        2,
        1,
        model.sha256("generated video test artifact"),
        model.sha256("generated video test tenant"),
        model.sha256("generated video test metadata policy"),
        model.sha256("generated video test challenge"),
    );
}

fn makeTestChunk(
    state: GeneratedVideoStateV1,
    source_output: *const [2]u8,
    first_duration_ticks: u64,
    second_duration_ticks: u64,
    source_result_sha256: Digest,
    renderer: RendererV1,
) !TestChunk {
    const output = [8]u8{
        source_output[0],
        source_output[0],
        source_output[0],
        source_output[0],
        source_output[1],
        source_output[1],
        source_output[1],
        source_output[1],
    };
    const first_frame_sha256 = model.sha256(output[0..4]);
    const second_frame_sha256 = model.sha256(output[4..8]);
    const placeholder_media = model.sha256(
        "generated video placeholder media",
    );
    const provisional = try makeManifestV1(
        state,
        first_duration_ticks,
        second_duration_ticks,
        source_output.len,
        output.len,
        renderer.required_capabilities,
        renderer.renderer_abi,
        source_result_sha256,
        model.sha256(source_output),
        model.sha256(reference_renderer_payload),
        renderer.implementation_sha256,
        placeholder_media,
        first_frame_sha256,
        second_frame_sha256,
    );
    const media_object = media.MediaObjectV1{
        .kind = .video,
        .semantic_abi = raw_video_semantic_abi,
        .byte_length = output.len,
        .container_id = raw_container_id,
        .codec_id = gray8_frame_codec_id,
        .axes = .{ 2, 2, 2 },
        .time_base = .{ .numerator = 1, .denominator = 1_000 },
        .tenant_scope_sha256 = state.tenant_scope_sha256,
        .content_sha256 = model.sha256(&output),
        .metadata_policy_sha256 = state.metadata_policy_sha256,
        .provenance_sha256 = sourceProvenanceRootV1(provisional),
    };
    var media_storage: [media.descriptor_bytes]u8 = undefined;
    const media_wire = try media.encodeMediaObjectV1(
        media_object,
        &media_storage,
    );
    const media_root = try media.mediaObjectSha256V1(media_wire);
    const manifest = try makeManifestV1(
        state,
        first_duration_ticks,
        second_duration_ticks,
        source_output.len,
        output.len,
        renderer.required_capabilities,
        renderer.renderer_abi,
        source_result_sha256,
        model.sha256(source_output),
        model.sha256(reference_renderer_payload),
        renderer.implementation_sha256,
        media_root,
        first_frame_sha256,
        second_frame_sha256,
    );
    try std.testing.expectEqual(
        media_object.provenance_sha256,
        sourceProvenanceRootV1(manifest),
    );
    return .{
        .manifest = manifest,
        .media_object = media_object,
        .output = output,
    };
}

fn publishTestChunk(
    bank: *resource_bank.Bank,
    state: *GeneratedVideoStateV1,
    owner_key: u64,
    source_output: *const [2]u8,
    first_duration_ticks: u64,
    second_duration_ticks: u64,
    source_result_sha256: Digest,
    renderer_context: *u8,
) !GeneratedVideoResultV1 {
    const renderer = referenceRendererV1(renderer_context);
    const chunk = try makeTestChunk(
        state.*,
        source_output,
        first_duration_ticks,
        second_duration_ticks,
        source_result_sha256,
        renderer,
    );
    var session: Session = .{};
    try session.initV1(
        bank,
        owner_key,
        state,
        chunk.manifest,
        chunk.media_object,
        reference_renderer_payload,
        renderer,
    );
    var candidate_output: [8]u8 = undefined;
    var candidate_provenance: [provenance_bytes]u8 = undefined;
    var candidate_result: [result_bytes]u8 = undefined;
    var visible_output: [8]u8 = undefined;
    var visible_provenance: [provenance_bytes]u8 = undefined;
    var visible_result: [result_bytes]u8 = undefined;
    _ = try session.prepareV1(
        source_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    const result = try session.commitV1();
    try session.closeAndRelease();
    try std.testing.expectEqual(chunk.output, visible_output);
    try std.testing.expectEqual(
        result,
        try decodeResultV1(&visible_result),
    );
    return result;
}

fn expectStateWireRejected(input: []const u8) !void {
    if (decodeStateV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectManifestWireRejected(input: []const u8) !void {
    if (decodeManifestV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectProvenanceWireRejected(input: []const u8) !void {
    if (decodeProvenanceV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectResultWireRejected(input: []const u8) !void {
    if (decodeResultV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectObservationWireRejected(input: []const u8) !void {
    if (decodeDisplayObservationV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectAckPlanWireRejected(input: []const u8) !void {
    if (decodeDisplayAckPlanV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectAckResultWireRejected(input: []const u8) !void {
    if (decodeDisplayAckResultV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "generated video wires are canonical and mutation complete" {
    var storage: TestStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        82_001,
    );
    var renderer_context: u8 = 1;
    const renderer = referenceRendererV1(&renderer_context);
    var state = try makeTestState();
    const initial_state = state;
    const source_output = [_]u8{ 3, 7 };
    const chunk = try makeTestChunk(
        state,
        &source_output,
        2,
        3,
        model.sha256("generated video source result zero"),
        renderer,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        83_001,
        &state,
        chunk.manifest,
        chunk.media_object,
        reference_renderer_payload,
        renderer,
    );
    var candidate_output: [8]u8 = undefined;
    var candidate_provenance: [provenance_bytes]u8 = undefined;
    var candidate_result: [result_bytes]u8 = undefined;
    var visible_output: [8]u8 = undefined;
    var visible_provenance: [provenance_bytes]u8 = undefined;
    var visible_result: [result_bytes]u8 = undefined;
    _ = try session.prepareV1(
        &source_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    const publication_result = try session.commitV1();
    try session.closeAndRelease();
    const provenance = try decodeProvenanceV1(&visible_provenance);
    try validateProvenanceBindingV1(chunk.manifest, provenance);
    try validateResultBindingV1(
        chunk.manifest,
        provenance,
        publication_result,
    );
    const observation = try makeDisplayObservationV1(
        state,
        model.sha256("test display sink implementation"),
        model.sha256("test display sink instance"),
    );
    const ack_plan = try makeDisplayAckPlanV1(
        state,
        publication_result,
        observation,
    );
    const ack_result = try makeDisplayAckResultV1(
        state,
        publication_result,
        observation,
        ack_plan,
    );

    var state_storage: [state_bytes]u8 = undefined;
    _ = try encodeStateV1(initial_state, &state_storage);
    try std.testing.expectEqual(
        initial_state,
        try decodeStateV1(&state_storage),
    );
    for (0..state_storage.len) |index| {
        var mutated = state_storage;
        mutated[index] ^= 1;
        try expectStateWireRejected(&mutated);
    }
    var manifest_storage: [manifest_bytes]u8 = undefined;
    _ = try encodeManifestV1(chunk.manifest, &manifest_storage);
    for (0..manifest_storage.len) |index| {
        var mutated = manifest_storage;
        mutated[index] ^= 1;
        try expectManifestWireRejected(&mutated);
    }
    for (0..visible_provenance.len) |index| {
        var mutated = visible_provenance;
        mutated[index] ^= 1;
        try expectProvenanceWireRejected(&mutated);
    }
    for (0..visible_result.len) |index| {
        var mutated = visible_result;
        mutated[index] ^= 1;
        try expectResultWireRejected(&mutated);
    }
    var observation_storage: [observation_bytes]u8 = undefined;
    _ = try encodeDisplayObservationV1(
        observation,
        &observation_storage,
    );
    for (0..observation_storage.len) |index| {
        var mutated = observation_storage;
        mutated[index] ^= 1;
        try expectObservationWireRejected(&mutated);
    }
    var ack_plan_storage: [ack_plan_bytes]u8 = undefined;
    _ = try encodeDisplayAckPlanV1(ack_plan, &ack_plan_storage);
    for (0..ack_plan_storage.len) |index| {
        var mutated = ack_plan_storage;
        mutated[index] ^= 1;
        try expectAckPlanWireRejected(&mutated);
    }
    var ack_result_storage: [ack_result_bytes]u8 = undefined;
    _ = try encodeDisplayAckResultV1(
        ack_result,
        &ack_result_storage,
    );
    for (0..ack_result_storage.len) |index| {
        var mutated = ack_result_storage;
        mutated[index] ^= 1;
        try expectAckResultWireRejected(&mutated);
    }
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}

test "display acknowledgement gates each generated video segment" {
    var storage: TestStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        84_001,
    );
    var renderer_context: u8 = 1;
    var state = try makeTestState();
    const first_source = [_]u8{ 3, 7 };
    const first_result = try publishTestChunk(
        &bank,
        &state,
        85_001,
        &first_source,
        2,
        3,
        model.sha256("generated video source result zero"),
        &renderer_context,
    );
    try std.testing.expectEqual(@as(u64, 1), state.pending);
    try std.testing.expectEqual(@as(u64, 1), state.visible_segments);
    try std.testing.expectEqual(@as(u64, 2), state.visible_frames);
    try std.testing.expectEqual(@as(u64, 5), state.visible_end_tick);
    try std.testing.expectError(
        Error.DisplayPending,
        makeManifestV1(
            state,
            4,
            1,
            2,
            8,
            0,
            reference_renderer_abi,
            model.sha256("blocked source result"),
            model.sha256("blocked source output"),
            model.sha256(reference_renderer_payload),
            referenceRendererImplementationSha256V1(),
            model.sha256("blocked media"),
            model.sha256("blocked frame zero"),
            model.sha256("blocked frame one"),
        ),
    );
    const sink_implementation =
        model.sha256("test display sink implementation");
    const sink_instance =
        model.sha256("test display sink instance");
    const first_observation = try makeDisplayObservationV1(
        state,
        sink_implementation,
        sink_instance,
    );
    var partial = first_observation;
    partial.consumed_frames -= 1;
    partial.observation_sha256 = observationRootV1(partial);
    try std.testing.expectError(
        Error.InvalidObservation,
        makeDisplayAckPlanV1(state, first_result, partial),
    );
    var impossible_observation = first_observation;
    impossible_observation.display_sequence += 1;
    impossible_observation.observation_sha256 =
        observationRootV1(impossible_observation);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateDisplayObservationV1(impossible_observation),
    );
    const first_ack_plan = try makeDisplayAckPlanV1(
        state,
        first_result,
        first_observation,
    );
    _ = try acknowledgeDisplayV1(
        &state,
        first_result,
        first_observation,
        first_ack_plan,
    );
    try std.testing.expectEqual(@as(u64, 0), state.pending);
    try std.testing.expectEqual(@as(u64, 1), state.displayed_segments);
    try std.testing.expectEqual(@as(u64, 2), state.displayed_frames);
    try std.testing.expectEqual(@as(u64, 5), state.displayed_end_tick);

    const second_source = [_]u8{ 11, 13 };
    const second_result = try publishTestChunk(
        &bank,
        &state,
        85_002,
        &second_source,
        4,
        1,
        first_result.result_sha256,
        &renderer_context,
    );
    const second_observation = try makeDisplayObservationV1(
        state,
        sink_implementation,
        sink_instance,
    );
    const second_ack_plan = try makeDisplayAckPlanV1(
        state,
        second_result,
        second_observation,
    );
    _ = try acknowledgeDisplayV1(
        &state,
        second_result,
        second_observation,
        second_ack_plan,
    );
    try std.testing.expectEqual(@as(u64, 4), state.generation);
    try std.testing.expectEqual(@as(u64, 2), state.visible_segments);
    try std.testing.expectEqual(@as(u64, 4), state.visible_frames);
    try std.testing.expectEqual(@as(u64, 10), state.visible_end_tick);
    try std.testing.expectEqual(@as(u64, 2), state.displayed_segments);
    try std.testing.expectEqual(@as(u64, 4), state.displayed_frames);
    try std.testing.expectEqual(@as(u64, 10), state.displayed_end_tick);
    try std.testing.expectError(
        Error.NoDisplayPending,
        acknowledgeDisplayV1(
            &state,
            second_result,
            second_observation,
            second_ack_plan,
        ),
    );
    const final = try bank.snapshotV3();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(@as(u64, 0), final.live_allocations);
    try std.testing.expectEqual(@as(u64, 0), final.active_lease_trees);
}

test "generated video abort and candidate drift preserve visibility" {
    var storage: TestStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        86_001,
    );
    var renderer_context: u8 = 1;
    const renderer = referenceRendererV1(&renderer_context);
    var state = try makeTestState();
    const state_before = state;
    const source_output = [_]u8{ 3, 7 };
    const chunk = try makeTestChunk(
        state,
        &source_output,
        2,
        3,
        model.sha256("generated video source result zero"),
        renderer,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        87_001,
        &state,
        chunk.manifest,
        chunk.media_object,
        reference_renderer_payload,
        renderer,
    );
    var candidate_output: [8]u8 = undefined;
    var candidate_provenance: [provenance_bytes]u8 = undefined;
    var candidate_result: [result_bytes]u8 = undefined;
    var visible_output = [_]u8{0xa5} ** 8;
    var visible_provenance = [_]u8{0xa5} ** provenance_bytes;
    var visible_result = [_]u8{0xa5} ** result_bytes;
    _ = try session.prepareV1(
        &source_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    try session.abortV1();
    try std.testing.expectEqual(state_before, state);
    try std.testing.expectEqual(
        [_]u8{0} ** 8,
        candidate_output,
    );
    try std.testing.expectEqual(
        [_]u8{0xa5} ** 8,
        visible_output,
    );
    _ = try session.prepareV1(
        &source_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    candidate_output[0] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expectEqual(state_before, state);
    try std.testing.expectEqual(
        [_]u8{0} ** 8,
        candidate_output,
    );
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}

test "rehashed generated video lineage substitution fails closed" {
    var renderer_context: u8 = 1;
    const renderer = referenceRendererV1(&renderer_context);
    const state = try makeTestState();
    const source_output = [_]u8{ 3, 7 };
    const chunk = try makeTestChunk(
        state,
        &source_output,
        2,
        3,
        model.sha256("generated video source result zero"),
        renderer,
    );
    var impossible_state = state;
    impossible_state.generation += 1;
    impossible_state.state_sha256 = stateRootV1(impossible_state);
    try std.testing.expectError(
        Error.InvalidState,
        validateStateV1(impossible_state),
    );
    var impossible_manifest = chunk.manifest;
    impossible_manifest.generation += 2;
    impossible_manifest.manifest_sha256 =
        manifestRootV1(impossible_manifest);
    try std.testing.expectError(
        Error.InvalidManifest,
        validateManifestV1(impossible_manifest),
    );
    const provenance = try makeProvenanceV1(
        chunk.manifest,
        model.sha256(&chunk.output),
    );
    var rebound = provenance;
    rebound.source_output_bytes += 1;
    rebound.provenance_sha256 = provenanceRootV1(rebound);
    try std.testing.expectError(
        Error.InvalidBinding,
        validateProvenanceBindingV1(chunk.manifest, rebound),
    );
    var foreign_manifest = chunk.manifest;
    foreign_manifest.first_duration_ticks += 1;
    foreign_manifest.end_tick += 1;
    foreign_manifest.visible_end_tick_after += 1;
    foreign_manifest.manifest_sha256 =
        manifestRootV1(foreign_manifest);
    try validateManifestV1(foreign_manifest);
    try std.testing.expectError(
        Error.InvalidMedia,
        validatePublicationBindingsV1(
            foreign_manifest,
            state,
            chunk.media_object,
            reference_renderer_payload,
            renderer,
        ),
    );
    const resource_claim = try claimForManifestV1(
        chunk.manifest,
        reference_renderer_payload.len,
    );
    var malformed_result = try makeResultV1(
        chunk.manifest,
        provenance,
        .{
            .bank_epoch = 1,
            .slot_index = 0,
            .generation = 1,
            .owner_key = 1,
            .claim = resource_claim,
            .integrity = 1,
        },
    );
    malformed_result.total_output_bytes += 1;
    malformed_result.result_sha256 = resultRootV1(malformed_result);
    try std.testing.expectError(
        Error.InvalidResult,
        validateResultV1(malformed_result),
    );
}

test "generated video roots match the independent reference chain" {
    var storage: TestStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        94_001,
    );
    var renderer_context: u8 = 1;
    const renderer = referenceRendererV1(&renderer_context);
    var state = try makeTestState();
    const state0 = state;
    const first_source = [_]u8{ 3, 7 };
    const first_chunk = try makeTestChunk(
        state,
        &first_source,
        2,
        3,
        model.sha256("generated video source result zero"),
        renderer,
    );
    const first_provenance = try makeProvenanceV1(
        first_chunk.manifest,
        model.sha256(&first_chunk.output),
    );
    const first_result = try publishTestChunk(
        &bank,
        &state,
        95_001,
        &first_source,
        2,
        3,
        model.sha256("generated video source result zero"),
        &renderer_context,
    );
    const sink_implementation =
        model.sha256("test display sink implementation");
    const sink_instance =
        model.sha256("test display sink instance");
    const first_observation = try makeDisplayObservationV1(
        state,
        sink_implementation,
        sink_instance,
    );
    const first_ack_plan = try makeDisplayAckPlanV1(
        state,
        first_result,
        first_observation,
    );
    const first_ack = try acknowledgeDisplayV1(
        &state,
        first_result,
        first_observation,
        first_ack_plan,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "5a2fa2c3417d77dd46aae71913db4bd1abad51d28a8e2ae4061589d432fc0a1d",
        ),
        state0.state_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "918566635a8f91d7e589aaedadefd96b97b2e32f376e7d6205ba9bff6818234f",
        ),
        first_chunk.manifest.manifest_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "3676e6357a628f1716b291b9d7296a00a3ba48039655d91146db58c156421b70",
        ),
        first_provenance.provenance_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "60105ba224ed598e52dad97f4d4dc29500ce8eaf33288190cef63a3b560c0cba",
        ),
        first_result.result_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "952814aa06bee9a61fc98316949e8aa7e10762bc3a486608df2ef6c9126e5b5f",
        ),
        first_observation.observation_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "fc945471d54fd5907a84dc3fe1e72804399e7e0ec53b3218602bf8fd92e0c53f",
        ),
        first_ack_plan.plan_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "53e78f9aea3ee263013fbf2700ceaffc4860a6aac7883090e6b05db587b41650",
        ),
        first_ack.result_sha256,
    );

    const second_source = [_]u8{ 11, 13 };
    const second_result = try publishTestChunk(
        &bank,
        &state,
        95_002,
        &second_source,
        4,
        1,
        first_result.result_sha256,
        &renderer_context,
    );
    const second_observation = try makeDisplayObservationV1(
        state,
        sink_implementation,
        sink_instance,
    );
    const second_ack_plan = try makeDisplayAckPlanV1(
        state,
        second_result,
        second_observation,
    );
    _ = try acknowledgeDisplayV1(
        &state,
        second_result,
        second_observation,
        second_ack_plan,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "ca533126a1234276aa97d2748f488567e96823534f509b5e2958a76a78f23d12",
        ),
        state.state_sha256,
    );
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}
