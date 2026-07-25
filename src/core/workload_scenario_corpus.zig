//! Generated deterministic workload corpus and failure-preserving shrinker.
//!
//! This additive W2 module produces unchanged WorkloadPressure V1 scenarios.
//! Logical driver steps and service quanta remain deterministic conformance
//! units; this module performs no ambient timing, random-system access, model
//! loading, filesystem or network I/O, device work, heap allocation, or thread
//! creation.

const std = @import("std");
const media = @import("media_contract.zig");
const qos = @import("lane_weave_qos.zig");
const resource_bank = @import("resource_bank.zig");
const workload = @import("workload_pressure.zig");
const scheduled = @import("scheduled_media_pressure.zig");

pub const Digest = workload.Digest;
pub const zero_digest = workload.zero_digest;

pub const generator_abi: u64 = 0x4757_4347_0000_0001;
pub const shrinker_abi: u64 = 0x4757_4353_0000_0001;
pub const corpus_abi: u64 = 0x4757_4343_0000_0001;
pub const coverage_abi: u64 = 0x4757_4356_0000_0001;
pub const failure_abi: u64 = 0x4757_4346_0000_0001;

pub const maximum_corpus_cases: usize = 64;
pub const maximum_shrink_evaluations: u64 = 4096;
pub const retained_seed_count: usize = 4;
pub const class_count: usize = 8;
pub const retained_case_count: usize = retained_seed_count * class_count;

pub const retained_seeds = [retained_seed_count]u64{
    0x4757_4332_2026_0001,
    0x4757_4332_2026_0002,
    0x4757_4332_2026_0003,
    0x4757_4332_2026_0004,
};

pub const decision_domain =
    "glacier-workload-scenario-corpus-decision-v1\x00";
pub const case_domain = "glacier-workload-scenario-case-v1\x00";
pub const corpus_domain = "glacier-workload-scenario-corpus-v1\x00";
pub const failure_domain = "glacier-workload-failure-signature-v1\x00";
const synthetic_failure_domain =
    "glacier-workload-synthetic-turnover-v1\x00";

pub const ScenarioClassV1 = enum(u64) {
    fairness = 1,
    no_slot = 2,
    resource_limit = 3,
    cancel_turnover = 4,
    timeout_turnover = 5,
    deadline_feasible = 6,
    deadline_infeasible = 7,
    projection_limit = 8,
};

pub const DecisionTagV1 = enum(u64) {
    scenario_seed = 1,
    bank_epoch = 2,
    scheduler_epoch = 3,
    challenge = 4,
    modality_rotation = 5,
};

pub const CoverageV1 = struct {
    pub const completed: u64 = 1 << 0;
    pub const cancelled: u64 = 1 << 1;
    pub const timed_out: u64 = 1 << 2;
    pub const rejected_no_slot: u64 = 1 << 3;
    pub const rejected_resource_limit: u64 = 1 << 4;
    pub const rejected_projection_limit: u64 = 1 << 5;
    pub const rejected_deadline_infeasible: u64 = 1 << 6;
    pub const image_profile: u64 = 1 << 7;
    pub const audio_profile: u64 = 1 << 8;
    pub const video_profile: u64 = 1 << 9;
    pub const completed_deadline: u64 = 1 << 10;
    pub const weighted_fairness: u64 = 1 << 11;
    pub const staggered_arrivals: u64 = 1 << 12;
    pub const terminal_after_service: u64 = 1 << 13;
    pub const zero_orphan_ownership: u64 = 1 << 14;
};

pub const mandatory_coverage_bits: u64 = 0x7fff;

pub const Error = workload.Error || scheduled.Error || error{
    InvalidCaseIndex,
    InvalidCorpus,
    InvalidEvaluationBudget,
    FailureNotInteresting,
    FailureSignatureMismatch,
    UnstableFailure,
    EvaluationBudgetExhausted,
};

/// Owns item storage without retaining a self-referential slice. Call
/// `scenario()` only after the owner has reached its final address.
pub const OwnedScenarioV1 = struct {
    seed: u64,
    max_driver_steps: u64,
    fairness_start_tick: u64,
    fairness_end_tick: u64,
    bank_epoch: u64,
    scheduler_epoch: u64,
    max_weight: u16,
    max_projection_quanta: u64,
    max_projection_operations: u64,
    capacity: u32,
    limits: resource_bank.Limits,
    challenge: Digest,
    item_count: u8,
    items: [workload.maximum_items]workload.WorkItemV1,

    pub fn scenario(self: *const OwnedScenarioV1) workload.ScenarioV1 {
        const count: usize = self.item_count;
        return .{
            .seed = self.seed,
            .max_driver_steps = self.max_driver_steps,
            .fairness_start_tick = self.fairness_start_tick,
            .fairness_end_tick = self.fairness_end_tick,
            .bank_epoch = self.bank_epoch,
            .scheduler_epoch = self.scheduler_epoch,
            .max_weight = self.max_weight,
            .max_projection_quanta = self.max_projection_quanta,
            .max_projection_operations = self.max_projection_operations,
            .capacity = self.capacity,
            .limits = self.limits,
            .challenge = self.challenge,
            .items = self.items[0..count],
        };
    }
};

pub fn copyScenarioV1(
    scenario: workload.ScenarioV1,
    output: *OwnedScenarioV1,
) Error!void {
    try workload.validateScenarioV1(scenario);
    var value: OwnedScenarioV1 = .{
        .seed = scenario.seed,
        .max_driver_steps = scenario.max_driver_steps,
        .fairness_start_tick = scenario.fairness_start_tick,
        .fairness_end_tick = scenario.fairness_end_tick,
        .bank_epoch = scenario.bank_epoch,
        .scheduler_epoch = scenario.scheduler_epoch,
        .max_weight = scenario.max_weight,
        .max_projection_quanta = scenario.max_projection_quanta,
        .max_projection_operations = scenario.max_projection_operations,
        .capacity = scenario.capacity,
        .limits = scenario.limits,
        .challenge = scenario.challenge,
        .item_count = @intCast(scenario.items.len),
        .items = undefined,
    };
    @memcpy(value.items[0..scenario.items.len], scenario.items);
    output.* = value;
}

/// Normative decision address:
/// domain || LE64(generator ABI, seed, case index, class, tag, ordinal).
pub fn decisionDigestV1(
    seed: u64,
    case_index: u64,
    scenario_class: ScenarioClassV1,
    tag: DecisionTagV1,
    ordinal: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(decision_domain);
    hashU64(&hash, generator_abi);
    hashU64(&hash, seed);
    hashU64(&hash, case_index);
    hashU64(&hash, @intFromEnum(scenario_class));
    hashU64(&hash, @intFromEnum(tag));
    hashU64(&hash, ordinal);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn decisionU64V1(
    seed: u64,
    case_index: u64,
    scenario_class: ScenarioClassV1,
    tag: DecisionTagV1,
    ordinal: u64,
) u64 {
    const digest = decisionDigestV1(
        seed,
        case_index,
        scenario_class,
        tag,
        ordinal,
    );
    return std.mem.readInt(u64, digest[0..8], .little);
}

pub fn classNameV1(scenario_class: ScenarioClassV1) []const u8 {
    return switch (scenario_class) {
        .fairness => "fairness",
        .no_slot => "no_slot",
        .resource_limit => "resource_limit",
        .cancel_turnover => "cancel_turnover",
        .timeout_turnover => "timeout_turnover",
        .deadline_feasible => "deadline_feasible",
        .deadline_infeasible => "deadline_infeasible",
        .projection_limit => "projection_limit",
    };
}

pub fn retainedSeedIndexV1(case_index: usize) Error!usize {
    if (case_index >= retained_case_count) return Error.InvalidCaseIndex;
    return case_index / class_count;
}

pub fn classForRetainedCaseV1(
    case_index: usize,
) Error!ScenarioClassV1 {
    if (case_index >= retained_case_count) return Error.InvalidCaseIndex;
    return @enumFromInt((case_index % class_count) + 1);
}

pub fn generateRetainedCaseV1(
    case_index: usize,
    output: *OwnedScenarioV1,
) Error!void {
    const seed_index = try retainedSeedIndexV1(case_index);
    return generateCaseV1(
        retained_seeds[seed_index],
        case_index,
        try classForRetainedCaseV1(case_index),
        output,
    );
}

pub fn generateCaseV1(
    seed: u64,
    case_index: usize,
    scenario_class: ScenarioClassV1,
    output: *OwnedScenarioV1,
) Error!void {
    if (seed == 0 or case_index >= maximum_corpus_cases)
        return Error.InvalidCaseIndex;
    const case_u64: u64 = @intCast(case_index);
    const absent = workload.absent_step;
    const rotation = decisionU64V1(
        seed,
        case_u64,
        scenario_class,
        .modality_rotation,
        workload.absent_item,
    ) % 3;
    var challenge = decisionDigestV1(
        seed,
        case_u64,
        scenario_class,
        .challenge,
        workload.absent_item,
    );
    if (std.mem.eql(u8, &challenge, &zero_digest)) challenge[0] = 1;

    var value: OwnedScenarioV1 = .{
        .seed = nonzeroV1(decisionU64V1(
            seed,
            case_u64,
            scenario_class,
            .scenario_seed,
            workload.absent_item,
        )),
        .max_driver_steps = 64,
        .fairness_start_tick = 0,
        .fairness_end_tick = if (scenario_class == .fairness) 7 else 8,
        .bank_epoch = nonzeroV1(decisionU64V1(
            seed,
            case_u64,
            scenario_class,
            .bank_epoch,
            workload.absent_item,
        )),
        .scheduler_epoch = nonzeroV1(decisionU64V1(
            seed,
            case_u64,
            scenario_class,
            .scheduler_epoch,
            workload.absent_item,
        )),
        .max_weight = 4,
        .max_projection_quanta = 256,
        .max_projection_operations = if (scenario_class == .projection_limit) 1 else 4096,
        .capacity = 1,
        .limits = .{},
        .challenge = challenge,
        .item_count = 0,
        .items = undefined,
    };

    switch (scenario_class) {
        .fairness => {
            value.item_count = 3;
            value.capacity = 3;
            value.items[0] = generatedItem(
                case_index,
                rotation,
                0,
                0,
                1,
                4,
                0,
                absent,
                .none,
            );
            value.items[1] = generatedItem(
                case_index,
                rotation,
                1,
                0,
                2,
                4,
                0,
                absent,
                .none,
            );
            value.items[2] = generatedItem(
                case_index,
                rotation,
                2,
                0,
                4,
                4,
                0,
                absent,
                .none,
            );
        },
        .no_slot => {
            value.item_count = 4;
            value.capacity = 2;
            inline for (0..4) |index| {
                value.items[index] = generatedItem(
                    case_index,
                    rotation,
                    index,
                    0,
                    if (index % 2 == 0) 1 else 2,
                    2,
                    0,
                    absent,
                    .none,
                );
            }
        },
        .resource_limit => {
            value.item_count = 3;
            value.capacity = 2;
            inline for (0..3) |index| {
                value.items[index] = generatedItem(
                    case_index,
                    rotation,
                    index,
                    0,
                    1,
                    2,
                    0,
                    absent,
                    .none,
                );
            }
        },
        .cancel_turnover => {
            value.item_count = 2;
            value.capacity = 1;
            value.items[0] = generatedItem(
                case_index,
                rotation,
                0,
                0,
                1,
                4,
                0,
                1,
                .cancel,
            );
            value.items[1] = generatedItem(
                case_index,
                rotation,
                1,
                2,
                1,
                2,
                0,
                absent,
                .none,
            );
        },
        .timeout_turnover => {
            value.item_count = 2;
            value.capacity = 1;
            value.items[0] = generatedItem(
                case_index,
                rotation,
                0,
                0,
                1,
                4,
                0,
                2,
                .timeout,
            );
            value.items[1] = generatedItem(
                case_index,
                rotation,
                1,
                3,
                1,
                2,
                0,
                absent,
                .none,
            );
        },
        .deadline_feasible => {
            value.item_count = 2;
            value.capacity = 1;
            value.items[0] = generatedItem(
                case_index,
                rotation,
                0,
                0,
                1,
                3,
                3,
                absent,
                .none,
            );
            value.items[1] = generatedItem(
                case_index,
                rotation,
                1,
                3,
                1,
                2,
                5,
                absent,
                .none,
            );
        },
        .deadline_infeasible => {
            value.item_count = 2;
            value.capacity = 1;
            value.items[0] = generatedItem(
                case_index,
                rotation,
                0,
                0,
                1,
                3,
                2,
                absent,
                .none,
            );
            value.items[1] = generatedItem(
                case_index,
                rotation,
                1,
                1,
                1,
                1,
                0,
                absent,
                .none,
            );
        },
        .projection_limit => {
            value.item_count = 2;
            value.capacity = 2;
            inline for (0..2) |index| {
                value.items[index] = generatedItem(
                    case_index,
                    rotation,
                    index,
                    0,
                    1,
                    2,
                    8,
                    absent,
                    .none,
                );
            }
        },
    }

    const item_count: usize = value.item_count;
    value.limits = .{
        .host_bytes = try hostLimitV1(
            scenario_class,
            value.items[0..item_count],
        ),
        .queue_slots = value.capacity,
    };
    try workload.validateScenarioV1(value.scenario());
    output.* = value;
}

fn generatedItem(
    case_index: usize,
    rotation: u64,
    ordinal: usize,
    arrival_step: u64,
    weight: u16,
    work_quanta: u64,
    deadline_tick: u64,
    action_step: u64,
    action: workload.TerminalActionV1,
) workload.WorkItemV1 {
    const ordinal_u64: u64 = @intCast(ordinal);
    const identity = 1 + @as(u64, @intCast(case_index)) *
        workload.maximum_items + ordinal_u64;
    return workload.makeWorkItemV1(ordinal_u64, .{
        .media_kind = rotatedKindV1(rotation, ordinal_u64),
        .arrival_step = arrival_step,
        .weight = weight,
        .work_quanta = work_quanta,
        .deadline_tick = deadline_tick,
        .terminal_action_step = action_step,
        .terminal_action = action,
        .fairness_member = true,
        .identity = .{
            .tenant_key = 0x1000_0000_0000_0000 | identity,
            .request_key = 0x2000_0000_0000_0000 | identity,
            .request_generation = 1,
            .resource_owner_key = 0x3000_0000_0000_0000 | identity,
        },
    });
}

fn rotatedKindV1(rotation: u64, ordinal: u64) media.MediaKindV1 {
    return switch ((rotation + ordinal) % 3) {
        0 => .image,
        1 => .audio,
        2 => .video,
        else => unreachable,
    };
}

fn hostLimitV1(
    scenario_class: ScenarioClassV1,
    items: []const workload.WorkItemV1,
) Error!u64 {
    return switch (scenario_class) {
        .fairness, .projection_limit => sumHostClaims(items),
        .no_slot => sumHostClaims(items[0..2]),
        .resource_limit => items[0].claim.hostBytes(),
        .cancel_turnover,
        .timeout_turnover,
        .deadline_feasible,
        .deadline_infeasible,
        => @max(
            try items[0].claim.hostBytes(),
            try items[1].claim.hostBytes(),
        ),
    };
}

fn sumHostClaims(items: []const workload.WorkItemV1) Error!u64 {
    var total: u64 = 0;
    for (items) |item| {
        total = std.math.add(
            u64,
            total,
            try item.claim.hostBytes(),
        ) catch return error.ArithmeticOverflow;
    }
    return total;
}

pub fn coverageBitsV1(
    scenario: workload.ScenarioV1,
    result: workload.ResultV1,
) Error!u64 {
    try workload.validateResultAgainstScenarioV1(scenario, result);
    var bits: u64 = 0;
    var weighted_member: ?u16 = null;
    var distinct_fairness_weight = false;
    var first_arrival: ?u64 = null;

    for (scenario.items) |item| {
        switch (item.media_kind) {
            .image => bits |= CoverageV1.image_profile,
            .audio => bits |= CoverageV1.audio_profile,
            .video => bits |= CoverageV1.video_profile,
        }
        if (item.fairness_member) {
            if (weighted_member) |weight| {
                if (weight != item.weight) distinct_fairness_weight = true;
            } else {
                weighted_member = item.weight;
            }
        }
        if (first_arrival) |arrival| {
            if (arrival != item.arrival_step)
                bits |= CoverageV1.staggered_arrivals;
        } else {
            first_arrival = item.arrival_step;
        }
    }

    for (scenario.items, result.outcomes) |item, outcome| {
        switch (outcome.kind) {
            .completed => {
                bits |= CoverageV1.completed;
                if (item.deadline_tick != 0)
                    bits |= CoverageV1.completed_deadline;
            },
            .cancelled => bits |= CoverageV1.cancelled,
            .timed_out => bits |= CoverageV1.timed_out,
            .rejected => switch (outcome.rejection_reason) {
                .no_slot => bits |= CoverageV1.rejected_no_slot,
                .resource_limit => bits |= CoverageV1.rejected_resource_limit,
                .projection_limit => bits |= CoverageV1.rejected_projection_limit,
                .deadline_infeasible => bits |= CoverageV1.rejected_deadline_infeasible,
                else => {},
            },
        }
        if ((outcome.kind == .cancelled or outcome.kind == .timed_out) and
            outcome.served_quanta != 0)
            bits |= CoverageV1.terminal_after_service;
    }
    if (distinct_fairness_weight and
        result.summary.fairness_cross_product_error == 0)
        bits |= CoverageV1.weighted_fairness;
    if (result.summary.zero_orphan_ownership)
        bits |= CoverageV1.zero_orphan_ownership;
    return bits;
}

pub const CaseEvidenceV1 = struct {
    seed: u64,
    case_index: u64,
    scenario_class: ScenarioClassV1,
    item_count: u64,
    coverage_bits: u64,
    admitted: u64,
    rejected: u64,
    completed: u64,
    cancelled: u64,
    timed_out: u64,
    service_quanta: u64,
    driver_steps: u64,
    publications: u64,
    closed_terminal_sessions: u64,
    zero_orphan_ownership: bool,
    scenario_sha256: Digest,
    outcome_sha256: Digest,
    trace_sha256: Digest,
    summary_sha256: Digest,
    scheduled_evidence_sha256: Digest,
    case_sha256: Digest,
};

pub const RetainedCorpusV1 = struct {
    cases: [retained_case_count]CaseEvidenceV1,
    coverage_bits: u64,
    item_count: u64,
    admitted: u64,
    rejected: u64,
    completed: u64,
    cancelled: u64,
    timed_out: u64,
    service_quanta: u64,
    driver_steps: u64,
    publications: u64,
    closed_terminal_sessions: u64,
    zero_orphan_ownership: bool,
    corpus_sha256: Digest,
};

pub fn runRetainedCorpusV1(output: *RetainedCorpusV1) Error!void {
    var corpus: RetainedCorpusV1 = undefined;
    corpus.coverage_bits = 0;
    corpus.item_count = 0;
    corpus.admitted = 0;
    corpus.rejected = 0;
    corpus.completed = 0;
    corpus.cancelled = 0;
    corpus.timed_out = 0;
    corpus.service_quanta = 0;
    corpus.driver_steps = 0;
    corpus.publications = 0;
    corpus.closed_terminal_sessions = 0;
    corpus.zero_orphan_ownership = true;

    for (0..retained_case_count) |case_index| {
        var owned: OwnedScenarioV1 = undefined;
        try generateRetainedCaseV1(case_index, &owned);
        const seed_index = try retainedSeedIndexV1(case_index);
        corpus.cases[case_index] = try executeCaseV1(
            retained_seeds[seed_index],
            case_index,
            try classForRetainedCaseV1(case_index),
            &owned,
        );
        const evidence = corpus.cases[case_index];
        corpus.coverage_bits |= evidence.coverage_bits;
        corpus.item_count += evidence.item_count;
        corpus.admitted += evidence.admitted;
        corpus.rejected += evidence.rejected;
        corpus.completed += evidence.completed;
        corpus.cancelled += evidence.cancelled;
        corpus.timed_out += evidence.timed_out;
        corpus.service_quanta += evidence.service_quanta;
        corpus.driver_steps += evidence.driver_steps;
        corpus.publications += evidence.publications;
        corpus.closed_terminal_sessions += evidence.closed_terminal_sessions;
        corpus.zero_orphan_ownership =
            corpus.zero_orphan_ownership and
            evidence.zero_orphan_ownership;
    }
    if (corpus.coverage_bits != mandatory_coverage_bits or
        corpus.item_count != 80 or
        corpus.admitted != 52 or
        corpus.rejected != 28 or
        corpus.completed != 44 or
        corpus.cancelled != 4 or
        corpus.timed_out != 4 or
        corpus.service_quanta != 124 or
        corpus.driver_steps != 140 or
        corpus.publications != 44 or
        corpus.closed_terminal_sessions != 52 or
        !corpus.zero_orphan_ownership)
        return Error.InvalidCorpus;
    corpus.corpus_sha256 = corpusRootV1(corpus);
    output.* = corpus;
}

pub fn executeCaseV1(
    seed: u64,
    case_index: usize,
    scenario_class: ScenarioClassV1,
    owned: *const OwnedScenarioV1,
) Error!CaseEvidenceV1 {
    const scenario = owned.scenario();
    try workload.validateScenarioV1(scenario);
    var expected_owned: OwnedScenarioV1 = undefined;
    try generateCaseV1(
        seed,
        case_index,
        scenario_class,
        &expected_owned,
    );
    const actual_scenario_root = try workload.scenarioSha256V1(scenario);
    const expected_scenario_root = try workload.scenarioSha256V1(
        expected_owned.scenario(),
    );
    if (!std.mem.eql(
        u8,
        &actual_scenario_root,
        &expected_scenario_root,
    )) return Error.InvalidCorpus;

    var workload_storage: workload.MaximumStorageV1 = .{};
    const result = try workload.runScenarioV1(
        scenario,
        workload_storage.interface(),
    );
    var replay_storage: workload.MaximumStorageV1 = .{};
    try workload.validateResultByReplayV1(
        scenario,
        result,
        replay_storage.interface(),
    );

    var scheduled_storage: scheduled.MaximumStorageV1 = .{};
    const campaign = try scheduled.runScenarioV1(
        scenario,
        scheduled_storage.interface(),
    );
    if (!std.meta.eql(campaign.workload_result.summary, result.summary) or
        !std.mem.eql(
            u8,
            &campaign.workload_result.scenario_sha256,
            &result.scenario_sha256,
        ) or
        !std.mem.eql(
            u8,
            &campaign.workload_result.outcome_sha256,
            &result.outcome_sha256,
        ) or
        !std.mem.eql(
            u8,
            &campaign.workload_result.trace_sha256,
            &result.trace_sha256,
        ) or
        !std.mem.eql(
            u8,
            &campaign.workload_result.summary_sha256,
            &result.summary_sha256,
        ) or
        campaign.evidence.summary.publications != result.summary.completed or
        campaign.evidence.summary.closed_terminal_sessions !=
            result.summary.admitted or
        !campaign.evidence.summary.zero_orphan_ownership)
        return Error.InvalidCorpus;

    var evidence: CaseEvidenceV1 = .{
        .seed = seed,
        .case_index = @intCast(case_index),
        .scenario_class = scenario_class,
        .item_count = @intCast(scenario.items.len),
        .coverage_bits = try coverageBitsV1(scenario, result),
        .admitted = result.summary.admitted,
        .rejected = result.summary.rejected,
        .completed = result.summary.completed,
        .cancelled = result.summary.cancelled,
        .timed_out = result.summary.timed_out,
        .service_quanta = result.summary.service_quanta,
        .driver_steps = result.summary.driver_steps,
        .publications = campaign.evidence.summary.publications,
        .closed_terminal_sessions = campaign.evidence.summary.closed_terminal_sessions,
        .zero_orphan_ownership = campaign.evidence.summary.zero_orphan_ownership and
            result.summary.zero_orphan_ownership,
        .scenario_sha256 = result.scenario_sha256,
        .outcome_sha256 = result.outcome_sha256,
        .trace_sha256 = result.trace_sha256,
        .summary_sha256 = result.summary_sha256,
        .scheduled_evidence_sha256 = campaign.evidence.evidence_sha256,
        .case_sha256 = undefined,
    };
    evidence.case_sha256 = caseRootV1(evidence);
    return evidence;
}

pub fn caseRootV1(evidence: CaseEvidenceV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(case_domain);
    hashU64(&hash, corpus_abi);
    hashU64(&hash, generator_abi);
    hashU64(&hash, coverage_abi);
    hashU64(&hash, evidence.seed);
    hashU64(&hash, evidence.case_index);
    hashU64(&hash, @intFromEnum(evidence.scenario_class));
    hashU64(&hash, evidence.coverage_bits);
    hashU64(&hash, evidence.item_count);
    hashU64(&hash, evidence.admitted);
    hashU64(&hash, evidence.rejected);
    hashU64(&hash, evidence.completed);
    hashU64(&hash, evidence.cancelled);
    hashU64(&hash, evidence.timed_out);
    hashU64(&hash, evidence.service_quanta);
    hashU64(&hash, evidence.driver_steps);
    hashU64(&hash, evidence.publications);
    hashU64(&hash, evidence.closed_terminal_sessions);
    hashU64(&hash, @intFromBool(evidence.zero_orphan_ownership));
    hash.update(&evidence.scenario_sha256);
    hash.update(&evidence.outcome_sha256);
    hash.update(&evidence.trace_sha256);
    hash.update(&evidence.summary_sha256);
    hash.update(&evidence.scheduled_evidence_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Recomputes every child root so stale cached `case_sha256` values cannot
/// detach case metadata from the corpus commitment.
pub fn corpusRootV1(corpus: RetainedCorpusV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(corpus_domain);
    hashU64(&hash, corpus_abi);
    hashU64(&hash, generator_abi);
    hashU64(&hash, coverage_abi);
    hashU64(&hash, retained_seed_count);
    hashU64(&hash, class_count);
    hashU64(&hash, retained_case_count);
    hashU64(&hash, corpus.coverage_bits);
    hashU64(&hash, corpus.item_count);
    hashU64(&hash, corpus.admitted);
    hashU64(&hash, corpus.rejected);
    hashU64(&hash, corpus.completed);
    hashU64(&hash, corpus.cancelled);
    hashU64(&hash, corpus.timed_out);
    hashU64(&hash, corpus.service_quanta);
    hashU64(&hash, corpus.driver_steps);
    hashU64(&hash, corpus.publications);
    hashU64(&hash, corpus.closed_terminal_sessions);
    hashU64(&hash, @intFromBool(corpus.zero_orphan_ownership));
    for (corpus.cases) |case| {
        const child_root = caseRootV1(case);
        hash.update(&child_root);
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub const FailureStageV1 = enum(u64) {
    synthetic_shrinker_conformance = 1,
    scenario_generation = 2,
    scenario_wire = 3,
    workload_replay = 4,
    result_mismatch = 5,
    scheduled_media_mismatch = 6,
    invariant_violation = 7,
};

pub const FailureSignatureV1 = struct {
    stage: FailureStageV1,
    code: u64,
    fingerprint: Digest,
};

pub fn failureSignatureSha256V1(
    signature: FailureSignatureV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(failure_domain);
    hashU64(&hash, failure_abi);
    hashU64(&hash, @intFromEnum(signature.stage));
    hashU64(&hash, signature.code);
    hash.update(&signature.fingerprint);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub const FailureProbeV1 = struct {
    context: ?*anyopaque = null,
    evaluate_fn: *const fn (
        context: ?*anyopaque,
        scenario: workload.ScenarioV1,
        result: workload.ResultV1,
    ) ?FailureSignatureV1,

    pub fn evaluate(
        self: FailureProbeV1,
        scenario: workload.ScenarioV1,
        result: workload.ResultV1,
    ) ?FailureSignatureV1 {
        return self.evaluate_fn(self.context, scenario, result);
    }
};

/// Versioned lexicographic measure used by every accepted V1 reduction.
pub const ComplexityV1 = struct {
    item_count: u64,
    terminal_actions: u64,
    total_work_quanta: u64,
    total_arrival_steps: u64,
    total_action_distance: u64,
    deadline_count: u64,
    total_deadline_ticks: u64,
    total_weight: u64,
    total_media_rank: u64,
    capacity: u64,
    host_limit: u64,
    max_driver_steps: u64,
    max_projection_operations: u64,
    fairness_end_tick: u64,

    pub fn lessThan(left: ComplexityV1, right: ComplexityV1) bool {
        const left_values = left.values();
        const right_values = right.values();
        for (left_values, right_values) |left_value, right_value| {
            if (left_value < right_value) return true;
            if (left_value > right_value) return false;
        }
        return false;
    }

    pub fn orderedValues(self: ComplexityV1) [14]u64 {
        return .{
            self.item_count,
            self.terminal_actions,
            self.total_work_quanta,
            self.total_arrival_steps,
            self.total_action_distance,
            self.deadline_count,
            self.total_deadline_ticks,
            self.total_weight,
            self.total_media_rank,
            self.capacity,
            self.host_limit,
            self.max_driver_steps,
            self.max_projection_operations,
            self.fairness_end_tick,
        };
    }

    fn values(self: ComplexityV1) [14]u64 {
        return self.orderedValues();
    }
};

pub fn complexityV1(
    owned: *const OwnedScenarioV1,
) Error!ComplexityV1 {
    const scenario = owned.scenario();
    try workload.validateScenarioV1(scenario);
    var value: ComplexityV1 = .{
        .item_count = @intCast(scenario.items.len),
        .terminal_actions = 0,
        .total_work_quanta = 0,
        .total_arrival_steps = 0,
        .total_action_distance = 0,
        .deadline_count = 0,
        .total_deadline_ticks = 0,
        .total_weight = 0,
        .total_media_rank = 0,
        .capacity = scenario.capacity,
        .host_limit = scenario.limits.host_bytes,
        .max_driver_steps = scenario.max_driver_steps,
        .max_projection_operations = scenario.max_projection_operations,
        .fairness_end_tick = scenario.fairness_end_tick,
    };
    for (scenario.items) |item| {
        value.total_work_quanta = try addU64(
            value.total_work_quanta,
            item.work_quanta,
        );
        value.total_arrival_steps = try addU64(
            value.total_arrival_steps,
            item.arrival_step,
        );
        value.total_weight = try addU64(value.total_weight, item.weight);
        value.total_media_rank = try addU64(
            value.total_media_rank,
            @intFromEnum(item.media_kind),
        );
        if (item.terminal_action != .none) {
            value.terminal_actions += 1;
            value.total_action_distance = try addU64(
                value.total_action_distance,
                try addU64(
                    item.terminal_action_step - item.arrival_step,
                    1,
                ),
            );
        }
        if (item.deadline_tick != 0) {
            value.deadline_count += 1;
            value.total_deadline_ticks = try addU64(
                value.total_deadline_ticks,
                item.deadline_tick,
            );
        }
    }
    return value;
}

pub const ShrinkResultV1 = struct {
    scenario: OwnedScenarioV1,
    original_scenario_sha256: Digest,
    minimized_scenario_sha256: Digest,
    failure_signature_sha256: Digest,
    evaluations: u64,
    reductions: u64,
    budget_exhausted: bool,
    locally_minimal: bool,
};

const ObservationV1 = union(enum) {
    invalid,
    budget,
    absent,
    present: FailureSignatureV1,
};

const CandidateDecisionV1 = enum {
    rejected,
    accepted,
    budget,
};

const PassResultV1 = enum {
    no_change,
    accepted,
    budget,
};

const ShrinkContextV1 = struct {
    expected: FailureSignatureV1,
    probe: FailureProbeV1,
    evaluation_budget: u64,
    evaluations: u64 = 0,

    fn observe(
        self: *ShrinkContextV1,
        candidate: *const OwnedScenarioV1,
    ) Error!ObservationV1 {
        const scenario = candidate.scenario();
        workload.validateScenarioV1(scenario) catch
            return .invalid;
        var execution_storage: workload.MaximumStorageV1 = .{};
        const result = workload.runScenarioV1(
            scenario,
            execution_storage.interface(),
        ) catch return .invalid;
        var replay_storage: workload.MaximumStorageV1 = .{};
        workload.validateResultByReplayV1(
            scenario,
            result,
            replay_storage.interface(),
        ) catch return .invalid;
        if (self.evaluations + 2 > self.evaluation_budget)
            return .budget;
        const first = self.probe.evaluate(scenario, result);
        self.evaluations += 1;
        const second = self.probe.evaluate(scenario, result);
        self.evaluations += 1;
        if ((first == null) != (second == null))
            return Error.UnstableFailure;
        if (first == null) return .absent;
        if (!std.meta.eql(first.?, second.?))
            return Error.UnstableFailure;
        return .{ .present = first.? };
    }

    fn consider(
        self: *ShrinkContextV1,
        current: *OwnedScenarioV1,
        candidate: *const OwnedScenarioV1,
    ) Error!CandidateDecisionV1 {
        const candidate_complexity = complexityV1(candidate) catch
            return .rejected;
        const current_complexity = try complexityV1(current);
        if (!candidate_complexity.lessThan(current_complexity))
            return .rejected;
        return switch (try self.observe(candidate)) {
            .invalid, .absent => .rejected,
            .budget => .budget,
            .present => |signature| if (std.meta.eql(
                signature,
                self.expected,
            )) blk: {
                current.* = candidate.*;
                break :blk .accepted;
            } else .rejected,
        };
    }
};

pub fn shrinkFailureV1(
    initial: *const OwnedScenarioV1,
    expected: FailureSignatureV1,
    probe: FailureProbeV1,
    evaluation_budget: u64,
    output: *ShrinkResultV1,
) Error!void {
    if (evaluation_budget < 2 or
        evaluation_budget > maximum_shrink_evaluations or
        evaluation_budget % 2 != 0)
        return Error.InvalidEvaluationBudget;

    var current: OwnedScenarioV1 = undefined;
    try copyScenarioV1(initial.scenario(), &current);
    const original_root = try workload.scenarioSha256V1(current.scenario());
    var context: ShrinkContextV1 = .{
        .expected = expected,
        .probe = probe,
        .evaluation_budget = evaluation_budget,
    };
    switch (try context.observe(&current)) {
        .invalid, .absent => return Error.FailureNotInteresting,
        .budget => return Error.EvaluationBudgetExhausted,
        .present => |signature| {
            if (!std.meta.eql(signature, expected))
                return Error.FailureSignatureMismatch;
        },
    }

    var reductions: u64 = 0;
    while (true) {
        switch (try reduceOnePassV1(&current, &context)) {
            .accepted => reductions += 1,
            .budget => return Error.EvaluationBudgetExhausted,
            .no_change => break,
        }
    }
    const minimized_root = try workload.scenarioSha256V1(
        current.scenario(),
    );
    output.* = .{
        .scenario = current,
        .original_scenario_sha256 = original_root,
        .minimized_scenario_sha256 = minimized_root,
        .failure_signature_sha256 = failureSignatureSha256V1(expected),
        .evaluations = context.evaluations,
        .reductions = reductions,
        .budget_exhausted = false,
        .locally_minimal = true,
    };
}

fn reduceOnePassV1(
    current: *OwnedScenarioV1,
    context: *ShrinkContextV1,
) Error!PassResultV1 {
    const count: usize = current.item_count;
    if (count > 2) {
        var remove_index = count;
        while (remove_index > 0) {
            remove_index -= 1;
            var candidate = current.*;
            removeItemV1(&candidate, remove_index);
            switch (try context.consider(current, &candidate)) {
                .accepted => return .accepted,
                .budget => return .budget,
                .rejected => {},
            }
        }
    }

    for (0..count) |index| {
        if (current.items[index].terminal_action == .none) continue;
        var candidate = current.*;
        candidate.items[index].terminal_action = .none;
        candidate.items[index].terminal_action_step = workload.absent_step;
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }

    for (0..count) |index| {
        const current_work = current.items[index].work_quanta;
        if (current_work <= 1) continue;
        const targets = [_]u64{
            1,
            @max(@as(u64, 1), current_work / 2),
            current_work - 1,
        };
        for (targets, 0..) |target, target_index| {
            if (target >= current_work) continue;
            var duplicate = false;
            for (targets[0..target_index]) |prior| {
                if (prior == target) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            var candidate = current.*;
            candidate.items[index].work_quanta = target;
            switch (try context.consider(current, &candidate)) {
                .accepted => return .accepted,
                .budget => return .budget,
                .rejected => {},
            }
        }
    }

    for (0..count) |index| {
        const current_arrival = current.items[index].arrival_step;
        if (current_arrival == 0) continue;
        const previous_arrival = if (index == 0)
            0
        else
            current.items[index - 1].arrival_step;
        const targets = [_]u64{ previous_arrival, current_arrival - 1 };
        for (targets, 0..) |target, target_index| {
            if (target >= current_arrival) continue;
            var duplicate = false;
            for (targets[0..target_index]) |prior| {
                if (prior == target) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            var candidate = current.*;
            candidate.items[index].arrival_step = target;
            switch (try context.consider(current, &candidate)) {
                .accepted => return .accepted,
                .budget => return .budget,
                .rejected => {},
            }
        }
    }

    for (0..count) |index| {
        const item = current.items[index];
        if (item.terminal_action == .none or
            item.terminal_action_step == item.arrival_step)
            continue;
        var candidate = current.*;
        candidate.items[index].terminal_action_step = item.arrival_step;
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }

    for (0..count) |index| {
        if (current.items[index].deadline_tick == 0) continue;
        var candidate = current.*;
        candidate.items[index].deadline_tick = 0;
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }

    for (0..count) |index| {
        if (current.items[index].weight == 1) continue;
        var candidate = current.*;
        candidate.items[index].weight = 1;
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }

    for (0..count) |index| {
        if (current.items[index].media_kind == .image) continue;
        var candidate = current.*;
        candidate.items[index] = withKindV1(
            candidate.items[index],
            .image,
        );
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }

    if (current.capacity > 1) {
        var candidate = current.*;
        candidate.capacity = 1;
        candidate.limits.queue_slots = 1;
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }

    const minimum_host = try maximumIndividualHostV1(
        current.items[0..count],
    );
    if (minimum_host < current.limits.host_bytes) {
        var candidate = current.*;
        candidate.limits.host_bytes = minimum_host;
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }

    const minimum_steps = try minimumDriverStepsV1(
        current.items[0..count],
    );
    if (minimum_steps < current.max_driver_steps) {
        var candidate = current.*;
        candidate.max_driver_steps = minimum_steps;
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }

    if (current.max_projection_operations > 1) {
        var candidate = current.*;
        candidate.max_projection_operations = 1;
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }

    if (current.fairness_end_tick > 1) {
        var candidate = current.*;
        candidate.fairness_end_tick = 1;
        switch (try context.consider(current, &candidate)) {
            .accepted => return .accepted,
            .budget => return .budget,
            .rejected => {},
        }
    }
    return .no_change;
}

fn removeItemV1(
    owned: *OwnedScenarioV1,
    remove_index: usize,
) void {
    const old_count: usize = owned.item_count;
    std.debug.assert(remove_index < old_count and old_count > 2);
    var index = remove_index;
    while (index + 1 < old_count) : (index += 1) {
        owned.items[index] = withOrdinalV1(
            owned.items[index + 1],
            index,
        );
    }
    owned.item_count -= 1;
}

fn withOrdinalV1(
    item: workload.WorkItemV1,
    ordinal: usize,
) workload.WorkItemV1 {
    var changed = item;
    changed.ordinal = @intCast(ordinal);
    return changed;
}

fn withKindV1(
    item: workload.WorkItemV1,
    kind: media.MediaKindV1,
) workload.WorkItemV1 {
    return workload.makeWorkItemV1(item.ordinal, .{
        .media_kind = kind,
        .arrival_step = item.arrival_step,
        .weight = item.weight,
        .work_quanta = item.work_quanta,
        .deadline_tick = item.deadline_tick,
        .terminal_action_step = item.terminal_action_step,
        .terminal_action = item.terminal_action,
        .fairness_member = item.fairness_member,
        .identity = .{
            .tenant_key = item.tenant_key,
            .request_key = item.request_key,
            .request_generation = item.request_generation,
            .resource_owner_key = item.resource_owner_key,
        },
    });
}

fn maximumIndividualHostV1(
    items: []const workload.WorkItemV1,
) Error!u64 {
    var maximum: u64 = 0;
    for (items) |item|
        maximum = @max(maximum, try item.claim.hostBytes());
    return maximum;
}

fn minimumDriverStepsV1(
    items: []const workload.WorkItemV1,
) Error!u64 {
    var total_work: u64 = 0;
    var latest_arrival: u64 = 0;
    var latest_action: u64 = 0;
    for (items) |item| {
        total_work = try addU64(total_work, item.work_quanta);
        latest_arrival = @max(latest_arrival, item.arrival_step);
        if (item.terminal_action != .none)
            latest_action = @max(latest_action, item.terminal_action_step);
    }
    return @max(
        try addU64(try addU64(latest_arrival, total_work), 1),
        try addU64(latest_action, 1),
    );
}

pub fn syntheticFailureSignatureV1() FailureSignatureV1 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(synthetic_failure_domain);
    var fingerprint: Digest = undefined;
    hash.final(&fingerprint);
    return .{
        .stage = .synthetic_shrinker_conformance,
        .code = 1,
        .fingerprint = fingerprint,
    };
}

pub fn syntheticFailureProbeV1() FailureProbeV1 {
    return .{ .evaluate_fn = evaluateSyntheticTurnoverV1 };
}

fn evaluateSyntheticTurnoverV1(
    context: ?*anyopaque,
    scenario: workload.ScenarioV1,
    result: workload.ResultV1,
) ?FailureSignatureV1 {
    _ = context;
    if (scenario.items.len != 2 or
        result.summary.cancelled != 1 or
        result.summary.completed != 1 or
        result.summary.maximum_live_receipts != 1 or
        !result.summary.zero_orphan_ownership)
        return null;
    var cancel_step: ?u64 = null;
    for (scenario.items) |item| {
        if (item.terminal_action == .cancel)
            cancel_step = item.terminal_action_step;
    }
    if (cancel_step == null) return null;
    for (scenario.items, result.outcomes) |item, outcome| {
        if (outcome.kind == .completed and
            item.arrival_step > cancel_step.?)
            return syntheticFailureSignatureV1();
    }
    return null;
}

pub fn runSyntheticShrinkV1(
    output: *ShrinkResultV1,
) Error!void {
    var original: OwnedScenarioV1 = undefined;
    try generateRetainedCaseV1(3, &original);
    return shrinkFailureV1(
        &original,
        syntheticFailureSignatureV1(),
        syntheticFailureProbeV1(),
        maximum_shrink_evaluations,
        output,
    );
}

fn nonzeroV1(value: u64) u64 {
    return if (value == 0) 1 else value;
}

fn addU64(left: u64, right: anytype) Error!u64 {
    return std.math.add(u64, left, @intCast(right)) catch
        return error.ArithmeticOverflow;
}

fn hashU64(hash: anytype, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

const UnstableProbeState = struct {
    calls: u64 = 0,
};

fn unstableAfterInitialProbe(
    context: ?*anyopaque,
    scenario: workload.ScenarioV1,
    result: workload.ResultV1,
) ?FailureSignatureV1 {
    _ = scenario;
    _ = result;
    const state: *UnstableProbeState =
        @ptrCast(@alignCast(context.?));
    const call = state.calls;
    state.calls += 1;
    if (call < 2 or call % 2 == 0)
        return syntheticFailureSignatureV1();
    return null;
}

fn digestFromHex(hex: *const [64]u8) !Digest {
    var digest: Digest = undefined;
    _ = try std.fmt.hexToBytes(&digest, hex);
    return digest;
}

test "decision address and retained corpus aggregates are frozen" {
    const vectors = .{
        .{
            DecisionTagV1.scenario_seed,
            "4c0b3855daa90459f6025c1c00d2822da64d24e4742b117896020c0887b1a006",
            @as(u64, 6_414_438_524_480_129_868),
        },
        .{
            DecisionTagV1.bank_epoch,
            "cbc709239e8dd4ee3f496671cf4abc5d69cded5e26d1cebf730762e771aeb522",
            @as(u64, 17_209_535_786_421_700_555),
        },
        .{
            DecisionTagV1.scheduler_epoch,
            "47d3ca0a4e836d6351cd8f20a39790ee1a49c71b57b61d698325d0fcefd90431",
            @as(u64, 7_164_526_953_428_079_431),
        },
        .{
            DecisionTagV1.challenge,
            "72c2beb7487d9e24725a33593e5d6f84b23394eb993545de6a79bcffb7a17c1e",
            @as(u64, 2_638_684_182_959_538_802),
        },
        .{
            DecisionTagV1.modality_rotation,
            "a5495d4122eb9a23e106773fcca08fc6a7c3c133124a3513433a4dc72f30633e",
            @as(u64, 2_565_621_470_098_966_949),
        },
    };
    inline for (vectors) |vector| {
        const expected_decision = try digestFromHex(vector[1]);
        try std.testing.expectEqualDeep(
            expected_decision,
            decisionDigestV1(
                retained_seeds[0],
                0,
                .fairness,
                vector[0],
                workload.absent_item,
            ),
        );
        try std.testing.expectEqual(
            vector[2],
            decisionU64V1(
                retained_seeds[0],
                0,
                .fairness,
                vector[0],
                workload.absent_item,
            ),
        );
    }

    var corpus: RetainedCorpusV1 = undefined;
    try runRetainedCorpusV1(&corpus);
    try std.testing.expectEqual(
        mandatory_coverage_bits,
        corpus.coverage_bits,
    );
    try std.testing.expectEqual(@as(u64, 80), corpus.item_count);
    try std.testing.expectEqual(@as(u64, 52), corpus.admitted);
    try std.testing.expectEqual(@as(u64, 28), corpus.rejected);
    try std.testing.expectEqual(@as(u64, 44), corpus.completed);
    try std.testing.expectEqual(@as(u64, 4), corpus.cancelled);
    try std.testing.expectEqual(@as(u64, 4), corpus.timed_out);
    try std.testing.expectEqual(@as(u64, 124), corpus.service_quanta);
    try std.testing.expectEqual(@as(u64, 140), corpus.driver_steps);
    try std.testing.expectEqual(@as(u64, 44), corpus.publications);
    try std.testing.expectEqual(
        @as(u64, 52),
        corpus.closed_terminal_sessions,
    );
    try std.testing.expect(corpus.zero_orphan_ownership);
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "7503b944a4092d3e0a3c7c40602f7df38d46adbf4569d038353004668b993c0b",
        ),
        corpus.cases[0].case_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "68215427b0c8feef54611eb144446b1819a587e41d4696d2b9483e22d8ca5bbc",
        ),
        corpus.corpus_sha256,
    );
    try std.testing.expectEqualDeep(
        corpus.corpus_sha256,
        corpusRootV1(corpus),
    );
    var stale_child = corpus;
    stale_child.cases[0].service_quanta += 1;
    const stale_root = corpusRootV1(stale_child);
    try std.testing.expect(!std.mem.eql(
        u8,
        &corpus.corpus_sha256,
        &stale_root,
    ));
    var stale_cache_only = corpus;
    stale_cache_only.cases[0].case_sha256[0] ^= 1;
    try std.testing.expectEqualDeep(
        corpus.corpus_sha256,
        corpusRootV1(stale_cache_only),
    );
}

test "each generated class reaches its exact W0 and W1 terminal path" {
    for (0..class_count) |case_index| {
        var owned: OwnedScenarioV1 = undefined;
        try generateRetainedCaseV1(case_index, &owned);
        const scenario_class = try classForRetainedCaseV1(case_index);
        const evidence = try executeCaseV1(
            retained_seeds[0],
            case_index,
            scenario_class,
            &owned,
        );
        switch (scenario_class) {
            .fairness => {
                try std.testing.expectEqual(@as(u64, 3), evidence.admitted);
                try std.testing.expectEqual(@as(u64, 3), evidence.completed);
            },
            .no_slot => {
                try std.testing.expectEqual(@as(u64, 2), evidence.rejected);
                try expectRejectionReason(&owned, .no_slot, 2);
            },
            .resource_limit => {
                try std.testing.expectEqual(@as(u64, 2), evidence.rejected);
                try expectRejectionReason(&owned, .resource_limit, 2);
            },
            .cancel_turnover => {
                try std.testing.expectEqual(@as(u64, 1), evidence.cancelled);
                try std.testing.expectEqual(@as(u64, 1), evidence.completed);
            },
            .timeout_turnover => {
                try std.testing.expectEqual(@as(u64, 1), evidence.timed_out);
                try std.testing.expectEqual(@as(u64, 1), evidence.completed);
            },
            .deadline_feasible => {
                try std.testing.expectEqual(@as(u64, 2), evidence.completed);
                try std.testing.expect(
                    evidence.coverage_bits &
                        CoverageV1.completed_deadline != 0,
                );
            },
            .deadline_infeasible => {
                try std.testing.expectEqual(@as(u64, 1), evidence.rejected);
                try expectRejectionReason(
                    &owned,
                    .deadline_infeasible,
                    1,
                );
            },
            .projection_limit => {
                try std.testing.expectEqual(@as(u64, 2), evidence.rejected);
                try expectRejectionReason(
                    &owned,
                    .projection_limit,
                    2,
                );
            },
        }
    }
}

fn expectRejectionReason(
    owned: *const OwnedScenarioV1,
    reason: qos.RejectionReason,
    expected_count: u64,
) !void {
    var storage: workload.MaximumStorageV1 = .{};
    const result = try workload.runScenarioV1(
        owned.scenario(),
        storage.interface(),
    );
    var count: u64 = 0;
    for (result.outcomes) |outcome| {
        if (outcome.kind == .rejected and
            outcome.rejection_reason == reason)
            count += 1;
    }
    try std.testing.expectEqual(expected_count, count);
}

test "generated scenario and result wires replay exactly for all cases" {
    const maximum_scenario_bytes =
        workload.scenario_header_bytes +
        workload.maximum_items * workload.scenario_item_bytes +
        workload.scenario_footer_bytes;
    const maximum_result_bytes =
        workload.result_header_bytes +
        workload.maximum_items * workload.outcome_record_bytes +
        workload.maximum_trace_records * workload.trace_record_bytes +
        workload.result_footer_bytes;

    for (0..retained_case_count) |case_index| {
        var owned: OwnedScenarioV1 = undefined;
        try generateRetainedCaseV1(case_index, &owned);
        const scenario = owned.scenario();
        var scenario_bytes: [maximum_scenario_bytes]u8 = undefined;
        const encoded_scenario = try workload.encodeScenarioV1(
            scenario,
            &scenario_bytes,
        );
        var decoded_items: [workload.maximum_items]workload.WorkItemV1 =
            undefined;
        const decoded_scenario = try workload.decodeScenarioV1(
            encoded_scenario,
            &decoded_items,
        );
        try std.testing.expectEqualDeep(
            try workload.scenarioSha256V1(scenario),
            try workload.scenarioSha256V1(decoded_scenario),
        );

        var storage: workload.MaximumStorageV1 = .{};
        const result = try workload.runScenarioV1(
            decoded_scenario,
            storage.interface(),
        );
        var result_bytes: [maximum_result_bytes]u8 = undefined;
        const encoded_result = try workload.encodeResultV1(
            result,
            &result_bytes,
        );
        var outcomes: [workload.maximum_items]workload.OutcomeV1 =
            undefined;
        var trace: [workload.maximum_trace_records]workload.TraceRecordV1 =
            undefined;
        const decoded_result = try workload.decodeResultV1(
            encoded_result,
            &outcomes,
            &trace,
        );
        var replay_storage: workload.MaximumStorageV1 = .{};
        try workload.validateResultByReplayV1(
            decoded_scenario,
            decoded_result,
            replay_storage.interface(),
        );
    }
}

test "public case execution rejects foreign labels and scenarios" {
    var owned: OwnedScenarioV1 = undefined;
    try generateRetainedCaseV1(0, &owned);
    try std.testing.expectError(
        Error.InvalidCorpus,
        executeCaseV1(
            retained_seeds[0],
            0,
            .no_slot,
            &owned,
        ),
    );
    try std.testing.expectError(
        Error.InvalidCorpus,
        executeCaseV1(
            retained_seeds[1],
            0,
            .fairness,
            &owned,
        ),
    );
    try std.testing.expectError(
        Error.InvalidCorpus,
        executeCaseV1(
            retained_seeds[0],
            1,
            .fairness,
            &owned,
        ),
    );
    var foreign = owned;
    foreign.items[0].work_quanta += 1;
    try std.testing.expectError(
        Error.InvalidCorpus,
        executeCaseV1(
            retained_seeds[0],
            0,
            .fairness,
            &foreign,
        ),
    );
}

test "W0 and W1 reference goldens remain unchanged" {
    var items = workload.makeReferenceItemsV1();
    const scenario = workload.referenceScenarioV1(&items);
    var workload_storage: workload.ReferenceStorageV1 = .{};
    const result = try workload.runScenarioV1(
        scenario,
        workload_storage.interface(),
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "e6fc0e1b3d676c5ea89a2e54434bef0ac51e30f8b1ab85944bfc43e0cd34407b",
        ),
        result.scenario_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "9eb52f76c2c68098d59f13bc6d5b456b2efd7297b936731543c33a2d9934596f",
        ),
        result.outcome_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "0868ce16006aa777bbc13d2454935607f375f5446e4c18cf78a958c2bee92169",
        ),
        result.trace_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "1c7d104f1d12627503c6d472f01bb0b07f41f200a8d1ecad23738d06dff80b0d",
        ),
        result.summary_sha256,
    );
    var scheduled_storage: scheduled.ReferenceStorageV1 = .{};
    const campaign = try scheduled.runReferenceScenarioV1(
        &scheduled_storage,
    );
    try std.testing.expectEqualDeep(
        result.scenario_sha256,
        campaign.workload_result.scenario_sha256,
    );
    try std.testing.expectEqualDeep(
        result.outcome_sha256,
        campaign.workload_result.outcome_sha256,
    );
    try std.testing.expectEqualDeep(
        result.trace_sha256,
        campaign.workload_result.trace_sha256,
    );
    try std.testing.expectEqualDeep(
        result.summary_sha256,
        campaign.workload_result.summary_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "f6d17a0d6471379c61bd38a5ac255c88f14dfb7585e150cda85b8d04631b880b",
        ),
        campaign.evidence.evidence_sha256,
    );
}

test "shrinker is stable monotone bounded idempotent and locally minimal" {
    var original: OwnedScenarioV1 = undefined;
    try generateRetainedCaseV1(3, &original);
    const original_complexity = try complexityV1(&original);
    var shrunk: ShrinkResultV1 = undefined;
    try shrinkFailureV1(
        &original,
        syntheticFailureSignatureV1(),
        syntheticFailureProbeV1(),
        maximum_shrink_evaluations,
        &shrunk,
    );
    try std.testing.expect(shrunk.locally_minimal);
    try std.testing.expect(!shrunk.budget_exhausted);
    try std.testing.expect(shrunk.reductions > 0);
    try std.testing.expect(shrunk.evaluations >= 2);
    try std.testing.expectEqual(@as(u64, 0), shrunk.evaluations % 2);
    try std.testing.expect(
        (try complexityV1(&shrunk.scenario)).lessThan(
            original_complexity,
        ),
    );
    try std.testing.expectEqual(@as(u64, 58), shrunk.evaluations);
    try std.testing.expectEqual(@as(u64, 8), shrunk.reductions);
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "552f40e339d7dc4b90757179ef244de25015caeea2890a08eb978f50a9cba314",
        ),
        shrunk.original_scenario_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "6cf1ea51f6b1deb5f765500eb389c408c9eb451e8b9ba5ca971f9295fefc4cf4",
        ),
        shrunk.minimized_scenario_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "d0b9ca7624476aa868bf28115635e35119224f642031d6a810ed93c08151cff3",
        ),
        shrunk.failure_signature_sha256,
    );
    var minimized_storage: workload.MaximumStorageV1 = .{};
    const minimized_result = try workload.runScenarioV1(
        shrunk.scenario.scenario(),
        minimized_storage.interface(),
    );
    try std.testing.expectEqualDeep(
        syntheticFailureSignatureV1(),
        syntheticFailureProbeV1().evaluate(
            shrunk.scenario.scenario(),
            minimized_result,
        ).?,
    );

    var second: ShrinkResultV1 = undefined;
    try shrinkFailureV1(
        &shrunk.scenario,
        syntheticFailureSignatureV1(),
        syntheticFailureProbeV1(),
        maximum_shrink_evaluations,
        &second,
    );
    try std.testing.expectEqual(@as(u64, 0), second.reductions);
    try std.testing.expectEqual(@as(u64, 8), second.evaluations);
    try std.testing.expect(second.locally_minimal);
    try std.testing.expect(!second.budget_exhausted);
    try std.testing.expectEqualDeep(
        shrunk.minimized_scenario_sha256,
        second.minimized_scenario_sha256,
    );

    var bounded = shrunk;
    const bounded_scenario_before = try workload.scenarioSha256V1(
        bounded.scenario.scenario(),
    );
    try std.testing.expectError(
        Error.EvaluationBudgetExhausted,
        shrinkFailureV1(
            &original,
            syntheticFailureSignatureV1(),
            syntheticFailureProbeV1(),
            2,
            &bounded,
        ),
    );
    try std.testing.expectEqualDeep(
        bounded_scenario_before,
        try workload.scenarioSha256V1(bounded.scenario.scenario()),
    );
    try std.testing.expectEqualDeep(
        shrunk.original_scenario_sha256,
        bounded.original_scenario_sha256,
    );
    try std.testing.expectEqualDeep(
        shrunk.minimized_scenario_sha256,
        bounded.minimized_scenario_sha256,
    );
    try std.testing.expectEqualDeep(
        shrunk.failure_signature_sha256,
        bounded.failure_signature_sha256,
    );
    try std.testing.expectEqual(shrunk.evaluations, bounded.evaluations);
    try std.testing.expectEqual(shrunk.reductions, bounded.reductions);
    try std.testing.expectEqual(
        shrunk.budget_exhausted,
        bounded.budget_exhausted,
    );
    try std.testing.expectEqual(
        shrunk.locally_minimal,
        bounded.locally_minimal,
    );
}

test "shrinker errors preserve output and reject unstable signatures" {
    var original: OwnedScenarioV1 = undefined;
    try generateRetainedCaseV1(3, &original);
    var sentinel: ShrinkResultV1 = undefined;
    try runSyntheticShrinkV1(&sentinel);

    var output = sentinel;
    var mismatched = syntheticFailureSignatureV1();
    mismatched.code += 1;
    try std.testing.expectError(
        Error.FailureSignatureMismatch,
        shrinkFailureV1(
            &original,
            mismatched,
            syntheticFailureProbeV1(),
            maximum_shrink_evaluations,
            &output,
        ),
    );
    try std.testing.expectEqualDeep(
        sentinel.minimized_scenario_sha256,
        output.minimized_scenario_sha256,
    );

    var unstable_state: UnstableProbeState = .{};
    try std.testing.expectError(
        Error.UnstableFailure,
        shrinkFailureV1(
            &original,
            syntheticFailureSignatureV1(),
            .{
                .context = &unstable_state,
                .evaluate_fn = unstableAfterInitialProbe,
            },
            maximum_shrink_evaluations,
            &output,
        ),
    );
    try std.testing.expectEqual(@as(u64, 4), unstable_state.calls);
    try std.testing.expectEqualDeep(
        sentinel.minimized_scenario_sha256,
        output.minimized_scenario_sha256,
    );

    try std.testing.expectError(
        Error.InvalidEvaluationBudget,
        shrinkFailureV1(
            &original,
            syntheticFailureSignatureV1(),
            syntheticFailureProbeV1(),
            3,
            &output,
        ),
    );
    try std.testing.expectEqualDeep(
        sentinel.minimized_scenario_sha256,
        output.minimized_scenario_sha256,
    );
}
