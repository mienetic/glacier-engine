//! Bounded reference composition for typed perception workloads.
//!
//! This layer joins the portable typed-workload plan and lifecycle driver to
//! the retained exact-integer vision, audio-window, and temporal-video
//! adapters. Every admitted item adopts the scheduler's existing receipt.
//! Model execution is deferred until the final service quantum, where
//! scheduler service and result publication commit atomically. Cache restore
//! ownership remains isolated in one address-stable Bank per item.
//!
//! Evidence in this file is semantic sidecar evidence only. It intentionally
//! defines no binary wire format or JSON representation.

const std = @import("std");
const contract = @import("typed_workload_contract.zig");
const driver = @import("typed_workload_driver.zig");
const model = @import("model_contract.zig");
const processor = @import("media_processor_state.zig");
const processor_cache = @import("media_processor_cache.zig");
const resource_bank = @import("resource_bank.zig");
const qos = @import("lane_weave_qos.zig");
const vision = @import("vision_encoder_adapter.zig");
const audio = @import("audio_window_adapter.zig");
const video = @import("temporal_video_adapter.zig");

pub const Digest = contract.Digest;
pub const zero_digest = contract.zero_digest;

pub const evidence_abi: u64 = 0x4754_5057_4500_0001;
pub const item_evidence_abi: u64 = 0x4754_5057_4900_0001;
pub const summary_abi: u64 = 0x4754_5057_5300_0001;

pub const reference_profile_count: usize = 3;
pub const reference_item_count: usize = 6;
pub const reference_capacity: u32 = 3;
pub const output_bytes: usize = 16;

const item_evidence_domain =
    "glacier-typed-perception-item-evidence-v1\x00";
const item_section_domain =
    "glacier-typed-perception-item-section-v1\x00";
const summary_domain =
    "glacier-typed-perception-summary-v1\x00";
const evidence_domain =
    "glacier-typed-perception-evidence-v1\x00";

pub const Error = driver.Error || vision.Error || audio.Error ||
    video.Error || processor_cache.Error || resource_bank.Error ||
    model.Error || error{
    InjectedFailure,
    InvalidExecution,
    InvalidEvidence,
};

pub const PerceptionFamilyV1 = enum(u64) {
    vision = 1,
    audio_window = 2,
    temporal_video = 3,
};

pub const FailureInjectionV1 = enum {
    none,
    after_prepare,
    candidate_drift,
    after_arm,
};

pub const ItemEvidenceV1 = struct {
    ordinal: u64,
    family: PerceptionFamilyV1,
    profile_index: u64,
    outcome: driver.OutcomeKindV1,
    terminal_action: contract.TerminalActionV1,
    profile_sha256: Digest,
    item_sha256: Digest,
    artifact_sha256: Digest,
    execution_plan_sha256: Digest,
    execution_plan: model.ExecutionPlanV1,
    adapter_implementation_sha256: Digest,
    adapter_sha256: Digest = zero_digest,
    source_mapping_sha256: Digest = zero_digest,
    resource_receipt_sha256: Digest = zero_digest,
    resource_bank_epoch: u64 = 0,
    resource_slot_index: u64 = 0,
    resource_generation: u64 = 0,
    resource_owner_key: u64 = 0,
    resource_claim: resource_bank.Claim = .{},
    resource_integrity: u64 = 0,
    final_service_event_sha256: Digest = zero_digest,
    result_envelope_sha256: Digest = zero_digest,
    result_envelope: ?model.ResultEnvelopeV1 = null,
    output_sha256: Digest = zero_digest,
    publication_state_before_sha256: Digest,
    publication_state_after_sha256: Digest,
    admission_trace_sha256: Digest,
    terminal_trace_sha256: Digest,
    driver_outcome_sha256: Digest,
    record_sha256: Digest = zero_digest,
};

pub const SummaryV1 = struct {
    profile_count: u64,
    item_count: u64,
    admitted: u64,
    rejected: u64,
    completed: u64,
    cancelled: u64,
    timed_out: u64,
    vision_completed: u64,
    audio_window_completed: u64,
    temporal_video_completed: u64,
    publications: u64,
    nonpublished_terminal_items: u64,
    cache_restores: u64,
    cache_closures: u64,
    cache_successful_commits: u64,
    cache_releases: u64,
    cache_live_allocations: u64,
    model_successful_commits: u64,
    model_releases: u64,
    model_final_active_reservations: u64,
    model_final_committed_receipts: u64,
    zero_model_ownership: bool,
    zero_cache_ownership: bool,
    zero_orphan_ownership: bool,
    summary_sha256: Digest = zero_digest,
};

pub const EvidenceV1 = struct {
    plan_sha256: Digest,
    driver_result_sha256: Digest,
    driver_outcome_sha256: Digest,
    driver_trace_sha256: Digest,
    driver_summary_sha256: Digest,
    item_section_sha256: Digest,
    evidence_summary_sha256: Digest,
    items: []const ItemEvidenceV1,
    summary: SummaryV1,
    evidence_sha256: Digest,
};

pub const CampaignV1 = struct {
    plan: contract.PlanV1,
    driver_result: driver.ResultV1,
    evidence: EvidenceV1,
};

/// Retained even when a run fails so tests and embedders can audit rollback.
pub const CleanupReportV1 = struct {
    invoked: bool = false,
    sessions_closed: u64 = 0,
    caches_closed: u64 = 0,
    candidates_zero: bool = false,
    outputs_zero: bool = false,
    model_used_zero: bool = false,
    model_active_reservations: u64 = 0,
    model_committed_receipts: u64 = 0,
    cache_used_zero: bool = false,
    cache_live_allocations: u64 = 0,
};

const CacheRuntimeV1 = struct {
    slots: [8]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 8,
    roots: [8]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8,
    nodes: [12]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 12,
    bank: resource_bank.Bank = undefined,
    session: processor_cache.RestoreSession = .{},
    started: bool = false,
    restored: bool = false,
    closed: bool = false,
    final_snapshot: resource_bank.SnapshotV3 = undefined,

    fn restore(
        self: *CacheRuntimeV1,
        bundle: processor_cache.DecodedBundleV1,
        payloads: [3][]const u8,
    ) Error!void {
        if (self.started or self.restored or self.closed)
            return Error.InvalidExecution;
        self.bank = try resource_bank.Bank.initWithLeaseTreeStorage(
            &self.slots,
            &self.roots,
            &self.nodes,
            .{},
            bundle.restore_bank_epoch,
        );
        try self.session.prepareV1(
            &self.bank,
            bundle,
            bundle.bundle_sha256,
        );
        self.started = true;
        try self.session.commitMaterializedV1(payloads);
        self.restored = true;
    }

    fn close(self: *CacheRuntimeV1) Error!void {
        if (self.closed) return;
        if (!self.started) return Error.InvalidExecution;
        try self.session.closeAndRelease();
        self.final_snapshot = try self.bank.snapshotV3();
        self.closed = true;
        if (!cacheSnapshotHasZeroAuthorityV1(self.final_snapshot))
            return Error.InvalidExecution;
    }
};

const VisionRuntimeV1 = struct {
    fixture: vision.ReferenceFixtureV1,
    cache: CacheRuntimeV1 = .{},
    session: vision.Session = .{},
    adapter_context: u8 = 1,
    candidate: [output_bytes]u8 = [_]u8{0} ** output_bytes,
    output: [output_bytes]u8 = [_]u8{0} ** output_bytes,

    fn init() Error!VisionRuntimeV1 {
        return .{ .fixture = try vision.ReferenceFixtureV1.init() };
    }
};

const AudioRuntimeV1 = struct {
    fixture: audio.ReferenceFixtureV1,
    cache: CacheRuntimeV1 = .{},
    session: audio.Session = .{},
    adapter_context: u8 = 1,
    candidate: [output_bytes]u8 = [_]u8{0} ** output_bytes,
    output: [output_bytes]u8 = [_]u8{0} ** output_bytes,

    fn init() Error!AudioRuntimeV1 {
        return .{ .fixture = try audio.ReferenceFixtureV1.init() };
    }
};

const VideoRuntimeV1 = struct {
    fixture: video.ReferenceFixtureV1,
    cache: CacheRuntimeV1 = .{},
    session: video.Session = .{},
    adapter_context: u8 = 1,
    selected_input: [4]u8 = [_]u8{0} ** 4,
    candidate: [output_bytes]u8 = [_]u8{0} ** output_bytes,
    output: [output_bytes]u8 = [_]u8{0} ** output_bytes,

    fn init() Error!VideoRuntimeV1 {
        return .{ .fixture = try video.ReferenceFixtureV1.init() };
    }
};

const RuntimeV1 = union(PerceptionFamilyV1) {
    vision: VisionRuntimeV1,
    audio_window: AudioRuntimeV1,
    temporal_video: VideoRuntimeV1,
};

const ItemStateV1 = struct {
    admitted: bool = false,
    executed: bool = false,
    session_closed: bool = false,
    receipt: resource_bank.Receipt = undefined,
    resource_receipt_sha256: Digest = zero_digest,
    publication_before_sha256: Digest = zero_digest,
    publication_after_sha256: Digest = zero_digest,
    final_service_event: qos.EventV1 = undefined,
    result: ?model.ResultEnvelopeV1 = null,
};

pub const ReferenceStorageV1 = struct {
    driver_storage: driver.MaximumStorageV1 = .{},
    replay_storage: driver.MaximumStorageV1 = .{},
    profiles: [reference_profile_count]contract.ProfileV1 = undefined,
    items: [reference_item_count]contract.ItemV1 = undefined,
    runtimes: [reference_item_count]RuntimeV1 = undefined,
    states: [reference_item_count]ItemStateV1 =
        [_]ItemStateV1{.{}} ** reference_item_count,
    item_evidence: [reference_item_count]ItemEvidenceV1 = undefined,
    cleanup_report: CleanupReportV1 = .{},
    prepared: bool = false,
    prepared_address: usize = 0,

    /// Returned storage contains no internal pointers yet. `prepareV1` is
    /// deliberately separate and must run after the value reaches its final
    /// address.
    pub fn init() Error!ReferenceStorageV1 {
        var self: ReferenceStorageV1 = undefined;
        self.driver_storage = .{};
        self.replay_storage = .{};
        self.profiles = undefined;
        self.items = undefined;
        self.states = [_]ItemStateV1{.{}} ** reference_item_count;
        self.item_evidence = undefined;
        self.cleanup_report = .{};
        self.prepared = false;
        self.prepared_address = 0;
        self.runtimes[0] = .{ .vision = try VisionRuntimeV1.init() };
        self.runtimes[1] = .{ .audio_window = try AudioRuntimeV1.init() };
        self.runtimes[2] = .{
            .temporal_video = try VideoRuntimeV1.init(),
        };
        self.runtimes[3] = .{
            .temporal_video = try VideoRuntimeV1.init(),
        };
        self.runtimes[4] = .{ .vision = try VisionRuntimeV1.init() };
        self.runtimes[5] = .{ .audio_window = try AudioRuntimeV1.init() };
        return self;
    }

    pub fn prepareV1(self: *ReferenceStorageV1) Error!void {
        if (self.prepared) return Error.InvalidExecution;
        for (&self.runtimes) |*runtime| {
            try rebindRuntimeV1(runtime);
        }
        self.profiles = try makeReferenceProfilesV1(self);
        self.items = try makeReferenceItemsV1(self, &self.profiles);
        try contract.validatePlanV1(self.planV1());
        for (&self.runtimes, &self.states) |*runtime, *state| {
            state.publication_before_sha256 =
                try publicationRootV1(runtime);
            state.publication_after_sha256 =
                state.publication_before_sha256;
        }
        self.prepared = true;
        self.prepared_address = @intFromPtr(self);
        try validateReferenceSealV1(self);
    }

    pub fn planV1(self: *const ReferenceStorageV1) contract.PlanV1 {
        return referencePlanV1(&self.profiles, &self.items);
    }

    fn closeCachesBestEffort(self: *ReferenceStorageV1) void {
        for (&self.runtimes) |*runtime| {
            const cache = cacheForRuntimeV1(runtime);
            if (cache.started and !cache.closed) cache.close() catch {};
        }
    }
};

pub fn makeProfileV1(
    index: usize,
    support: model.SupportRecordV1,
    manifest: model.ArtifactManifestV1,
    execution_plan: model.ExecutionPlanV1,
    adapter_abi: u64,
    adapter_implementation_sha256: Digest,
    correctness_sha256: Digest,
) contract.ProfileV1 {
    var profile: contract.ProfileV1 = .{
        .index = @intCast(index),
        .family = execution_plan.family,
        .operation = execution_plan.operation,
        .input_kind = execution_plan.input_kind,
        .output_kind = execution_plan.output_kind,
        .numerical_policy = execution_plan.numerical_policy,
        .adapter_abi = adapter_abi,
        .lifecycle = .stateless,
        .execution_unit = .operation,
        .cancellation_boundary = .between_units,
        .publication_policy = .final_only,
        .correctness_gate = .exact,
        .claim = execution_plan.claim,
        .support_sha256 = contract.supportRecordSha256V1(support),
        .artifact_sha256 = manifest.artifact_sha256,
        .execution_plan_sha256 = execution_plan.plan_sha256,
        .adapter_implementation_sha256 = adapter_implementation_sha256,
        .correctness_sha256 = correctness_sha256,
        .profile_sha256 = zero_digest,
    };
    profile.profile_sha256 = contract.profileSha256V1(profile);
    return profile;
}

pub fn makeItemV1(
    ordinal: usize,
    profile: contract.ProfileV1,
    arrival_step: u64,
    work_quanta: u64,
    terminal_action_step: u64,
    terminal_action: contract.TerminalActionV1,
    input_binding_sha256: Digest,
) contract.ItemV1 {
    const identity: u64 = @intCast(ordinal + 1);
    var item: contract.ItemV1 = .{
        .ordinal = @intCast(ordinal),
        .profile_index = profile.index,
        .profile_sha256 = profile.profile_sha256,
        .arrival_step = arrival_step,
        .weight = 1,
        .work_quanta = work_quanta,
        .deadline_tick = 0,
        .terminal_action_step = terminal_action_step,
        .terminal_action = terminal_action,
        .fairness_member = true,
        .tenant_key = 0x7100 + identity,
        .request_key = 0x7200 + identity,
        .request_generation = 1,
        .resource_owner_key = 0x7300 + identity,
        .claim = profile.claim,
        .input_binding_sha256 = input_binding_sha256,
        .item_sha256 = zero_digest,
    };
    item.item_sha256 = contract.itemSha256V1(item);
    return item;
}

pub fn makeReferenceProfilesV1(
    storage: *const ReferenceStorageV1,
) Error![reference_profile_count]contract.ProfileV1 {
    const vision_runtime = &storage.runtimes[0].vision;
    const audio_runtime = &storage.runtimes[1].audio_window;
    const video_runtime = &storage.runtimes[2].temporal_video;
    return .{
        makeProfileV1(
            0,
            vision.vision_support[0],
            vision_runtime.fixture.manifest,
            vision_runtime.fixture.plan,
            vision.reference_adapter_abi,
            implementationRootV1(.vision),
            expectedOutputSha256V1(.vision),
        ),
        makeProfileV1(
            1,
            audio.audio_support[0],
            audio_runtime.fixture.manifest,
            audio_runtime.fixture.plan,
            audio.reference_adapter_abi,
            implementationRootV1(.audio_window),
            expectedOutputSha256V1(.audio_window),
        ),
        makeProfileV1(
            2,
            video.video_support[0],
            video_runtime.fixture.manifest,
            video_runtime.fixture.plan,
            video.reference_adapter_abi,
            implementationRootV1(.temporal_video),
            expectedOutputSha256V1(.temporal_video),
        ),
    };
}

pub fn makeReferenceItemsV1(
    storage: *const ReferenceStorageV1,
    profiles: *const [reference_profile_count]contract.ProfileV1,
) Error![reference_item_count]contract.ItemV1 {
    const vision_runtime = &storage.runtimes[0].vision;
    const audio_runtime = &storage.runtimes[1].audio_window;
    const video_runtime = &storage.runtimes[2].temporal_video;
    const vision_input = try vision.sourceMappingRootV1(
        vision_runtime.fixture.plan,
        vision_runtime.fixture.processor_bundle.states[0],
    );
    const audio_input = try audio.sourceMappingRootV1(
        audio_runtime.fixture.plan,
        audio_runtime.fixture.processor_bundle.states[1],
    );
    const video_input = try video.sourceMappingRootV1(
        video_runtime.fixture.plan,
        video_runtime.fixture.processor_bundle.states[2],
        video_runtime.fixture.selection,
    );
    return makeReferenceItemsFromRootsV1(
        profiles,
        .{ vision_input, audio_input, video_input },
    );
}

fn makeReferenceItemsFromRootsV1(
    profiles: *const [reference_profile_count]contract.ProfileV1,
    input_roots: [reference_profile_count]Digest,
) [reference_item_count]contract.ItemV1 {
    return .{
        makeItemV1(
            0,
            profiles[0],
            0,
            8,
            1,
            .cancel,
            input_roots[0],
        ),
        makeItemV1(
            1,
            profiles[1],
            0,
            8,
            2,
            .timeout,
            input_roots[1],
        ),
        makeItemV1(
            2,
            profiles[2],
            0,
            1,
            contract.absent,
            .none,
            input_roots[2],
        ),
        makeItemV1(
            3,
            profiles[2],
            1,
            1,
            contract.absent,
            .none,
            input_roots[2],
        ),
        makeItemV1(
            4,
            profiles[0],
            2,
            1,
            contract.absent,
            .none,
            input_roots[0],
        ),
        makeItemV1(
            5,
            profiles[1],
            3,
            1,
            contract.absent,
            .none,
            input_roots[1],
        ),
    };
}

fn rebindRuntimeV1(runtime: *RuntimeV1) Error!void {
    switch (runtime.*) {
        .vision => |*value| try value.fixture.rebind(),
        .audio_window => |*value| try value.fixture.rebind(),
        .temporal_video => |*value| try value.fixture.rebind(),
    }
}

fn restoreRuntimeCacheV1(runtime: *RuntimeV1) Error!void {
    switch (runtime.*) {
        .vision => |*value| try value.cache.restore(
            value.fixture.cache_bundle,
            .{
                &value.fixture.image_features,
                &value.fixture.audio_features,
                &value.fixture.video_features,
            },
        ),
        .audio_window => |*value| try value.cache.restore(
            value.fixture.cache_bundle,
            .{
                &value.fixture.image_cache,
                &value.fixture.audio_features,
                &value.fixture.video_cache,
            },
        ),
        .temporal_video => |*value| try value.cache.restore(
            value.fixture.cache_bundle,
            .{
                &value.fixture.image_cache,
                &value.fixture.audio_cache,
                &value.fixture.video_cache,
            },
        ),
    }
}

fn cacheForRuntimeV1(runtime: *RuntimeV1) *CacheRuntimeV1 {
    return switch (runtime.*) {
        .vision => |*value| &value.cache,
        .audio_window => |*value| &value.cache,
        .temporal_video => |*value| &value.cache,
    };
}

fn familyForRuntimeV1(runtime: *const RuntimeV1) PerceptionFamilyV1 {
    return std.meta.activeTag(runtime.*);
}

fn publicationRootV1(runtime: *const RuntimeV1) Error!Digest {
    return switch (runtime.*) {
        .vision => |value| model.publicationStateRootV1(
            value.fixture.publication_state,
        ),
        .audio_window => |value| model.publicationStateRootV1(
            value.fixture.publication_state,
        ),
        .temporal_video => |value| model.publicationStateRootV1(
            value.fixture.publication_state,
        ),
    };
}

fn executionPlanForRuntimeV1(
    runtime: *const RuntimeV1,
) model.ExecutionPlanV1 {
    return switch (runtime.*) {
        .vision => |value| value.fixture.plan,
        .audio_window => |value| value.fixture.plan,
        .temporal_video => |value| value.fixture.plan,
    };
}

fn outputForRuntimeV1(runtime: *const RuntimeV1) []const u8 {
    return switch (runtime.*) {
        .vision => |*value| &value.output,
        .audio_window => |*value| &value.output,
        .temporal_video => |*value| &value.output,
    };
}

fn candidateForRuntimeV1(runtime: *RuntimeV1) []u8 {
    return switch (runtime.*) {
        .vision => |*value| &value.candidate,
        .audio_window => |*value| &value.candidate,
        .temporal_video => |*value| &value.candidate,
    };
}

fn runtimeBuffersZeroV1(runtime: *const RuntimeV1) bool {
    const candidate_zero = switch (runtime.*) {
        .vision => |value| std.mem.allEqual(u8, &value.candidate, 0),
        .audio_window => |value| std.mem.allEqual(
            u8,
            &value.candidate,
            0,
        ),
        .temporal_video => |value| std.mem.allEqual(
            u8,
            &value.candidate,
            0,
        ) and std.mem.allEqual(u8, &value.selected_input, 0),
    };
    return candidate_zero;
}

fn runtimeOutputZeroV1(runtime: *const RuntimeV1) bool {
    return std.mem.allEqual(u8, outputForRuntimeV1(runtime), 0);
}

fn initializeScheduledRuntimeV1(
    runtime: *RuntimeV1,
    scheduler: *driver.SchedulerV1,
    admission: driver.SchedulerAdmissionV1,
) Error!void {
    switch (runtime.*) {
        .vision => |*value| {
            const descriptor = try vision.makeAdapterDescriptorV1(
                vision.reference_adapter_abi,
                value.fixture.manifest,
                implementationRootV1(.vision),
            );
            const adapter: vision.AdapterV1 = .{
                .context = &value.adapter_context,
                .descriptor = descriptor,
                .execute_fn = vision.referenceExecuteV1,
                .validate_candidate_fn = vision.validateCandidateV1,
            };
            try value.session.initScheduledV1(
                scheduler,
                admission,
                &value.fixture.publication_state,
                value.fixture.manifest,
                value.fixture.plan,
                adapter,
            );
        },
        .audio_window => |*value| {
            const descriptor = try audio.makeAdapterDescriptorV1(
                value.fixture.manifest,
                implementationRootV1(.audio_window),
            );
            const adapter: audio.AdapterV1 = .{
                .context = &value.adapter_context,
                .descriptor = descriptor,
                .execute_fn = audio.referenceExecuteV1,
                .validate_candidate_fn = audio.validateCandidateV1,
            };
            try value.session.initScheduledV1(
                scheduler,
                admission,
                &value.fixture.publication_state,
                value.fixture.manifest,
                value.fixture.plan,
                adapter,
            );
        },
        .temporal_video => |*value| {
            const descriptor = try video.makeAdapterDescriptorV1(
                value.fixture.manifest,
                implementationRootV1(.temporal_video),
            );
            const adapter: video.AdapterV1 = .{
                .context = &value.adapter_context,
                .descriptor = descriptor,
                .execute_fn = video.referenceExecuteV1,
                .validate_candidate_fn = video.validateCandidateV1,
            };
            try value.session.initScheduledV1(
                scheduler,
                admission,
                &value.fixture.publication_state,
                value.fixture.manifest,
                value.fixture.plan,
                adapter,
            );
        },
    }
}

fn prepareRuntimeV1(
    runtime: *RuntimeV1,
) Error!model.ResultEnvelopeV1 {
    return switch (runtime.*) {
        .vision => |*value| value.session.prepareV1(
            &value.fixture.processor_bundle,
            &value.fixture.cache_bundle,
            &value.cache.session,
            &value.fixture.weights,
            &value.fixture.image_features,
            &value.candidate,
            &value.output,
        ),
        .audio_window => |*value| value.session.prepareV1(
            &value.fixture.processor_bundle,
            &value.fixture.cache_bundle,
            &value.cache.session,
            &value.fixture.weights,
            &value.fixture.audio_features,
            &value.candidate,
            &value.output,
        ),
        .temporal_video => |*value| value.session.prepareV1(
            &value.fixture.processor_bundle,
            &value.fixture.cache_bundle,
            &value.cache.session,
            value.fixture.selection,
            &value.fixture.weights,
            &value.fixture.video_cache,
            &value.selected_input,
            &value.candidate,
            &value.output,
        ),
    };
}

fn abortPreparedRuntimeV1(runtime: *RuntimeV1) Error!void {
    switch (runtime.*) {
        .vision => |*value| try value.session.abortV1(),
        .audio_window => |*value| try value.session.abortV1(),
        .temporal_video => |*value| try value.session.abortV1(),
    }
}

fn armAndCommitRuntimeV1(
    runtime: *RuntimeV1,
    scheduler: *driver.SchedulerV1,
    permit: driver.SchedulerServicePermitV1,
    injection: FailureInjectionV1,
) Error!struct {
    event: driver.SchedulerEventV1,
    result: model.ResultEnvelopeV1,
} {
    _ = try prepareRuntimeV1(runtime);
    if (injection == .after_prepare) {
        try abortPreparedRuntimeV1(runtime);
        try scheduler.abortService(permit);
        return Error.InjectedFailure;
    }

    const armed_service = scheduler.armServiceCommit(permit) catch |err| {
        abortPreparedRuntimeV1(runtime) catch {};
        scheduler.abortService(permit) catch {};
        return err;
    };
    if (injection == .candidate_drift) {
        const candidate = candidateForRuntimeV1(runtime);
        candidate[0] ^= 0xff;
    }

    switch (runtime.*) {
        .vision => |*value| {
            var armed_model = value.session.armServiceV1(
                armed_service.intent,
            ) catch |err| {
                scheduler.abortArmedService(
                    armed_service.ticket,
                ) catch {};
                if (injection == .candidate_drift)
                    return Error.InjectedFailure;
                return err;
            };
            if (injection == .after_arm) {
                try armed_model.abort();
                try scheduler.abortArmedService(armed_service.ticket);
                return Error.InjectedFailure;
            }
            const event = scheduler.commitArmedServiceV2(
                armed_service.ticket,
                armed_model.finalizer(),
            ) catch |err| {
                armed_model.abort() catch {};
                scheduler.abortArmedService(
                    armed_service.ticket,
                ) catch {};
                return err;
            };
            return .{
                .event = event,
                .result = try armed_model.resultV1(),
            };
        },
        .audio_window => |*value| {
            var armed_model = value.session.armServiceV1(
                armed_service.intent,
            ) catch |err| {
                scheduler.abortArmedService(
                    armed_service.ticket,
                ) catch {};
                if (injection == .candidate_drift)
                    return Error.InjectedFailure;
                return err;
            };
            if (injection == .after_arm) {
                try armed_model.abort();
                try scheduler.abortArmedService(armed_service.ticket);
                return Error.InjectedFailure;
            }
            const event = scheduler.commitArmedServiceV2(
                armed_service.ticket,
                armed_model.finalizer(),
            ) catch |err| {
                armed_model.abort() catch {};
                scheduler.abortArmedService(
                    armed_service.ticket,
                ) catch {};
                return err;
            };
            return .{
                .event = event,
                .result = try armed_model.resultV1(),
            };
        },
        .temporal_video => |*value| {
            var armed_model = value.session.armServiceV1(
                armed_service.intent,
            ) catch |err| {
                scheduler.abortArmedService(
                    armed_service.ticket,
                ) catch {};
                if (injection == .candidate_drift)
                    return Error.InjectedFailure;
                return err;
            };
            if (injection == .after_arm) {
                try armed_model.abort();
                try scheduler.abortArmedService(armed_service.ticket);
                return Error.InjectedFailure;
            }
            const event = scheduler.commitArmedServiceV2(
                armed_service.ticket,
                armed_model.finalizer(),
            ) catch |err| {
                armed_model.abort() catch {};
                scheduler.abortArmedService(
                    armed_service.ticket,
                ) catch {};
                return err;
            };
            return .{
                .event = event,
                .result = try armed_model.resultV1(),
            };
        },
    }
}

fn cancelRuntimeV1(runtime: *RuntimeV1) Error!qos.EventV1 {
    return switch (runtime.*) {
        .vision => |*value| value.session.cancelScheduledV1(),
        .audio_window => |*value| value.session.cancelScheduledV1(),
        .temporal_video => |*value| value.session.cancelScheduledV1(),
    };
}

fn retireRuntimeV1(runtime: *RuntimeV1) Error!qos.EventV1 {
    return switch (runtime.*) {
        .vision => |*value| value.session.retireScheduledV1(),
        .audio_window => |*value| value.session.retireScheduledV1(),
        .temporal_video => |*value| value.session.retireScheduledV1(),
    };
}

fn cleanupRuntimeSessionV1(runtime: *RuntimeV1) Error!bool {
    switch (runtime.*) {
        inline else => |*value| {
            if (!value.session.inner.initialized) return false;
            switch (value.session.inner.phase) {
                .prepared => try value.session.abortV1(),
                .armed => return Error.InvalidExecution,
                .published => {
                    _ = try value.session.retireScheduledV1();
                    return true;
                },
                .idle => {},
                .closed => return false,
                .poisoned => return Error.InvalidExecution,
            }
            _ = try value.session.cancelScheduledV1();
            return true;
        },
    }
}

const DriverContextV1 = struct {
    storage: *ReferenceStorageV1,
    injection: FailureInjectionV1,
    injection_consumed: bool = false,
    failure: ?Error = null,

    fn fromOpaque(context: ?*anyopaque) *DriverContextV1 {
        return @ptrCast(@alignCast(context orelse
            @panic("missing typed perception driver context")));
    }

    fn fail(self: *DriverContextV1, err: Error) driver.DriverError {
        if (self.failure == null) self.failure = err;
        return error.DriverFailed;
    }

    fn bindAdmitted(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
        call: driver.DriverBindAdmittedV1,
    ) driver.DriverError!void {
        const self = fromOpaque(context);
        if (call.item_index >= reference_item_count)
            return self.fail(Error.InvalidExecution);
        const runtime = &self.storage.runtimes[call.item_index];
        const state = &self.storage.states[call.item_index];
        if (state.admitted or state.session_closed or
            familyProfileIndexV1(familyForRuntimeV1(runtime)) !=
                call.profile.index or
            !std.mem.eql(
                u8,
                &call.item.item_sha256,
                &self.storage.items[call.item_index].item_sha256,
            ))
            return self.fail(Error.InvalidExecution);
        restoreRuntimeCacheV1(runtime) catch |err|
            return self.fail(err);
        initializeScheduledRuntimeV1(
            runtime,
            scheduler,
            call.admission,
        ) catch |err| return self.fail(err);
        state.receipt = call.admission.event.resource_receipt;
        state.resource_receipt_sha256 =
            call.admission.event.resource_receipt_sha256;
        state.admitted = true;
    }

    fn cancel(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
        call: driver.DriverCancelV1,
    ) driver.DriverError!driver.SchedulerEventV1 {
        _ = scheduler;
        const self = fromOpaque(context);
        if (call.item_index >= reference_item_count)
            return self.fail(Error.InvalidExecution);
        const runtime = &self.storage.runtimes[call.item_index];
        const state = &self.storage.states[call.item_index];
        if (!state.admitted or state.executed or state.session_closed)
            return self.fail(Error.InvalidExecution);
        const event = cancelRuntimeV1(runtime) catch |err|
            return self.fail(err);
        state.session_closed = true;
        state.publication_after_sha256 =
            publicationRootV1(runtime) catch |err|
                return self.fail(err);
        return event;
    }

    fn commitService(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
        call: driver.DriverCommitServiceV1,
    ) driver.DriverError!driver.SchedulerEventV1 {
        const self = fromOpaque(context);
        if (!call.final_quantum)
            return scheduler.commitService(call.permit);
        if (call.item_index >= reference_item_count)
            return self.fail(Error.InvalidExecution);
        const runtime = &self.storage.runtimes[call.item_index];
        const state = &self.storage.states[call.item_index];
        if (!state.admitted or state.executed or state.session_closed)
            return self.fail(Error.InvalidExecution);

        const injection = if (!self.injection_consumed and
            self.injection != .none and call.item_index == 2)
            self.injection
        else
            FailureInjectionV1.none;
        if (injection != .none) self.injection_consumed = true;
        const committed = armAndCommitRuntimeV1(
            runtime,
            scheduler,
            call.permit,
            injection,
        ) catch |err| return self.fail(err);
        state.executed = true;
        state.final_service_event = committed.event;
        state.result = committed.result;
        state.publication_after_sha256 =
            publicationRootV1(runtime) catch |err|
                return self.fail(err);
        return committed.event;
    }

    fn retire(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
        call: driver.DriverRetireV1,
    ) driver.DriverError!driver.SchedulerEventV1 {
        _ = scheduler;
        const self = fromOpaque(context);
        if (call.item_index >= reference_item_count)
            return self.fail(Error.InvalidExecution);
        const runtime = &self.storage.runtimes[call.item_index];
        const state = &self.storage.states[call.item_index];
        if (!state.admitted or !state.executed or state.session_closed or
            !std.meta.eql(
                state.final_service_event,
                call.final_service_event,
            ))
            return self.fail(Error.InvalidExecution);
        const event = retireRuntimeV1(runtime) catch |err|
            return self.fail(err);
        state.session_closed = true;
        return event;
    }

    fn cleanup(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
    ) void {
        const self = fromOpaque(context);
        var report: CleanupReportV1 = .{ .invoked = true };
        for (
            &self.storage.runtimes,
            &self.storage.states,
        ) |*runtime, *state| {
            if (cleanupRuntimeSessionV1(runtime)) |closed| {
                if (closed) {
                    state.session_closed = true;
                    report.sessions_closed += 1;
                }
            } else |err| {
                if (self.failure == null) self.failure = err;
            }
            state.publication_after_sha256 =
                publicationRootV1(runtime) catch zero_digest;
            const cache = cacheForRuntimeV1(runtime);
            if (cache.started and !cache.closed) {
                cache.close() catch |err| {
                    if (self.failure == null) self.failure = err;
                    continue;
                };
                report.caches_closed += 1;
            }
        }
        const snapshot = scheduler.bank.snapshot() catch null;
        if (snapshot) |value| {
            report.model_used_zero = value.used.isZero();
            report.model_active_reservations =
                @intCast(value.active_reservations);
            report.model_committed_receipts =
                @intCast(value.committed_receipts);
        }
        populateBufferAndCacheCleanupV1(self.storage, &report);
        self.storage.cleanup_report = report;
    }

    fn interface(self: *DriverContextV1) driver.DriverV1 {
        return .{
            .context = self,
            .bind_admitted_fn = bindAdmitted,
            .cancel_fn = cancel,
            .commit_service_fn = commitService,
            .retire_fn = retire,
            .cleanup_fn = cleanup,
        };
    }
};

pub fn runReferenceCampaignV1(
    storage: *ReferenceStorageV1,
) Error!CampaignV1 {
    return runReferenceCampaignWithFailureV1(storage, .none);
}

pub fn runReferenceCampaignWithFailureV1(
    storage: *ReferenceStorageV1,
    injection: FailureInjectionV1,
) Error!CampaignV1 {
    if (!storage.prepared) try storage.prepareV1();
    try validateReferenceSealV1(storage);
    storage.cleanup_report = .{};
    for (&storage.states) |*state| {
        state.admitted = false;
        state.executed = false;
        state.session_closed = false;
        state.resource_receipt_sha256 = zero_digest;
        state.result = null;
        state.publication_after_sha256 =
            state.publication_before_sha256;
    }

    const plan = storage.planV1();
    var context: DriverContextV1 = .{
        .storage = storage,
        .injection = injection,
    };
    var driver_result: driver.ResultV1 = undefined;
    driver.runPlanWithDriverV1(
        plan,
        storage.driver_storage.interface(),
        context.interface(),
        &driver_result,
    ) catch |err| {
        if (err == error.DriverFailed)
            return context.failure orelse Error.DriverFailed;
        return err;
    };
    if (injection != .none and !context.injection_consumed)
        return Error.InvalidExecution;

    var cache_closures: u64 = 0;
    for (&storage.runtimes) |*runtime| {
        const cache = cacheForRuntimeV1(runtime);
        if (!cache.started) continue;
        try cache.close();
        cache_closures += 1;
    }
    var success_report: CleanupReportV1 = .{
        .caches_closed = cache_closures,
        .model_used_zero = driver_result.summary.zero_orphan_ownership,
        .model_active_reservations = driver_result.summary.final_active_reservations,
        .model_committed_receipts = driver_result.summary.final_committed_receipts,
    };
    for (storage.states) |state| {
        if (state.session_closed) success_report.sessions_closed += 1;
    }
    populateBufferAndCacheCleanupV1(storage, &success_report);
    storage.cleanup_report = success_report;

    const evidence = try buildEvidenceV1(
        storage,
        plan,
        driver_result,
    );
    return .{
        .plan = plan,
        .driver_result = driver_result,
        .evidence = evidence,
    };
}

fn validateReferenceSealV1(
    storage: *const ReferenceStorageV1,
) Error!void {
    if (!storage.prepared or
        storage.prepared_address != @intFromPtr(storage))
        return Error.InvalidExecution;
    var canonical_vision = try vision.ReferenceFixtureV1.init();
    try canonical_vision.rebind();
    var canonical_audio = try audio.ReferenceFixtureV1.init();
    try canonical_audio.rebind();
    var canonical_video = try video.ReferenceFixtureV1.init();
    try canonical_video.rebind();
    const expected_profiles = [reference_profile_count]contract.ProfileV1{
        makeProfileV1(
            0,
            vision.vision_support[0],
            canonical_vision.manifest,
            canonical_vision.plan,
            vision.reference_adapter_abi,
            implementationRootV1(.vision),
            expectedOutputSha256V1(.vision),
        ),
        makeProfileV1(
            1,
            audio.audio_support[0],
            canonical_audio.manifest,
            canonical_audio.plan,
            audio.reference_adapter_abi,
            implementationRootV1(.audio_window),
            expectedOutputSha256V1(.audio_window),
        ),
        makeProfileV1(
            2,
            video.video_support[0],
            canonical_video.manifest,
            canonical_video.plan,
            video.reference_adapter_abi,
            implementationRootV1(.temporal_video),
            expectedOutputSha256V1(.temporal_video),
        ),
    };
    for (storage.profiles, expected_profiles) |actual, expected| {
        if (!std.meta.eql(actual, expected))
            return Error.InvalidExecution;
    }
    const expected_items = makeReferenceItemsFromRootsV1(
        &expected_profiles,
        .{
            try vision.sourceMappingRootV1(
                canonical_vision.plan,
                canonical_vision.processor_bundle.states[0],
            ),
            try audio.sourceMappingRootV1(
                canonical_audio.plan,
                canonical_audio.processor_bundle.states[1],
            ),
            try video.sourceMappingRootV1(
                canonical_video.plan,
                canonical_video.processor_bundle.states[2],
                canonical_video.selection,
            ),
        },
    );
    for (storage.items, expected_items) |actual, expected| {
        if (!std.meta.eql(actual, expected))
            return Error.InvalidExecution;
    }
    for (
        &storage.runtimes,
        &storage.states,
        storage.items,
        0..,
    ) |*runtime, state, item, index| {
        try validateRuntimeReadyV1(
            runtime,
            state,
            item,
            index,
            &canonical_vision,
            &canonical_audio,
            &canonical_video,
        );
    }
    try contract.validatePlanV1(storage.planV1());
}

fn validateRuntimeReadyV1(
    runtime: *const RuntimeV1,
    state: ItemStateV1,
    item: contract.ItemV1,
    index: usize,
    canonical_vision: *const vision.ReferenceFixtureV1,
    canonical_audio: *const audio.ReferenceFixtureV1,
    canonical_video: *const video.ReferenceFixtureV1,
) Error!void {
    if (state.admitted or state.executed or state.session_closed or
        state.result != null or
        !digestIsZero(state.resource_receipt_sha256) or
        !std.mem.eql(
            u8,
            &state.publication_before_sha256,
            &state.publication_after_sha256,
        ) or !runtimeBuffersZeroV1(runtime) or
        !runtimeOutputZeroV1(runtime))
        return Error.InvalidExecution;
    switch (runtime.*) {
        .vision => |*value| {
            if (index != 0 and index != 4)
                return Error.InvalidExecution;
            try validateRuntimeCommonV1(
                &value.cache,
                &value.session,
                value.fixture.publication_state,
                state,
                item,
                .vision,
                try vision.sourceMappingRootV1(
                    value.fixture.plan,
                    value.fixture.processor_bundle.states[0],
                ),
            );
            try validateDecodedBundlesV1(
                &value.fixture.processor_storage,
                &value.fixture.cache_storage,
                value.fixture.processor_bundle,
                value.fixture.cache_bundle,
            );
            if (!std.meta.eql(
                value.fixture.manifest,
                canonical_vision.manifest,
            ) or !std.meta.eql(
                value.fixture.plan,
                canonical_vision.plan,
            ) or !std.meta.eql(
                value.fixture.publication_state,
                canonical_vision.publication_state,
            ) or !std.mem.eql(
                u8,
                &value.fixture.processor_storage,
                &canonical_vision.processor_storage,
            ) or !std.mem.eql(
                u8,
                &value.fixture.cache_storage,
                &canonical_vision.cache_storage,
            ) or !std.mem.eql(
                u8,
                &value.fixture.weights,
                &canonical_vision.weights,
            ) or !std.mem.eql(
                u8,
                &value.fixture.image_features,
                &canonical_vision.image_features,
            ) or !std.mem.eql(
                u8,
                &value.fixture.audio_features,
                &canonical_vision.audio_features,
            ) or !std.mem.eql(
                u8,
                &value.fixture.video_features,
                &canonical_vision.video_features,
            ))
                return Error.InvalidExecution;
        },
        .audio_window => |*value| {
            if (index != 1 and index != 5)
                return Error.InvalidExecution;
            try validateRuntimeCommonV1(
                &value.cache,
                &value.session,
                value.fixture.publication_state,
                state,
                item,
                .audio_window,
                try audio.sourceMappingRootV1(
                    value.fixture.plan,
                    value.fixture.processor_bundle.states[1],
                ),
            );
            try validateDecodedBundlesV1(
                &value.fixture.processor_storage,
                &value.fixture.cache_storage,
                value.fixture.processor_bundle,
                value.fixture.cache_bundle,
            );
            if (!std.meta.eql(
                value.fixture.manifest,
                canonical_audio.manifest,
            ) or !std.meta.eql(
                value.fixture.plan,
                canonical_audio.plan,
            ) or !std.meta.eql(
                value.fixture.publication_state,
                canonical_audio.publication_state,
            ) or !std.mem.eql(
                u8,
                &value.fixture.processor_storage,
                &canonical_audio.processor_storage,
            ) or !std.mem.eql(
                u8,
                &value.fixture.cache_storage,
                &canonical_audio.cache_storage,
            ) or !std.mem.eql(
                u8,
                &value.fixture.weights,
                &canonical_audio.weights,
            ) or !std.mem.eql(
                u8,
                &value.fixture.image_cache,
                &canonical_audio.image_cache,
            ) or !std.mem.eql(
                u8,
                &value.fixture.audio_features,
                &canonical_audio.audio_features,
            ) or !std.mem.eql(
                u8,
                &value.fixture.video_cache,
                &canonical_audio.video_cache,
            ))
                return Error.InvalidExecution;
        },
        .temporal_video => |*value| {
            if (index != 2 and index != 3)
                return Error.InvalidExecution;
            try validateRuntimeCommonV1(
                &value.cache,
                &value.session,
                value.fixture.publication_state,
                state,
                item,
                .temporal_video,
                try video.sourceMappingRootV1(
                    value.fixture.plan,
                    value.fixture.processor_bundle.states[2],
                    value.fixture.selection,
                ),
            );
            try validateDecodedBundlesV1(
                &value.fixture.processor_storage,
                &value.fixture.cache_storage,
                value.fixture.processor_bundle,
                value.fixture.cache_bundle,
            );
            if (!std.meta.eql(
                value.fixture.manifest,
                canonical_video.manifest,
            ) or !std.meta.eql(
                value.fixture.plan,
                canonical_video.plan,
            ) or !std.meta.eql(
                value.fixture.publication_state,
                canonical_video.publication_state,
            ) or !std.meta.eql(
                value.fixture.selection,
                canonical_video.selection,
            ) or !std.mem.eql(
                u8,
                &value.fixture.processor_storage,
                &canonical_video.processor_storage,
            ) or !std.mem.eql(
                u8,
                &value.fixture.cache_storage,
                &canonical_video.cache_storage,
            ) or !std.mem.eql(
                u8,
                &value.fixture.weights,
                &canonical_video.weights,
            ) or !std.mem.eql(
                u8,
                &value.fixture.image_cache,
                &canonical_video.image_cache,
            ) or !std.mem.eql(
                u8,
                &value.fixture.audio_cache,
                &canonical_video.audio_cache,
            ) or !std.mem.eql(
                u8,
                &value.fixture.video_cache,
                &canonical_video.video_cache,
            ))
                return Error.InvalidExecution;
        },
    }
}

fn validateDecodedBundlesV1(
    processor_storage: []const u8,
    cache_storage: []const u8,
    actual_processor: processor.DecodedBundleV1,
    actual_cache: processor_cache.DecodedBundleV1,
) Error!void {
    const decoded_processor =
        try processor.decodeBundleV1(processor_storage);
    const decoded_cache =
        try processor_cache.decodeBundleV1(cache_storage);
    if (!std.meta.eql(actual_processor, decoded_processor))
        return Error.InvalidExecution;
    var normalized_cache = actual_cache;
    normalized_cache.payloads = decoded_cache.payloads;
    if (!std.meta.eql(normalized_cache, decoded_cache))
        return Error.InvalidExecution;
    for (actual_cache.payloads, decoded_cache.payloads) |
        actual_payload,
        decoded_payload,
    | {
        if (actual_payload.ptr != decoded_payload.ptr or
            actual_payload.len != decoded_payload.len or
            !std.mem.eql(u8, actual_payload, decoded_payload))
            return Error.InvalidExecution;
    }
}

fn validateRuntimeCommonV1(
    cache: *const CacheRuntimeV1,
    session: anytype,
    publication_state: model.PublicationStateV1,
    state: ItemStateV1,
    item: contract.ItemV1,
    family: PerceptionFamilyV1,
    source_mapping_sha256: Digest,
) Error!void {
    if (cache.started or cache.restored or cache.closed or
        cache.session.phase != .idle or
        cache.session.prepared_count != 0 or
        cache.session.active_count != 0 or
        session.inner.initialized or session.inner.phase != .idle or
        item.profile_index != familyProfileIndexV1(family) or
        !std.mem.eql(
            u8,
            &item.input_binding_sha256,
            &source_mapping_sha256,
        ))
        return Error.InvalidExecution;
    const publication_sha256 =
        try model.publicationStateRootV1(publication_state);
    if (!std.mem.eql(
        u8,
        &publication_sha256,
        &state.publication_before_sha256,
    ))
        return Error.InvalidExecution;
}

fn buildEvidenceV1(
    storage: *ReferenceStorageV1,
    plan: contract.PlanV1,
    driver_result: driver.ResultV1,
) Error!EvidenceV1 {
    try contract.validatePlanV1(plan);
    try driver.validateResultStructureV1(plan, driver_result);
    if (driver_result.outcomes.len != reference_item_count)
        return Error.InvalidEvidence;

    for (
        plan.items,
        driver_result.outcomes,
        &storage.runtimes,
        &storage.states,
        &storage.item_evidence,
    ) |item, outcome, *runtime, *state, *evidence_item| {
        const profile_index = std.math.cast(
            usize,
            item.profile_index,
        ) orelse return Error.InvalidEvidence;
        if (profile_index >= plan.profiles.len)
            return Error.InvalidEvidence;
        const profile = plan.profiles[profile_index];
        const execution_plan = executionPlanForRuntimeV1(runtime);
        const admitted = outcome.kind != .rejected;
        if (state.admitted != admitted or
            (admitted and !state.session_closed))
            return Error.InvalidExecution;

        const completed = outcome.kind == .completed;
        if (completed != state.executed or
            completed != (state.result != null))
            return Error.InvalidExecution;
        if (!runtimeBuffersZeroV1(runtime))
            return Error.InvalidExecution;
        if (!completed and !runtimeOutputZeroV1(runtime))
            return Error.InvalidExecution;

        const result = state.result;
        if (result) |value| {
            if (!std.mem.eql(
                u8,
                &value.output_sha256,
                &model.sha256(outputForRuntimeV1(runtime)),
            ) or !std.mem.eql(
                u8,
                &value.output_sha256,
                &expectedOutputSha256V1(familyForRuntimeV1(runtime)),
            ) or !std.mem.eql(
                u8,
                &value.publication_state_before_sha256,
                &state.publication_before_sha256,
            ) or !std.mem.eql(
                u8,
                &value.artifact_sha256,
                &profile.artifact_sha256,
            ) or !std.mem.eql(
                u8,
                &value.plan_sha256,
                &profile.execution_plan_sha256,
            ))
                return Error.InvalidExecution;
        } else if (!std.mem.eql(
            u8,
            &state.publication_before_sha256,
            &state.publication_after_sha256,
        )) {
            return Error.InvalidExecution;
        }

        evidence_item.* = .{
            .ordinal = item.ordinal,
            .family = familyForRuntimeV1(runtime),
            .profile_index = item.profile_index,
            .outcome = outcome.kind,
            .terminal_action = outcome.terminal_action,
            .profile_sha256 = profile.profile_sha256,
            .item_sha256 = item.item_sha256,
            .artifact_sha256 = profile.artifact_sha256,
            .execution_plan_sha256 = profile.execution_plan_sha256,
            .execution_plan = execution_plan,
            .adapter_implementation_sha256 = profile.adapter_implementation_sha256,
            .adapter_sha256 = if (result) |value|
                value.adapter_sha256
            else
                zero_digest,
            .source_mapping_sha256 = if (result) |value|
                value.source_mapping_sha256
            else
                zero_digest,
            .resource_receipt_sha256 = if (admitted)
                state.resource_receipt_sha256
            else
                zero_digest,
            .resource_bank_epoch = if (admitted)
                state.receipt.bank_epoch
            else
                0,
            .resource_slot_index = if (admitted)
                state.receipt.slot_index
            else
                0,
            .resource_generation = if (admitted)
                state.receipt.generation
            else
                0,
            .resource_owner_key = if (admitted)
                state.receipt.owner_key
            else
                0,
            .resource_claim = if (admitted)
                state.receipt.claim
            else
                .{},
            .resource_integrity = if (admitted)
                state.receipt.integrity
            else
                0,
            .final_service_event_sha256 = if (completed)
                state.final_service_event.event_sha256
            else
                zero_digest,
            .result_envelope_sha256 = if (result) |value|
                value.result_sha256
            else
                zero_digest,
            .result_envelope = result,
            .output_sha256 = if (result) |value|
                value.output_sha256
            else
                zero_digest,
            .publication_state_before_sha256 = state.publication_before_sha256,
            .publication_state_after_sha256 = state.publication_after_sha256,
            .admission_trace_sha256 = outcome.admission_trace_sha256,
            .terminal_trace_sha256 = outcome.terminal_trace_sha256,
            .driver_outcome_sha256 = outcome.record_sha256,
        };
        evidence_item.record_sha256 =
            try itemEvidenceSha256V1(evidence_item.*);
    }

    const items = storage.item_evidence[0..reference_item_count];
    var cache_commits: u64 = 0;
    var cache_releases: u64 = 0;
    var cache_live: u64 = 0;
    var cache_zero = true;
    for (&storage.runtimes) |*runtime| {
        const cache = cacheForRuntimeV1(runtime);
        if (!cache.started) continue;
        if (!cache.closed) return Error.InvalidExecution;
        cache_commits = try checkedAdd(
            cache_commits,
            cache.final_snapshot.successful_commits,
        );
        cache_releases = try checkedAdd(
            cache_releases,
            cache.final_snapshot.releases,
        );
        cache_live = try checkedAdd(
            cache_live,
            @intCast(cache.final_snapshot.live_allocations),
        );
        cache_zero = cache_zero and
            cacheSnapshotHasZeroAuthorityV1(cache.final_snapshot);
    }

    var vision_completed: u64 = 0;
    var audio_completed: u64 = 0;
    var video_completed: u64 = 0;
    for (items) |item| {
        if (item.outcome != .completed) continue;
        switch (item.family) {
            .vision => vision_completed += 1,
            .audio_window => audio_completed += 1,
            .temporal_video => video_completed += 1,
        }
    }
    const model_zero =
        driver_result.summary.zero_orphan_ownership and
        driver_result.summary.final_active_reservations == 0 and
        driver_result.summary.final_committed_receipts == 0;
    var summary: SummaryV1 = .{
        .profile_count = @intCast(plan.profiles.len),
        .item_count = @intCast(plan.items.len),
        .admitted = driver_result.summary.admitted,
        .rejected = driver_result.summary.rejected,
        .completed = driver_result.summary.completed,
        .cancelled = driver_result.summary.cancelled,
        .timed_out = driver_result.summary.timed_out,
        .vision_completed = vision_completed,
        .audio_window_completed = audio_completed,
        .temporal_video_completed = video_completed,
        .publications = driver_result.summary.completed,
        .nonpublished_terminal_items = driver_result.summary.rejected +
            driver_result.summary.cancelled +
            driver_result.summary.timed_out,
        .cache_restores = driver_result.summary.admitted,
        .cache_closures = driver_result.summary.admitted,
        .cache_successful_commits = cache_commits,
        .cache_releases = cache_releases,
        .cache_live_allocations = cache_live,
        .model_successful_commits = driver_result.summary.successful_commits,
        .model_releases = driver_result.summary.releases,
        .model_final_active_reservations = driver_result.summary.final_active_reservations,
        .model_final_committed_receipts = driver_result.summary.final_committed_receipts,
        .zero_model_ownership = model_zero,
        .zero_cache_ownership = cache_zero,
        .zero_orphan_ownership = model_zero and cache_zero,
    };
    summary.summary_sha256 = summarySha256V1(summary);

    var evidence: EvidenceV1 = .{
        .plan_sha256 = driver_result.plan_sha256,
        .driver_result_sha256 = driver_result.result_sha256,
        .driver_outcome_sha256 = driver_result.outcome_sha256,
        .driver_trace_sha256 = driver_result.trace_sha256,
        .driver_summary_sha256 = driver_result.summary_sha256,
        .item_section_sha256 = itemSectionSha256V1(items),
        .evidence_summary_sha256 = summary.summary_sha256,
        .items = items,
        .summary = summary,
        .evidence_sha256 = zero_digest,
    };
    evidence.evidence_sha256 = evidenceSha256V1(evidence);
    try validateEvidenceByReplayV1(
        plan,
        driver_result,
        evidence,
        storage.replay_storage.interface(),
    );
    return evidence;
}

/// Authoritative validation for canonical handoff. Structural evidence checks
/// are composed with a fresh deterministic scheduler replay so a consistently
/// resealed, noncanonical driver result is still rejected.
pub fn validateEvidenceByReplayV1(
    plan: contract.PlanV1,
    driver_result: driver.ResultV1,
    evidence: EvidenceV1,
    replay_storage: driver.StorageV1,
) Error!void {
    try driver.validateResultByReplayV1(
        plan,
        driver_result,
        replay_storage,
    );
    try validateEvidenceV1(plan, driver_result, evidence);
}

/// Structural sidecar validation for callers that already authenticated the
/// driver result by replay. New trust boundaries should use
/// `validateEvidenceByReplayV1`.
pub fn validateEvidenceV1(
    plan: contract.PlanV1,
    driver_result: driver.ResultV1,
    evidence: EvidenceV1,
) Error!void {
    try contract.validatePlanV1(plan);
    try driver.validateResultStructureV1(plan, driver_result);
    if (evidence.items.len != plan.items.len or
        evidence.summary.profile_count != plan.profiles.len or
        evidence.summary.item_count != plan.items.len or
        !std.mem.eql(
            u8,
            &evidence.plan_sha256,
            &contract.planSha256V1(plan),
        ) or !std.mem.eql(
        u8,
        &evidence.driver_result_sha256,
        &driver_result.result_sha256,
    ) or !std.mem.eql(
        u8,
        &evidence.driver_outcome_sha256,
        &driver_result.outcome_sha256,
    ) or !std.mem.eql(
        u8,
        &evidence.driver_trace_sha256,
        &driver_result.trace_sha256,
    ) or !std.mem.eql(
        u8,
        &evidence.driver_summary_sha256,
        &driver_result.summary_sha256,
    ) or !std.mem.eql(
        u8,
        &evidence.item_section_sha256,
        &itemSectionSha256V1(evidence.items),
    ) or !std.mem.eql(
        u8,
        &evidence.evidence_summary_sha256,
        &summarySha256V1(evidence.summary),
    ) or !std.mem.eql(
        u8,
        &evidence.evidence_sha256,
        &evidenceSha256V1(evidence),
    ))
        return Error.InvalidEvidence;

    var vision_completed: u64 = 0;
    var audio_completed: u64 = 0;
    var video_completed: u64 = 0;
    for (
        plan.items,
        driver_result.outcomes,
        evidence.items,
    ) |item, outcome, evidence_item| {
        const profile_index = std.math.cast(
            usize,
            item.profile_index,
        ) orelse return Error.InvalidEvidence;
        if (profile_index >= plan.profiles.len)
            return Error.InvalidEvidence;
        const profile = plan.profiles[profile_index];
        try validateExecutionPlanBindingV1(
            profile,
            evidence_item.execution_plan,
        );
        const expected_adapter_sha256 = try expectedAdapterSha256V1(
            evidence_item.family,
            profile,
            evidence_item.execution_plan,
        );
        const expected_record =
            try itemEvidenceSha256V1(evidence_item);
        if (evidence_item.ordinal != item.ordinal or
            evidence_item.profile_index != item.profile_index or
            evidence_item.outcome != outcome.kind or
            evidence_item.terminal_action != outcome.terminal_action or
            familyProfileIndexV1(evidence_item.family) !=
                item.profile_index or
            !std.mem.eql(
                u8,
                &evidence_item.profile_sha256,
                &profile.profile_sha256,
            ) or !std.mem.eql(
            u8,
            &evidence_item.item_sha256,
            &item.item_sha256,
        ) or !std.mem.eql(
            u8,
            &evidence_item.artifact_sha256,
            &profile.artifact_sha256,
        ) or !std.mem.eql(
            u8,
            &evidence_item.execution_plan_sha256,
            &profile.execution_plan_sha256,
        ) or !std.mem.eql(
            u8,
            &evidence_item.adapter_implementation_sha256,
            &profile.adapter_implementation_sha256,
        ) or !std.mem.eql(
            u8,
            &evidence_item.admission_trace_sha256,
            &outcome.admission_trace_sha256,
        ) or !std.mem.eql(
            u8,
            &evidence_item.terminal_trace_sha256,
            &outcome.terminal_trace_sha256,
        ) or !std.mem.eql(
            u8,
            &evidence_item.driver_outcome_sha256,
            &outcome.record_sha256,
        ) or !std.mem.eql(
            u8,
            &evidence_item.record_sha256,
            &expected_record,
        ))
            return Error.InvalidEvidence;

        const admitted = outcome.kind != .rejected;
        const completed = outcome.kind == .completed;
        if (admitted) {
            const receipt = try evidenceReceiptV1(evidence_item);
            if (!resource_bank.receiptIntegrityValidV1(receipt) or
                receipt.bank_epoch != plan.bank_epoch or
                receipt.owner_key != item.resource_owner_key or
                @as(u64, receipt.slot_index) !=
                    outcome.scheduler_slot_index or
                receipt.generation !=
                    outcome.scheduler_slot_generation or
                !std.mem.eql(
                    u8,
                    &evidence_item.resource_receipt_sha256,
                    &qos.resourceReceiptSha256(receipt),
                ) or !std.meta.eql(receipt.claim, item.claim))
                return Error.InvalidEvidence;
        } else if (!receiptEvidenceIsZeroV1(evidence_item)) {
            return Error.InvalidEvidence;
        }
        if (completed) {
            const result = evidence_item.result_envelope orelse
                return Error.InvalidEvidence;
            try validateCompletedResultV1(
                item,
                profile,
                evidence_item,
                expected_adapter_sha256,
                result,
            );
            if (!finalServiceEvidencePresentV1(
                driver_result,
                evidence_item,
            ) or
                digestIsZero(
                    evidence_item.final_service_event_sha256,
                ))
                return Error.InvalidEvidence;
            switch (evidence_item.family) {
                .vision => vision_completed += 1,
                .audio_window => audio_completed += 1,
                .temporal_video => video_completed += 1,
            }
        } else if (evidence_item.result_envelope != null or
            !resultEvidenceIsZeroV1(evidence_item) or
            !std.mem.eql(
                u8,
                &evidence_item.publication_state_before_sha256,
                &evidence_item.publication_state_after_sha256,
            ))
            return Error.InvalidEvidence;
    }

    const summary = evidence.summary;
    const expected_cache_operations = std.math.mul(
        u64,
        summary.cache_restores,
        processor_cache.cache_count,
    ) catch return Error.InvalidEvidence;
    if (summary.admitted != driver_result.summary.admitted or
        summary.rejected != driver_result.summary.rejected or
        summary.completed != driver_result.summary.completed or
        summary.cancelled != driver_result.summary.cancelled or
        summary.timed_out != driver_result.summary.timed_out or
        summary.vision_completed != vision_completed or
        summary.audio_window_completed != audio_completed or
        summary.temporal_video_completed != video_completed or
        summary.publications != summary.completed or
        summary.nonpublished_terminal_items !=
            summary.rejected + summary.cancelled + summary.timed_out or
        summary.cache_restores != summary.admitted or
        summary.cache_closures != summary.admitted or
        summary.cache_successful_commits !=
            expected_cache_operations or
        summary.cache_releases != expected_cache_operations or
        summary.cache_live_allocations != 0 or
        summary.model_successful_commits !=
            driver_result.summary.successful_commits or
        summary.model_releases != driver_result.summary.releases or
        summary.model_final_active_reservations != 0 or
        summary.model_final_committed_receipts != 0 or
        !summary.zero_model_ownership or
        !summary.zero_cache_ownership or
        !summary.zero_orphan_ownership or
        !std.mem.eql(
            u8,
            &summary.summary_sha256,
            &evidence.evidence_summary_sha256,
        ))
        return Error.InvalidEvidence;
}

pub fn itemEvidenceSha256V1(item: ItemEvidenceV1) Error!Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(item_evidence_domain);
    hashU64(&hash, item_evidence_abi);
    hashU64(&hash, item.ordinal);
    hashU64(&hash, @intFromEnum(item.family));
    hashU64(&hash, item.profile_index);
    hashU64(&hash, @intFromEnum(item.outcome));
    hashU64(&hash, @intFromEnum(item.terminal_action));
    hash.update(&item.profile_sha256);
    hash.update(&item.item_sha256);
    hash.update(&item.artifact_sha256);
    hash.update(&item.execution_plan_sha256);
    var encoded_plan: [model.execution_plan_bytes]u8 = undefined;
    try model.encodeExecutionPlanV1(
        item.execution_plan,
        &encoded_plan,
    );
    hash.update(&encoded_plan);
    hash.update(&item.adapter_implementation_sha256);
    hash.update(&item.adapter_sha256);
    hash.update(&item.source_mapping_sha256);
    hash.update(&item.resource_receipt_sha256);
    hashU64(&hash, item.resource_bank_epoch);
    hashU64(&hash, item.resource_slot_index);
    hashU64(&hash, item.resource_generation);
    hashU64(&hash, item.resource_owner_key);
    hashClaim(&hash, item.resource_claim);
    hashU64(&hash, item.resource_integrity);
    hash.update(&item.final_service_event_sha256);
    hash.update(&item.result_envelope_sha256);
    hashU64(&hash, @intFromBool(item.result_envelope != null));
    if (item.result_envelope) |result| {
        var encoded_result: [model.result_envelope_bytes]u8 =
            undefined;
        try model.encodeResultEnvelopeV1(result, &encoded_result);
        hash.update(&encoded_result);
    }
    hash.update(&item.output_sha256);
    hash.update(&item.publication_state_before_sha256);
    hash.update(&item.publication_state_after_sha256);
    hash.update(&item.admission_trace_sha256);
    hash.update(&item.terminal_trace_sha256);
    hash.update(&item.driver_outcome_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn itemSectionSha256V1(items: []const ItemEvidenceV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(item_section_domain);
    hashU64(&hash, items.len);
    for (items) |item| hash.update(&item.record_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn summarySha256V1(summary: SummaryV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(summary_domain);
    hashU64(&hash, summary_abi);
    hashU64(&hash, summary.profile_count);
    hashU64(&hash, summary.item_count);
    hashU64(&hash, summary.admitted);
    hashU64(&hash, summary.rejected);
    hashU64(&hash, summary.completed);
    hashU64(&hash, summary.cancelled);
    hashU64(&hash, summary.timed_out);
    hashU64(&hash, summary.vision_completed);
    hashU64(&hash, summary.audio_window_completed);
    hashU64(&hash, summary.temporal_video_completed);
    hashU64(&hash, summary.publications);
    hashU64(&hash, summary.nonpublished_terminal_items);
    hashU64(&hash, summary.cache_restores);
    hashU64(&hash, summary.cache_closures);
    hashU64(&hash, summary.cache_successful_commits);
    hashU64(&hash, summary.cache_releases);
    hashU64(&hash, summary.cache_live_allocations);
    hashU64(&hash, summary.model_successful_commits);
    hashU64(&hash, summary.model_releases);
    hashU64(&hash, summary.model_final_active_reservations);
    hashU64(&hash, summary.model_final_committed_receipts);
    hashU64(&hash, @intFromBool(summary.zero_model_ownership));
    hashU64(&hash, @intFromBool(summary.zero_cache_ownership));
    hashU64(&hash, @intFromBool(summary.zero_orphan_ownership));
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn evidenceSha256V1(evidence: EvidenceV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(evidence_domain);
    hashU64(&hash, evidence_abi);
    hash.update(&evidence.plan_sha256);
    hash.update(&evidence.driver_result_sha256);
    hash.update(&evidence.driver_outcome_sha256);
    hash.update(&evidence.driver_trace_sha256);
    hash.update(&evidence.driver_summary_sha256);
    hash.update(&evidence.item_section_sha256);
    hash.update(&evidence.evidence_summary_sha256);
    hashU64(&hash, evidence.items.len);
    for (evidence.items) |item| hash.update(&item.record_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn familyProfileIndexV1(family: PerceptionFamilyV1) u64 {
    return switch (family) {
        .vision => 0,
        .audio_window => 1,
        .temporal_video => 2,
    };
}

fn implementationRootV1(family: PerceptionFamilyV1) Digest {
    return switch (family) {
        .vision => model.sha256(
            "glacier reference vision implementation v1",
        ),
        .audio_window => model.sha256(
            "glacier reference audio-window implementation v1",
        ),
        .temporal_video => model.sha256(
            "glacier reference temporal-video implementation v1",
        ),
    };
}

fn validateExecutionPlanBindingV1(
    profile: contract.ProfileV1,
    execution_plan: model.ExecutionPlanV1,
) Error!void {
    try model.validateExecutionPlanV1(execution_plan);
    if (profile.family != execution_plan.family or
        profile.operation != execution_plan.operation or
        profile.input_kind != execution_plan.input_kind or
        profile.output_kind != execution_plan.output_kind or
        profile.numerical_policy != execution_plan.numerical_policy or
        !std.meta.eql(profile.claim, execution_plan.claim) or
        !std.mem.eql(
            u8,
            &profile.artifact_sha256,
            &execution_plan.artifact_sha256,
        ) or !std.mem.eql(
        u8,
        &profile.execution_plan_sha256,
        &execution_plan.plan_sha256,
    ))
        return Error.InvalidEvidence;
}

fn expectedAdapterSha256V1(
    family: PerceptionFamilyV1,
    profile: contract.ProfileV1,
    execution_plan: model.ExecutionPlanV1,
) Error!Digest {
    const expected_abi: u64 = switch (family) {
        .vision => vision.reference_adapter_abi,
        .audio_window => audio.reference_adapter_abi,
        .temporal_video => video.reference_adapter_abi,
    };
    const expected_support = switch (family) {
        .vision => contract.supportRecordSha256V1(
            vision.vision_support[0],
        ),
        .audio_window => contract.supportRecordSha256V1(
            audio.audio_support[0],
        ),
        .temporal_video => contract.supportRecordSha256V1(
            video.video_support[0],
        ),
    };
    const expected_implementation = implementationRootV1(family);
    const expected_correctness = expectedOutputSha256V1(family);
    if (profile.index != familyProfileIndexV1(family) or
        profile.adapter_abi != expected_abi or
        profile.lifecycle != .stateless or
        profile.execution_unit != .operation or
        profile.cancellation_boundary != .between_units or
        profile.publication_policy != .final_only or
        profile.correctness_gate != .exact or
        !std.mem.eql(
            u8,
            &profile.support_sha256,
            &expected_support,
        ) or !std.mem.eql(
        u8,
        &profile.adapter_implementation_sha256,
        &expected_implementation,
    ) or !std.mem.eql(
        u8,
        &profile.correctness_sha256,
        &expected_correctness,
    ) or execution_plan.batch_items != 2 or
        execution_plan.publication_next_sequence != 0)
        return Error.InvalidEvidence;
    var descriptor: vision.AdapterDescriptorV1 = .{
        .adapter_abi = expected_abi,
        .family = execution_plan.family,
        .operation = execution_plan.operation,
        .input_kind = execution_plan.input_kind,
        .output_kind = execution_plan.output_kind,
        .numerical_policy = execution_plan.numerical_policy,
        .max_batch_items = 2,
        .max_input_features = execution_plan.input_features,
        .max_output_dimensions = execution_plan.output_dimensions,
        .allowed_capabilities = model.no_capabilities,
        .implementation_sha256 = expected_implementation,
        .adapter_sha256 = zero_digest,
    };
    descriptor.adapter_sha256 =
        vision.adapterDescriptorRootV1(descriptor);
    return descriptor.adapter_sha256;
}

fn evidenceReceiptV1(
    item: ItemEvidenceV1,
) Error!resource_bank.Receipt {
    return .{
        .bank_epoch = item.resource_bank_epoch,
        .slot_index = std.math.cast(
            u32,
            item.resource_slot_index,
        ) orelse return Error.InvalidEvidence,
        .generation = item.resource_generation,
        .owner_key = item.resource_owner_key,
        .claim = item.resource_claim,
        .integrity = item.resource_integrity,
    };
}

fn validateCompletedResultV1(
    item: contract.ItemV1,
    profile: contract.ProfileV1,
    evidence_item: ItemEvidenceV1,
    expected_adapter_sha256: Digest,
    result: model.ResultEnvelopeV1,
) Error!void {
    try model.validateResultEnvelopeV1(result);
    const execution_plan = evidence_item.execution_plan;
    const receipt = try evidenceReceiptV1(evidence_item);
    if (result.family != execution_plan.family or
        result.operation != execution_plan.operation or
        result.output_kind != execution_plan.output_kind or
        result.numerical_policy != execution_plan.numerical_policy or
        result.request_epoch != execution_plan.request_epoch or
        result.generation != execution_plan.generation or
        result.publication_sequence !=
            execution_plan.publication_next_sequence or
        !digestIsZero(result.previous_result_sha256) or
        result.batch_items != execution_plan.batch_items or
        result.output_dimensions != execution_plan.output_dimensions or
        result.output_element_bytes !=
            execution_plan.output_element_bytes or
        result.output_bytes != execution_plan.output_bytes or
        result.resource_bank_epoch != receipt.bank_epoch or
        result.resource_slot_index != receipt.slot_index or
        result.resource_generation != receipt.generation or
        result.resource_owner_key != receipt.owner_key or
        !std.meta.eql(result.claim, receipt.claim) or
        result.resource_integrity != receipt.integrity or
        !std.mem.eql(
            u8,
            &result.artifact_sha256,
            &execution_plan.artifact_sha256,
        ) or !std.mem.eql(
        u8,
        &result.plan_sha256,
        &execution_plan.plan_sha256,
    ) or !std.mem.eql(
        u8,
        &result.media_object_sha256,
        &execution_plan.media_object_sha256,
    ) or !std.mem.eql(
        u8,
        &result.processor_state_sha256,
        &execution_plan.processor_state_sha256,
    ) or !std.mem.eql(
        u8,
        &result.cache_bundle_sha256,
        &execution_plan.cache_bundle_sha256,
    ) or !std.mem.eql(
        u8,
        &result.cache_payload_sha256,
        &execution_plan.cache_payload_sha256,
    ) or !std.mem.eql(
        u8,
        &result.ownership_sha256,
        &execution_plan.ownership_sha256,
    ) or !std.mem.eql(
        u8,
        &result.challenge_sha256,
        &execution_plan.challenge_sha256,
    ) or !std.mem.eql(
        u8,
        &result.artifact_sha256,
        &profile.artifact_sha256,
    ) or !std.mem.eql(
        u8,
        &result.plan_sha256,
        &profile.execution_plan_sha256,
    ) or !std.mem.eql(
        u8,
        &result.source_mapping_sha256,
        &item.input_binding_sha256,
    ) or !std.mem.eql(
        u8,
        &result.source_mapping_sha256,
        &evidence_item.source_mapping_sha256,
    ) or !std.mem.eql(
        u8,
        &result.adapter_sha256,
        &expected_adapter_sha256,
    ) or !std.mem.eql(
        u8,
        &result.adapter_sha256,
        &evidence_item.adapter_sha256,
    ) or !std.mem.eql(
        u8,
        &result.output_sha256,
        &expectedOutputSha256V1(evidence_item.family),
    ) or !std.mem.eql(
        u8,
        &result.output_sha256,
        &evidence_item.output_sha256,
    ) or !std.mem.eql(
        u8,
        &result.result_sha256,
        &evidence_item.result_envelope_sha256,
    ) or !std.mem.eql(
        u8,
        &result.publication_state_before_sha256,
        &evidence_item.publication_state_before_sha256,
    ))
        return Error.InvalidEvidence;

    const state_before: model.PublicationStateV1 = .{
        .request_epoch = result.request_epoch,
        .next_sequence = result.publication_sequence,
        .visible_results = result.publication_sequence,
        .artifact_sha256 = result.artifact_sha256,
        .previous_result_sha256 = result.previous_result_sha256,
    };
    const state_before_sha256 =
        try model.publicationStateRootV1(state_before);
    if (!std.mem.eql(
        u8,
        &state_before_sha256,
        &evidence_item.publication_state_before_sha256,
    ))
        return Error.InvalidEvidence;
    var state_after = state_before;
    try model.commitResultV1(&state_after, result);
    const state_after_sha256 =
        try model.publicationStateRootV1(state_after);
    if (!std.mem.eql(
        u8,
        &state_after_sha256,
        &evidence_item.publication_state_after_sha256,
    ))
        return Error.InvalidEvidence;
}

fn finalServiceEvidencePresentV1(
    driver_result: driver.ResultV1,
    item: ItemEvidenceV1,
) bool {
    for (driver_result.trace) |record| {
        if (record.item_ordinal == item.ordinal and
            record.profile_index == item.profile_index and
            record.event_kind == .service and
            record.remaining_after == 0 and
            std.mem.eql(
                u8,
                &record.scheduler_event_sha256,
                &item.final_service_event_sha256,
            ))
            return true;
    }
    return false;
}

fn expectedOutputSha256V1(family: PerceptionFamilyV1) Digest {
    var encoded: [output_bytes]u8 = undefined;
    const values: [4]i32 = switch (family) {
        .vision => .{ 30, 6, 70, 6 },
        .audio_window => .{ 500, 500, 500, 1500 },
        .temporal_video => .{ 5, 5, 17, 13 },
    };
    for (values, 0..) |value, index| {
        const offset = index * @sizeOf(i32);
        std.mem.writeInt(
            i32,
            encoded[offset .. offset + @sizeOf(i32)][0..@sizeOf(i32)],
            value,
            .little,
        );
    }
    return model.sha256(&encoded);
}

fn receiptEvidenceIsZeroV1(item: ItemEvidenceV1) bool {
    return digestIsZero(item.resource_receipt_sha256) and
        item.resource_bank_epoch == 0 and
        item.resource_slot_index == 0 and
        item.resource_generation == 0 and
        item.resource_owner_key == 0 and
        item.resource_claim.isZero() and
        item.resource_integrity == 0;
}

fn resultEvidenceIsZeroV1(item: ItemEvidenceV1) bool {
    return item.result_envelope == null and
        digestIsZero(item.adapter_sha256) and
        digestIsZero(item.source_mapping_sha256) and
        digestIsZero(item.final_service_event_sha256) and
        digestIsZero(item.result_envelope_sha256) and
        digestIsZero(item.output_sha256);
}

fn cacheSnapshotHasZeroAuthorityV1(
    snapshot: resource_bank.SnapshotV3,
) bool {
    return snapshot.used.isZero() and
        snapshot.active_reservations == 0 and
        snapshot.committed_receipts == 0 and
        snapshot.active_child_leases == 0 and
        snapshot.active_lease_trees == 0 and
        snapshot.active_lease_scopes == 0 and
        snapshot.active_lease_nodes == 0 and
        snapshot.reserved_unmaterialized_allocations == 0 and
        snapshot.live_allocations == 0 and
        snapshot.quiescing_allocations == 0 and
        snapshot.free_authorized_allocations == 0;
}

fn populateBufferAndCacheCleanupV1(
    storage: *ReferenceStorageV1,
    report: *CleanupReportV1,
) void {
    report.candidates_zero = true;
    report.outputs_zero = true;
    report.cache_used_zero = true;
    report.cache_live_allocations = 0;
    for (&storage.runtimes) |*runtime| {
        report.candidates_zero =
            report.candidates_zero and runtimeBuffersZeroV1(runtime);
        report.outputs_zero =
            report.outputs_zero and runtimeOutputZeroV1(runtime);
        const cache = cacheForRuntimeV1(runtime);
        if (!cache.started) continue;
        if (!cache.closed) {
            report.cache_used_zero = false;
            continue;
        }
        report.cache_used_zero = report.cache_used_zero and
            cacheSnapshotHasZeroAuthorityV1(cache.final_snapshot);
        report.cache_live_allocations +=
            @intCast(cache.final_snapshot.live_allocations);
    }
    report.cache_used_zero = report.cache_used_zero and
        report.cache_live_allocations == 0;
}

fn digestIsZero(digest: Digest) bool {
    return std.mem.eql(u8, &digest, &zero_digest);
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.InvalidEvidence;
}

fn hashClaim(hash: anytype, claim: resource_bank.Claim) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        hashU64(hash, @field(claim, field.name));
    }
}

fn hashU64(hash: anytype, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

test "reference campaign completes every perception family transactionally" {
    var storage = try ReferenceStorageV1.init();
    const campaign = try runReferenceCampaignV1(&storage);

    try std.testing.expectEqual(
        contract.planSha256V1(campaign.plan),
        campaign.driver_result.plan_sha256,
    );
    try std.testing.expectEqual(
        @as(u64, reference_item_count),
        campaign.driver_result.summary.attempted,
    );
    try std.testing.expectEqual(
        @as(u64, 5),
        campaign.driver_result.summary.admitted,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        campaign.driver_result.summary.rejected,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        campaign.driver_result.summary.completed,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        campaign.driver_result.summary.cancelled,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        campaign.driver_result.summary.timed_out,
    );
    const expected_outcomes = [_]driver.OutcomeKindV1{
        .cancelled,
        .timed_out,
        .completed,
        .rejected,
        .completed,
        .completed,
    };
    for (
        campaign.driver_result.outcomes,
        expected_outcomes,
    ) |actual, expected| {
        try std.testing.expectEqual(expected, actual.kind);
    }

    try std.testing.expectEqual(
        @as(u64, 1),
        campaign.evidence.summary.vision_completed,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        campaign.evidence.summary.audio_window_completed,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        campaign.evidence.summary.temporal_video_completed,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        campaign.evidence.summary.publications,
    );
    try std.testing.expect(
        campaign.evidence.summary.zero_orphan_ownership,
    );
    try std.testing.expectEqual(
        @as(u64, 15),
        campaign.evidence.summary.cache_successful_commits,
    );
    try std.testing.expectEqual(
        campaign.evidence.summary.cache_successful_commits,
        campaign.evidence.summary.cache_releases,
    );
    try std.testing.expectEqual(
        campaign.driver_result.summary.admitted,
        campaign.driver_result.summary.successful_commits,
    );
    try std.testing.expectEqual(
        campaign.driver_result.summary.admitted,
        campaign.driver_result.summary.releases,
    );
    try std.testing.expect(
        campaign.driver_result.summary.zero_orphan_ownership,
    );
    var expected_trace: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_trace,
        "f65e74a653520e378a96f5f8a99c01ac" ++
            "3f02ac9fa1188943e3d4cc41a60f6ca4",
    );
    var expected_summary: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_summary,
        "9024ea81959bc53db7b789752169e9f6" ++
            "ab15668519311a3cc197557eac3caa72",
    );
    try std.testing.expectEqual(
        expected_trace,
        campaign.driver_result.trace_sha256,
    );
    try std.testing.expectEqual(
        expected_summary,
        campaign.driver_result.summary_sha256,
    );
    try std.testing.expectEqual(
        @as(u64, 5),
        campaign.driver_result.summary.service_quanta,
    );
    try std.testing.expectEqual(
        @as(u64, 5),
        campaign.driver_result.summary.driver_steps,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        campaign.driver_result.summary.maximum_wait_quanta,
    );
    try std.testing.expectEqual(
        @as(u64, 140),
        campaign.driver_result.summary.peak_host_bytes,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        campaign.driver_result.summary.fairness_cross_product_error,
    );
    var plan_storage: [contract.maximum_plan_bytes]u8 = undefined;
    const encoded_plan = try contract.encodePlanV1(
        campaign.plan,
        &plan_storage,
    );
    try std.testing.expectEqual(@as(usize, 3200), encoded_plan.len);
    var plan_wire_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        encoded_plan,
        &plan_wire_sha256,
        .{},
    );
    var expected_plan_wire_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_plan_wire_sha256,
        "66b0dfffc5b7c5fa780aac0da111595e" ++
            "2752aacff13d6f9dc5f68141df9afbad",
    );
    try std.testing.expectEqual(
        expected_plan_wire_sha256,
        plan_wire_sha256,
    );
    var expected_plan_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_plan_root,
        "dea9aa88a3ea6c159989a769dbcf9165" ++
            "9b9aa5d860d9c92155a12487dcd02347",
    );
    var expected_outcome_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_outcome_root,
        "42065963e33f29d088d0ad87933147d6" ++
            "5df7439bdc1740685ef16519a2acaa6f",
    );
    var expected_result_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_result_root,
        "b2fcb522dac425eee47a54697bc2c05d" ++
            "19f88d06cba4c5b0e06f569d3a97cdee",
    );
    var expected_item_section: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_item_section,
        "020b3af8abd9ef97e7d5871d17fb2e51" ++
            "f51d0ec1ce0e49d7e9256b2cf137703a",
    );
    var expected_evidence_summary: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_evidence_summary,
        "a6174f75ae22ec3bec57ee184f69fb11" ++
            "6a6bd57d8c16d487705bc64c78f23660",
    );
    var expected_evidence_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_evidence_root,
        "fcfbacf21be1e549f2402c9bf0a1d7bf" ++
            "94b6252a4a46f6f5ca8f0f6f0d6fe1f2",
    );
    try std.testing.expectEqual(
        expected_plan_root,
        campaign.driver_result.plan_sha256,
    );
    try std.testing.expectEqual(
        expected_outcome_root,
        campaign.driver_result.outcome_sha256,
    );
    try std.testing.expectEqual(
        expected_result_root,
        campaign.driver_result.result_sha256,
    );
    try std.testing.expectEqual(
        expected_item_section,
        campaign.evidence.item_section_sha256,
    );
    try std.testing.expectEqual(
        expected_evidence_summary,
        campaign.evidence.evidence_summary_sha256,
    );
    try std.testing.expectEqual(
        expected_evidence_root,
        campaign.evidence.evidence_sha256,
    );
    var replay_storage: driver.MaximumStorageV1 = .{};
    try validateEvidenceByReplayV1(
        campaign.plan,
        campaign.driver_result,
        campaign.evidence,
        replay_storage.interface(),
    );
}

test "only completed items expose output and rejected work gets no authority" {
    var storage = try ReferenceStorageV1.init();
    const campaign = try runReferenceCampaignV1(&storage);

    for (
        campaign.evidence.items,
        &storage.runtimes,
        &storage.states,
    ) |item, *runtime, state| {
        if (item.outcome == .completed) {
            try std.testing.expect(!digestIsZero(item.output_sha256));
            try std.testing.expect(!runtimeOutputZeroV1(runtime));
            try std.testing.expectEqual(
                @as(u64, 1),
                switch (runtime.*) {
                    .vision => |value| value.fixture.publication_state.visible_results,
                    .audio_window => |value| value.fixture.publication_state.visible_results,
                    .temporal_video => |value| value.fixture.publication_state.visible_results,
                },
            );
        } else {
            try std.testing.expect(digestIsZero(item.output_sha256));
            try std.testing.expect(runtimeOutputZeroV1(runtime));
        }
        if (item.outcome == .rejected) {
            try std.testing.expect(!state.admitted);
            try std.testing.expect(
                receiptEvidenceIsZeroV1(item),
            );
            const cache = cacheForRuntimeV1(runtime);
            try std.testing.expect(!cache.started);
            try std.testing.expect(!cache.restored);
            try std.testing.expect(!cache.closed);
        }
    }
    try std.testing.expectEqual(
        campaign.driver_result.summary.admitted,
        campaign.evidence.summary.cache_restores,
    );
    try std.testing.expectEqual(
        campaign.driver_result.summary.admitted,
        campaign.evidence.summary.cache_closures,
    );
    for (&storage.runtimes) |*runtime| {
        const cache = cacheForRuntimeV1(runtime);
        if (!cache.started) continue;
        try std.testing.expect(cache.closed);
        try std.testing.expect(
            cacheSnapshotHasZeroAuthorityV1(cache.final_snapshot),
        );
    }
}

test "semantic evidence rejects noncompleted output publication" {
    var storage = try ReferenceStorageV1.init();
    const campaign = try runReferenceCampaignV1(&storage);
    var mutated_items: [reference_item_count]ItemEvidenceV1 = undefined;
    @memcpy(&mutated_items, campaign.evidence.items);
    mutated_items[0].output_sha256 =
        expectedOutputSha256V1(.vision);
    mutated_items[0].record_sha256 =
        try itemEvidenceSha256V1(mutated_items[0]);
    var mutated = campaign.evidence;
    mutated.items = &mutated_items;
    mutated.item_section_sha256 =
        itemSectionSha256V1(mutated.items);
    mutated.evidence_sha256 = evidenceSha256V1(mutated);
    try std.testing.expectError(
        error.InvalidEvidence,
        validateEvidenceV1(
            campaign.plan,
            campaign.driver_result,
            mutated,
        ),
    );
}

test "resealed source adapter and result substitutions are rejected" {
    inline for ([_]u8{ 0, 1, 2 }) |mutation| {
        var storage = try ReferenceStorageV1.init();
        const campaign = try runReferenceCampaignV1(&storage);
        var mutated_items: [reference_item_count]ItemEvidenceV1 =
            undefined;
        @memcpy(&mutated_items, campaign.evidence.items);
        switch (mutation) {
            0 => mutated_items[2].source_mapping_sha256[0] ^= 1,
            1 => mutated_items[2].adapter_sha256[0] ^= 1,
            2 => mutated_items[2].result_envelope_sha256[0] ^= 1,
            else => unreachable,
        }
        mutated_items[2].record_sha256 =
            try itemEvidenceSha256V1(mutated_items[2]);
        var mutated = campaign.evidence;
        mutated.items = &mutated_items;
        mutated.item_section_sha256 =
            itemSectionSha256V1(mutated.items);
        mutated.evidence_sha256 = evidenceSha256V1(mutated);
        try std.testing.expectError(
            error.InvalidEvidence,
            validateEvidenceV1(
                campaign.plan,
                campaign.driver_result,
                mutated,
            ),
        );
    }
}

test "prepared storage address and exact reference seal fail before authority" {
    {
        var original = try ReferenceStorageV1.init();
        try original.prepareV1();
        var moved = original;
        try std.testing.expectError(
            error.InvalidExecution,
            runReferenceCampaignV1(&moved),
        );
        for (&moved.runtimes) |*runtime| {
            try std.testing.expect(
                !cacheForRuntimeV1(runtime).started,
            );
        }
    }

    inline for ([_]u8{ 0, 1, 2, 3 }) |mutation| {
        var storage = try ReferenceStorageV1.init();
        try storage.prepareV1();
        switch (mutation) {
            0 => {
                storage.profiles[0].publication_policy =
                    .transactional;
                storage.profiles[0].profile_sha256 =
                    contract.profileSha256V1(storage.profiles[0]);
                for (&storage.items) |*item| {
                    if (item.profile_index != 0) continue;
                    item.profile_sha256 =
                        storage.profiles[0].profile_sha256;
                    item.item_sha256 =
                        contract.itemSha256V1(item.*);
                }
            },
            1 => {
                storage.profiles[1].correctness_sha256[0] ^= 1;
                storage.profiles[1].profile_sha256 =
                    contract.profileSha256V1(storage.profiles[1]);
                for (&storage.items) |*item| {
                    if (item.profile_index != 1) continue;
                    item.profile_sha256 =
                        storage.profiles[1].profile_sha256;
                    item.item_sha256 =
                        contract.itemSha256V1(item.*);
                }
            },
            2 => {
                storage.items[0].input_binding_sha256[0] ^= 1;
                storage.items[0].item_sha256 =
                    contract.itemSha256V1(storage.items[0]);
            },
            3 => {
                storage.items[3].input_binding_sha256[0] ^= 1;
                storage.items[3].item_sha256 =
                    contract.itemSha256V1(storage.items[3]);
            },
            else => unreachable,
        }
        try std.testing.expectError(
            error.InvalidExecution,
            runReferenceCampaignV1(&storage),
        );
        for (&storage.runtimes) |*runtime| {
            try std.testing.expect(
                !cacheForRuntimeV1(runtime).started,
            );
        }
    }
}

test "nested summary substitution cannot bypass the evidence seal" {
    var storage = try ReferenceStorageV1.init();
    const campaign = try runReferenceCampaignV1(&storage);
    var mutated = campaign.evidence;
    mutated.summary.summary_sha256[0] ^= 1;
    try std.testing.expectError(
        error.InvalidEvidence,
        validateEvidenceV1(
            campaign.plan,
            campaign.driver_result,
            mutated,
        ),
    );
}

test "duplicate runtime mutation and completed storage reuse fail preflight" {
    inline for ([_]u8{ 0, 1, 2 }) |mutation| {
        var storage = try ReferenceStorageV1.init();
        try storage.prepareV1();
        switch (mutation) {
            0 => storage.runtimes[3]
                .temporal_video.fixture.weights[0] ^= 1,
            1 => storage.runtimes[3]
                .temporal_video.fixture.cache_bundle
                .restore_owner_key_base += 1,
            2 => storage.runtimes[3]
                .temporal_video.cache.session.phase = .closed,
            else => unreachable,
        }
        try std.testing.expectError(
            error.InvalidExecution,
            runReferenceCampaignV1(&storage),
        );
        for (&storage.runtimes) |*runtime| {
            try std.testing.expect(
                !cacheForRuntimeV1(runtime).started,
            );
        }
    }
    {
        var storage = try ReferenceStorageV1.init();
        _ = try runReferenceCampaignV1(&storage);
        try std.testing.expectError(
            error.InvalidExecution,
            runReferenceCampaignV1(&storage),
        );
        for (&storage.runtimes) |*runtime| {
            const cache = cacheForRuntimeV1(runtime);
            if (!cache.started) continue;
            try std.testing.expect(cache.closed);
            try std.testing.expect(
                cacheSnapshotHasZeroAuthorityV1(
                    cache.final_snapshot,
                ),
            );
        }
    }
}

test "authoritative evidence validation rejects resealed noncanonical result" {
    var storage = try ReferenceStorageV1.init();
    const campaign = try runReferenceCampaignV1(&storage);
    var noncanonical_result = campaign.driver_result;
    noncanonical_result.summary.fairness_cross_product_error += 1;
    noncanonical_result.summary_sha256 =
        driver.summarySha256V1(noncanonical_result.summary);
    noncanonical_result.result_sha256 = driver.resultSha256V1(
        noncanonical_result.plan_sha256,
        noncanonical_result.outcome_sha256,
        noncanonical_result.trace_sha256,
        noncanonical_result.summary_sha256,
    );
    var resealed_evidence = campaign.evidence;
    resealed_evidence.driver_result_sha256 =
        noncanonical_result.result_sha256;
    resealed_evidence.driver_summary_sha256 =
        noncanonical_result.summary_sha256;
    resealed_evidence.evidence_sha256 =
        evidenceSha256V1(resealed_evidence);

    try validateEvidenceV1(
        campaign.plan,
        noncanonical_result,
        resealed_evidence,
    );
    var replay_storage: driver.MaximumStorageV1 = .{};
    try std.testing.expectError(
        error.InvalidEvidence,
        validateEvidenceByReplayV1(
            campaign.plan,
            noncanonical_result,
            resealed_evidence,
            replay_storage.interface(),
        ),
    );
}

test "injected prepare candidate and arm failures leave no ownership" {
    inline for ([_]FailureInjectionV1{
        .after_prepare,
        .candidate_drift,
        .after_arm,
    }) |injection| {
        var storage = try ReferenceStorageV1.init();
        try std.testing.expectError(
            error.InjectedFailure,
            runReferenceCampaignWithFailureV1(
                &storage,
                injection,
            ),
        );
        const report = storage.cleanup_report;
        try std.testing.expect(report.invoked);
        try std.testing.expect(report.candidates_zero);
        try std.testing.expect(report.outputs_zero);
        try std.testing.expect(report.model_used_zero);
        try std.testing.expectEqual(
            @as(u64, 0),
            report.model_active_reservations,
        );
        try std.testing.expectEqual(
            @as(u64, 0),
            report.model_committed_receipts,
        );
        try std.testing.expect(report.cache_used_zero);
        try std.testing.expectEqual(
            @as(u64, 0),
            report.cache_live_allocations,
        );
    }
}

pub fn referencePlanV1(
    profiles: []const contract.ProfileV1,
    items: []const contract.ItemV1,
) contract.PlanV1 {
    return .{
        .seed = 0x4757_5043_0000_0001,
        .capacity = reference_capacity,
        .max_driver_steps = 32,
        .max_service_quanta = 32,
        .fairness_start_tick = 0,
        .fairness_end_tick = 16,
        .bank_epoch = 0x4757_5043_424b_0001,
        .scheduler_epoch = 0x4757_5043_5343_0001,
        .max_weight = 1,
        .max_projection_quanta = 64,
        .max_projection_operations = 256,
        .limits = .{
            .host_bytes = 1024 * 1024,
            .capsule_bytes = 1024 * 1024,
            .kv_bytes = 1024 * 1024,
            .activation_bytes = 1024 * 1024,
            .partial_bytes = 1024 * 1024,
            .logits_bytes = 1024 * 1024,
            .output_journal_bytes = 1024 * 1024,
            .staging_bytes = 1024 * 1024,
            .device_bytes = 1024 * 1024,
            .io_bytes = 1024 * 1024,
            .queue_slots = reference_capacity,
        },
        .challenge = model.sha256("typed perception reference campaign v1"),
        .profiles = profiles,
        .items = items,
    };
}
