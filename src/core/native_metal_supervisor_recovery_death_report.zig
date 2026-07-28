//! Portable evidence for the fixed W7b-b5 supervisor/recovery death boundary.
//!
//! The wire is pointer-free, allocation-free, explicitly little-endian, and
//! has one exact 3,520-byte geometry. It binds two real process-death receipts
//! to the generation-six checkpoint, gates recovery-ready on a challenge over
//! the fresh generation-six audit plus a controller lock-contention ACK, binds
//! the generation-twelve prepared selector, and retains a final strict audit.
//! The codec validates evidence already observed by a controller; it does not
//! send signals, acquire store authority, or perform recovery. Successful
//! decoding authenticates the canonical encoded claims; it does not
//! independently observe OS signal delivery, GPU execution, CPU oracle
//! execution, or durable filesystem behavior.

const std = @import("std");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const report_abi: u64 = 0x4757_5352_0000_0001;
pub const supervisor_ready_abi: u64 = 0x4757_5355_0000_0001;
pub const supervisor_kill_abi: u64 = 0x4757_534b_0000_0001;
pub const generation_six_audit_abi: u64 = 0x4757_5341_0000_0001;
pub const recovery_ready_abi: u64 = 0x4757_5252_0000_0001;
pub const recovery_kill_abi: u64 = 0x4757_524b_0000_0001;
pub const final_audit_abi: u64 = 0x4757_5241_0000_0001;

pub const report_header_bytes: usize = 1_024;
pub const supervisor_ready_bytes: usize = 512;
pub const supervisor_kill_bytes: usize = 320;
pub const generation_six_audit_bytes: usize = 384;
pub const recovery_ready_bytes: usize = 512;
pub const recovery_kill_bytes: usize = 320;
pub const final_audit_bytes: usize = 384;
pub const report_footer_bytes: usize = 64;
pub const report_encoded_bytes: usize = 3_520;
pub const encoded_bytes = report_encoded_bytes;

pub const report_header_offset: usize = 0;
pub const supervisor_ready_offset: usize =
    report_header_offset + report_header_bytes;
pub const supervisor_kill_offset: usize =
    supervisor_ready_offset + supervisor_ready_bytes;
pub const generation_six_audit_offset: usize =
    supervisor_kill_offset + supervisor_kill_bytes;
pub const recovery_ready_offset: usize =
    generation_six_audit_offset + generation_six_audit_bytes;
pub const recovery_kill_offset: usize =
    recovery_ready_offset + recovery_ready_bytes;
pub const final_audit_offset: usize =
    recovery_kill_offset + recovery_kill_bytes;
pub const report_footer_offset: usize =
    final_audit_offset + final_audit_bytes;

pub const allowed_flags: u64 = 0;
pub const selector_wire_bytes: u64 = 192;
pub const termination_signal_kill: u64 = 9;
pub const killed_returncode_bits: u64 = std.math.maxInt(u64) - 8;

pub const expected_segment_count: u64 = 12;
pub const expected_supervisor_generation: u64 = 6;
pub const expected_recovery_selected_generation: u64 = 11;
pub const expected_candidate_generation: u64 = 12;
pub const expected_worker_process_count: u64 = 2;
pub const expected_total_sigkill_count: u64 = 2;
pub const expected_total_records: u64 = 3_000;
pub const expected_total_completed: u64 = 1_200;
pub const expected_total_cancelled: u64 = 600;
pub const expected_total_failed: u64 = 600;
pub const expected_total_capacity_rejected: u64 = 600;
pub const expected_total_pin_completions: u64 = 2_400;
pub const expected_total_events: u64 = 15_000;

const header_scalar_count: usize = 24;
const header_digest_count: usize = 26;
const supervisor_ready_scalar_count: usize = 16;
const supervisor_ready_digest_count: usize = 12;
const kill_scalar_count: usize = 8;
const kill_digest_count: usize = 8;
const audit_scalar_count: usize = 16;
const audit_digest_count: usize = 8;

const header_domain =
    "glacier-w7b-b5-supervisor-recovery-death-header-v1\x00";
const supervisor_ready_domain =
    "glacier-w7b-b5-supervisor-recovery-death-supervisor-ready-v1\x00";
const supervisor_kill_domain =
    "glacier-w7b-b5-supervisor-recovery-death-supervisor-kill-v1\x00";
const generation_six_audit_domain =
    "glacier-w7b-b5-supervisor-recovery-death-generation-six-audit-v1\x00";
const recovery_ready_domain =
    "glacier-w7b-b5-supervisor-recovery-death-recovery-ready-v1\x00";
const recovery_kill_domain =
    "glacier-w7b-b5-supervisor-recovery-death-recovery-kill-v1\x00";
const final_audit_domain =
    "glacier-w7b-b5-supervisor-recovery-death-final-audit-v1\x00";
const body_domain =
    "glacier-w7b-b5-supervisor-recovery-death-body-v1\x00";
const report_domain =
    "glacier-w7b-b5-supervisor-recovery-death-report-v1\x00";
const component_set_domain =
    "glacier-w7b-b5-supervisor-recovery-death-component-set-v1\x00";
const supervisor_challenge_domain =
    "glacier-w7b-b5-supervisor-recovery-death-supervisor-challenge-v1\x00";
const machine_join_domain =
    "glacier-w7b-b5-supervisor-recovery-death-machine-join-v1\x00";
const recovery_challenge_domain =
    "glacier-w7b-b5-supervisor-recovery-death-recovery-challenge-v1\x00";
const resume_grant_domain =
    "glacier-w7b-b5-supervisor-recovery-death-resume-grant-v1\x00";
const finalizer_grant_domain =
    "glacier-w7b-b5-supervisor-recovery-death-finalizer-grant-v1\x00";

comptime {
    if (report_header_bytes !=
        header_scalar_count * @sizeOf(u64) +
            header_digest_count * @sizeOf(Digest) or
        supervisor_ready_bytes !=
            supervisor_ready_scalar_count * @sizeOf(u64) +
                supervisor_ready_digest_count * @sizeOf(Digest) or
        supervisor_kill_bytes !=
            kill_scalar_count * @sizeOf(u64) +
                kill_digest_count * @sizeOf(Digest) or
        generation_six_audit_bytes !=
            audit_scalar_count * @sizeOf(u64) +
                audit_digest_count * @sizeOf(Digest) or
        recovery_ready_bytes !=
            supervisor_ready_scalar_count * @sizeOf(u64) +
                supervisor_ready_digest_count * @sizeOf(Digest) or
        recovery_kill_bytes !=
            kill_scalar_count * @sizeOf(u64) +
                kill_digest_count * @sizeOf(Digest) or
        final_audit_bytes !=
            audit_scalar_count * @sizeOf(u64) +
                audit_digest_count * @sizeOf(Digest) or
        report_footer_offset + report_footer_bytes != report_encoded_bytes)
        @compileError(
            "native Metal supervisor/recovery death report layout drift",
        );
}

pub const Error = error{
    BufferTooSmall,
    InvalidAbi,
    InvalidAlias,
    InvalidBinding,
    InvalidCounts,
    InvalidFlags,
    InvalidIdentity,
    InvalidLength,
    InvalidProcess,
    InvalidRoot,
    InvalidState,
};

pub const ReportHeaderV1 = struct {
    abi_version: u64 = report_abi,
    encoded_bytes: u64 = report_encoded_bytes,
    flags: u64 = allowed_flags,
    header_bytes: u64 = report_header_bytes,
    supervisor_ready_bytes: u64 = supervisor_ready_bytes,
    supervisor_kill_bytes: u64 = supervisor_kill_bytes,
    generation_six_audit_bytes: u64 = generation_six_audit_bytes,
    recovery_ready_bytes: u64 = recovery_ready_bytes,
    recovery_kill_bytes: u64 = recovery_kill_bytes,
    final_audit_bytes: u64 = final_audit_bytes,
    footer_bytes: u64 = report_footer_bytes,
    segment_count: u64 = expected_segment_count,
    supervisor_generation: u64 = expected_supervisor_generation,
    recovery_selected_generation: u64 =
        expected_recovery_selected_generation,
    candidate_generation: u64 = expected_candidate_generation,
    worker_process_count: u64 = expected_worker_process_count,
    total_sigkill_count: u64 = expected_total_sigkill_count,
    total_records: u64 = expected_total_records,
    total_completed: u64 = expected_total_completed,
    total_cancelled: u64 = expected_total_cancelled,
    total_failed: u64 = expected_total_failed,
    total_capacity_rejected: u64 =
        expected_total_capacity_rejected,
    total_pin_completions: u64 =
        expected_total_pin_completions,
    total_events: u64 = expected_total_events,

    campaign_challenge_sha256: Digest,
    schedule_sha256: Digest,
    controller_authority_sha256: Digest,
    component_set_sha256: Digest = zero_digest,
    controller_sha256: Digest,
    supervisor_sha256: Digest,
    recovery_sha256: Digest,
    worker_sha256: Digest,
    metallib_sha256: Digest,
    verifier_sha256: Digest,
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    resume_grant_sha256: Digest = zero_digest,
    finalizer_grant_sha256: Digest = zero_digest,
    supervisor_ready_sha256: Digest = zero_digest,
    supervisor_kill_sha256: Digest = zero_digest,
    generation_six_audit_sha256: Digest = zero_digest,
    recovery_ready_sha256: Digest = zero_digest,
    recovery_kill_sha256: Digest = zero_digest,
    final_audit_sha256: Digest = zero_digest,
    generation_six_selector_sha256: Digest,
    candidate_selector_sha256: Digest,
    final_store_sha256: Digest,
    header_sha256: Digest = zero_digest,
};

pub const SupervisorReadyV1 = struct {
    abi_version: u64 = supervisor_ready_abi,
    encoded_bytes: u64 = supervisor_ready_bytes,
    flags: u64 = allowed_flags,
    pid: u64,
    worker_pid: u64,
    worker_exit_code_bits: u64 = 0,
    worker_termination_signal: u64 = 0,
    active_worker_count: u64 = 0,
    lock_held: u64 = 1,
    selected_generation: u64 = expected_supervisor_generation,
    completed_segment_count: u64 = expected_supervisor_generation,
    publication_inflight: u64 = 0,
    selector_bytes: u64 = selector_wire_bytes,
    process_session_isolated: u64 = 1,
    lock_contended: u64 = 1,
    reserved: u64 = 0,

    supervisor_challenge_sha256: Digest = zero_digest,
    supervisor_sha256: Digest,
    worker_sha256: Digest,
    metallib_sha256: Digest,
    campaign_id_sha256: Digest,
    manifest_sha256: Digest,
    selector_sha256: Digest,
    final_entry_sha256: Digest,
    canonical_store_sha256: Digest,
    lock_identity_sha256: Digest,
    machine_join_sha256: Digest = zero_digest,
    root_sha256: Digest = zero_digest,
};

pub const SupervisorKillV1 = struct {
    abi_version: u64 = supervisor_kill_abi,
    encoded_bytes: u64 = supervisor_kill_bytes,
    flags: u64 = allowed_flags,
    pid: u64,
    termination_signal: u64 = termination_signal_kill,
    returncode_bits: u64 = killed_returncode_bits,
    stdout_bytes: u64 = supervisor_ready_bytes,
    stderr_bytes: u64 = 0,

    campaign_challenge_sha256: Digest,
    supervisor_challenge_sha256: Digest = zero_digest,
    supervisor_ready_sha256: Digest = zero_digest,
    supervisor_sha256: Digest,
    controller_sha256: Digest,
    lock_identity_sha256: Digest,
    component_set_sha256: Digest = zero_digest,
    root_sha256: Digest = zero_digest,
};

pub const GenerationSixAuditV1 = struct {
    abi_version: u64 = generation_six_audit_abi,
    encoded_bytes: u64 = generation_six_audit_bytes,
    flags: u64 = allowed_flags,
    auditor_pid: u64,
    selected_generation: u64 = expected_supervisor_generation,
    segment_count: u64 = expected_supervisor_generation,
    require_complete: u64 = 0,
    complete: u64 = 0,
    shared_lock_held: u64 = 1,
    unknown_file_count: u64 = 0,
    temporary_file_count: u64 = 0,
    hardlink_count: u64 = 0,
    symlink_count: u64 = 0,
    process_generation_count: u64 = 1,
    record_count: u64 = expected_total_records / 2,
    completed_count: u64 = expected_total_completed / 2,

    resume_grant_sha256: Digest = zero_digest,
    campaign_id_sha256: Digest,
    manifest_sha256: Digest,
    selector_sha256: Digest,
    final_entry_sha256: Digest,
    canonical_store_sha256: Digest,
    lock_identity_sha256: Digest,
    root_sha256: Digest = zero_digest,
};

pub const RecoveryReadyV1 = struct {
    abi_version: u64 = recovery_ready_abi,
    encoded_bytes: u64 = recovery_ready_bytes,
    flags: u64 = allowed_flags,
    pid: u64,
    worker_pid: u64,
    worker_exit_code_bits: u64 = 0,
    worker_termination_signal: u64 = 0,
    active_worker_count: u64 = 0,
    lock_held: u64 = 1,
    selected_generation: u64 =
        expected_recovery_selected_generation,
    candidate_generation: u64 = expected_candidate_generation,
    segment_count: u64 = expected_segment_count,
    controller_lock_contention_acknowledged: u64 = 1,
    candidate_selector_bytes: u64 = selector_wire_bytes,
    root_sync_completed: u64 = 0,
    publication_phase_index: u64 = 26,

    resume_grant_sha256: Digest = zero_digest,
    recovery_sha256: Digest,
    worker_sha256: Digest,
    recovery_challenge_sha256: Digest = zero_digest,
    campaign_id_sha256: Digest,
    selected_manifest_sha256: Digest,
    selected_selector_sha256: Digest,
    candidate_manifest_sha256: Digest,
    candidate_selector_sha256: Digest,
    prepared_store_sha256: Digest,
    lock_identity_sha256: Digest,
    root_sha256: Digest = zero_digest,
};

pub const RecoveryKillV1 = struct {
    abi_version: u64 = recovery_kill_abi,
    encoded_bytes: u64 = recovery_kill_bytes,
    flags: u64 = allowed_flags,
    pid: u64,
    termination_signal: u64 = termination_signal_kill,
    returncode_bits: u64 = killed_returncode_bits,
    stdout_bytes: u64 = recovery_ready_bytes,
    stderr_bytes: u64 = 0,

    campaign_challenge_sha256: Digest,
    resume_grant_sha256: Digest = zero_digest,
    recovery_ready_sha256: Digest = zero_digest,
    recovery_sha256: Digest,
    controller_sha256: Digest,
    lock_identity_sha256: Digest,
    component_set_sha256: Digest = zero_digest,
    root_sha256: Digest = zero_digest,
};

pub const FinalAuditV1 = struct {
    abi_version: u64 = final_audit_abi,
    encoded_bytes: u64 = final_audit_bytes,
    flags: u64 = allowed_flags,
    finalizer_pid: u64,
    auditor_pid: u64,
    predecessor_generation: u64 =
        expected_recovery_selected_generation,
    final_generation: u64 = expected_candidate_generation,
    segment_count: u64 = expected_segment_count,
    rollforward_count: u64 = 1,
    selector_replace_count: u64 = 1,
    root_sync_count: u64 = 1,
    complete: u64 = 1,
    unknown_file_count: u64 = 0,
    temporary_file_count: u64 = 0,
    record_count: u64 = expected_total_records,
    completed_count: u64 = expected_total_completed,

    finalizer_grant_sha256: Digest = zero_digest,
    campaign_id_sha256: Digest,
    predecessor_selector_sha256: Digest,
    candidate_selector_sha256: Digest,
    final_manifest_sha256: Digest,
    final_selector_sha256: Digest,
    final_store_sha256: Digest,
    root_sha256: Digest = zero_digest,
};

pub const ReportFooterV1 = struct {
    body_sha256: Digest = zero_digest,
    report_sha256: Digest = zero_digest,
};

pub const NativeMetalSupervisorRecoveryDeathReportV1 = struct {
    header: ReportHeaderV1,
    supervisor_ready: SupervisorReadyV1,
    supervisor_kill: SupervisorKillV1,
    generation_six_audit: GenerationSixAuditV1,
    recovery_ready: RecoveryReadyV1,
    recovery_kill: RecoveryKillV1,
    final_audit: FinalAuditV1,
    footer: ReportFooterV1 = .{},
};

pub const ReportV1 = NativeMetalSupervisorRecoveryDeathReportV1;

/// Derive the exact component-set identity. Role components may intentionally
/// alias when one executable exposes multiple bounded subcommands.
pub fn componentSetSha256V1(
    controller: Digest,
    supervisor: Digest,
    recovery: Digest,
    worker: Digest,
    metallib: Digest,
    verifier: Digest,
) Digest {
    return hashDigests(
        component_set_domain,
        &.{
            controller,
            supervisor,
            recovery,
            worker,
            metallib,
            verifier,
        },
    );
}

pub fn supervisorChallengeSha256V1(
    campaign_challenge: Digest,
    schedule: Digest,
    component_set: Digest,
) Digest {
    return hashDigests(
        supervisor_challenge_domain,
        &.{ campaign_challenge, schedule, component_set },
    );
}

pub fn machineJoinSha256V1(
    machine: Digest,
    backend: Digest,
    device: Digest,
    placement: Digest,
) Digest {
    return hashDigests(
        machine_join_domain,
        &.{ machine, backend, device, placement },
    );
}

pub fn recoveryChallengeSha256V1(
    resume_grant: Digest,
    generation_six_audit_root: Digest,
) Digest {
    return hashDigests(
        recovery_challenge_domain,
        &.{ resume_grant, generation_six_audit_root },
    );
}

pub fn resumeGrantSha256V1(
    controller_authority: Digest,
    campaign_challenge: Digest,
    schedule: Digest,
    component_set: Digest,
    supervisor_ready_root: Digest,
    supervisor_kill_root: Digest,
    generation_six_selector: Digest,
    generation_six_canonical_store: Digest,
) Digest {
    return hashDigests(
        resume_grant_domain,
        &.{
            controller_authority,
            campaign_challenge,
            schedule,
            component_set,
            supervisor_ready_root,
            supervisor_kill_root,
            generation_six_selector,
            generation_six_canonical_store,
        },
    );
}

pub fn finalizerGrantSha256V1(
    controller_authority: Digest,
    campaign_challenge: Digest,
    schedule: Digest,
    component_set: Digest,
    resume_grant: Digest,
    recovery_ready_root: Digest,
    recovery_kill_root: Digest,
    candidate_selector: Digest,
    prepared_store: Digest,
) Digest {
    return hashDigests(
        finalizer_grant_domain,
        &.{
            controller_authority,
            campaign_challenge,
            schedule,
            component_set,
            resume_grant,
            recovery_ready_root,
            recovery_kill_root,
            candidate_selector,
            prepared_store,
        },
    );
}

/// Seal only canonical derived identities and roots. Observed process, store,
/// selector, component, and count fields are never silently rewritten.
pub fn sealReportV1(
    seed: NativeMetalSupervisorRecoveryDeathReportV1,
) Error!NativeMetalSupervisorRecoveryDeathReportV1 {
    var result = seed;
    resealDerivedV1(&result);
    try validateReportV1(result);
    return result;
}

pub const makeReportV1 = sealReportV1;

pub fn validateReportV1(
    value: NativeMetalSupervisorRecoveryDeathReportV1,
) Error!void {
    try validateHeaderV1(value.header);
    try validateSupervisorReadyV1(value.supervisor_ready);
    try validateSupervisorKillV1(value.supervisor_kill);
    try validateGenerationSixAuditV1(value.generation_six_audit);
    try validateRecoveryReadyV1(value.recovery_ready);
    try validateRecoveryKillV1(value.recovery_kill);
    try validateFinalAuditV1(value.final_audit);
    try validateBindingsV1(value);

    if (!digestEqual(
        value.footer.body_sha256,
        bodySha256V1(value),
    ) or !digestEqual(
        value.footer.report_sha256,
        reportSha256V1(value.footer.body_sha256),
    ))
        return Error.InvalidRoot;
}

pub const validateV1 = validateReportV1;

pub fn encodeReportV1(
    value: NativeMetalSupervisorRecoveryDeathReportV1,
    output: []u8,
) Error![]const u8 {
    if (output.len < report_encoded_bytes)
        return Error.BufferTooSmall;
    if (output.len != report_encoded_bytes)
        return Error.InvalidLength;
    try validateReportV1(value);
    encodeUncheckedV1(value, output);
    return output;
}

pub const encodeV1 = encodeReportV1;

pub fn decodeReportV1(
    encoded: []const u8,
) Error!NativeMetalSupervisorRecoveryDeathReportV1 {
    if (encoded.len != report_encoded_bytes)
        return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    const value: NativeMetalSupervisorRecoveryDeathReportV1 = .{
        .header = readHeaderV1(&reader),
        .supervisor_ready = readSupervisorReadyV1(&reader),
        .supervisor_kill = readSupervisorKillV1(&reader),
        .generation_six_audit = readGenerationSixAuditV1(&reader),
        .recovery_ready = readRecoveryReadyV1(&reader),
        .recovery_kill = readRecoveryKillV1(&reader),
        .final_audit = readFinalAuditV1(&reader),
        .footer = .{
            .body_sha256 = reader.readDigest(),
            .report_sha256 = reader.readDigest(),
        },
    };
    if (reader.position != report_encoded_bytes)
        return Error.InvalidLength;
    try validateReportV1(value);
    return value;
}

pub const decodeV1 = decodeReportV1;

pub fn headerSha256V1(value: ReportHeaderV1) Digest {
    const scalars = headerScalarsV1(value);
    const digests = headerDigestsV1(value);
    return rootRegion(
        report_header_bytes - @sizeOf(Digest),
        header_domain,
        &scalars,
        digests[0 .. header_digest_count - 1],
    );
}

pub fn supervisorReadySha256V1(
    value: SupervisorReadyV1,
) Digest {
    const scalars = supervisorReadyScalarsV1(value);
    const digests = supervisorReadyDigestsV1(value);
    return rootRegion(
        supervisor_ready_bytes - @sizeOf(Digest),
        supervisor_ready_domain,
        &scalars,
        digests[0 .. supervisor_ready_digest_count - 1],
    );
}

pub fn supervisorKillSha256V1(value: SupervisorKillV1) Digest {
    const scalars = supervisorKillScalarsV1(value);
    const digests = supervisorKillDigestsV1(value);
    return rootRegion(
        supervisor_kill_bytes - @sizeOf(Digest),
        supervisor_kill_domain,
        &scalars,
        digests[0 .. kill_digest_count - 1],
    );
}

pub fn generationSixAuditSha256V1(
    value: GenerationSixAuditV1,
) Digest {
    const scalars = generationSixAuditScalarsV1(value);
    const digests = generationSixAuditDigestsV1(value);
    return rootRegion(
        generation_six_audit_bytes - @sizeOf(Digest),
        generation_six_audit_domain,
        &scalars,
        digests[0 .. audit_digest_count - 1],
    );
}

pub fn recoveryReadySha256V1(value: RecoveryReadyV1) Digest {
    const scalars = recoveryReadyScalarsV1(value);
    const digests = recoveryReadyDigestsV1(value);
    return rootRegion(
        recovery_ready_bytes - @sizeOf(Digest),
        recovery_ready_domain,
        &scalars,
        digests[0 .. supervisor_ready_digest_count - 1],
    );
}

pub fn recoveryKillSha256V1(value: RecoveryKillV1) Digest {
    const scalars = recoveryKillScalarsV1(value);
    const digests = recoveryKillDigestsV1(value);
    return rootRegion(
        recovery_kill_bytes - @sizeOf(Digest),
        recovery_kill_domain,
        &scalars,
        digests[0 .. kill_digest_count - 1],
    );
}

pub fn finalAuditSha256V1(value: FinalAuditV1) Digest {
    const scalars = finalAuditScalarsV1(value);
    const digests = finalAuditDigestsV1(value);
    return rootRegion(
        final_audit_bytes - @sizeOf(Digest),
        final_audit_domain,
        &scalars,
        digests[0 .. audit_digest_count - 1],
    );
}

/// SHA-256(body-domain || all seven rooted regions).
pub fn bodySha256V1(
    value: NativeMetalSupervisorRecoveryDeathReportV1,
) Digest {
    var body: [report_footer_offset]u8 = undefined;
    var writer: Writer = .{ .bytes = &body };
    writeBodyV1(value, &writer);
    std.debug.assert(writer.position == report_footer_offset);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(body_domain);
    hash.update(&body);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// SHA-256(report-domain || body-root).
pub fn reportSha256V1(body_sha256: Digest) Digest {
    return hashDigests(report_domain, &.{body_sha256});
}

fn resealDerivedV1(
    value: *NativeMetalSupervisorRecoveryDeathReportV1,
) void {
    value.header.component_set_sha256 = componentSetSha256V1(
        value.header.controller_sha256,
        value.header.supervisor_sha256,
        value.header.recovery_sha256,
        value.header.worker_sha256,
        value.header.metallib_sha256,
        value.header.verifier_sha256,
    );
    value.supervisor_ready.supervisor_challenge_sha256 =
        supervisorChallengeSha256V1(
            value.header.campaign_challenge_sha256,
            value.header.schedule_sha256,
            value.header.component_set_sha256,
        );
    value.supervisor_kill.supervisor_challenge_sha256 =
        value.supervisor_ready.supervisor_challenge_sha256;
    value.supervisor_kill.component_set_sha256 =
        value.header.component_set_sha256;
    value.recovery_kill.component_set_sha256 =
        value.header.component_set_sha256;
    value.supervisor_ready.machine_join_sha256 =
        machineJoinSha256V1(
            value.header.machine_sha256,
            value.header.backend_sha256,
            value.header.device_sha256,
            value.header.placement_sha256,
        );

    value.supervisor_ready.root_sha256 =
        supervisorReadySha256V1(value.supervisor_ready);
    value.supervisor_kill.supervisor_ready_sha256 =
        value.supervisor_ready.root_sha256;
    value.supervisor_kill.root_sha256 =
        supervisorKillSha256V1(value.supervisor_kill);

    const resume_grant = resumeGrantSha256V1(
        value.header.controller_authority_sha256,
        value.header.campaign_challenge_sha256,
        value.header.schedule_sha256,
        value.header.component_set_sha256,
        value.supervisor_ready.root_sha256,
        value.supervisor_kill.root_sha256,
        value.header.generation_six_selector_sha256,
        value.supervisor_ready.canonical_store_sha256,
    );
    value.header.resume_grant_sha256 = resume_grant;
    value.generation_six_audit.resume_grant_sha256 = resume_grant;
    value.recovery_ready.resume_grant_sha256 = resume_grant;
    value.recovery_kill.resume_grant_sha256 = resume_grant;

    value.generation_six_audit.root_sha256 =
        generationSixAuditSha256V1(value.generation_six_audit);
    value.recovery_ready.recovery_challenge_sha256 =
        recoveryChallengeSha256V1(
            resume_grant,
            value.generation_six_audit.root_sha256,
        );
    value.recovery_ready.root_sha256 =
        recoveryReadySha256V1(value.recovery_ready);
    value.recovery_kill.recovery_ready_sha256 =
        value.recovery_ready.root_sha256;
    value.recovery_kill.root_sha256 =
        recoveryKillSha256V1(value.recovery_kill);

    const finalizer_grant = finalizerGrantSha256V1(
        value.header.controller_authority_sha256,
        value.header.campaign_challenge_sha256,
        value.header.schedule_sha256,
        value.header.component_set_sha256,
        resume_grant,
        value.recovery_ready.root_sha256,
        value.recovery_kill.root_sha256,
        value.header.candidate_selector_sha256,
        value.recovery_ready.prepared_store_sha256,
    );
    value.header.finalizer_grant_sha256 = finalizer_grant;
    value.final_audit.finalizer_grant_sha256 = finalizer_grant;
    value.final_audit.root_sha256 =
        finalAuditSha256V1(value.final_audit);

    value.header.supervisor_ready_sha256 =
        value.supervisor_ready.root_sha256;
    value.header.supervisor_kill_sha256 =
        value.supervisor_kill.root_sha256;
    value.header.generation_six_audit_sha256 =
        value.generation_six_audit.root_sha256;
    value.header.recovery_ready_sha256 =
        value.recovery_ready.root_sha256;
    value.header.recovery_kill_sha256 =
        value.recovery_kill.root_sha256;
    value.header.final_audit_sha256 =
        value.final_audit.root_sha256;
    value.header.header_sha256 = headerSha256V1(value.header);
    value.footer.body_sha256 = bodySha256V1(value.*);
    value.footer.report_sha256 =
        reportSha256V1(value.footer.body_sha256);
}

fn validateHeaderV1(value: ReportHeaderV1) Error!void {
    const actual = headerScalarsV1(value);
    const expected = [_]u64{
        report_abi,
        report_encoded_bytes,
        allowed_flags,
        report_header_bytes,
        supervisor_ready_bytes,
        supervisor_kill_bytes,
        generation_six_audit_bytes,
        recovery_ready_bytes,
        recovery_kill_bytes,
        final_audit_bytes,
        report_footer_bytes,
        expected_segment_count,
        expected_supervisor_generation,
        expected_recovery_selected_generation,
        expected_candidate_generation,
        expected_worker_process_count,
        expected_total_sigkill_count,
        expected_total_records,
        expected_total_completed,
        expected_total_cancelled,
        expected_total_failed,
        expected_total_capacity_rejected,
        expected_total_pin_completions,
        expected_total_events,
    };
    try expectCanonicalScalars(&actual, &expected);
    const digests = headerDigestsV1(value);
    try requireNonzeroDigests(&digests);
    if (!digestEqual(value.header_sha256, headerSha256V1(value)))
        return Error.InvalidRoot;
    if (!pairwiseDistinct(&.{
        value.machine_sha256,
        value.backend_sha256,
        value.device_sha256,
        value.placement_sha256,
    }) or digestEqual(
        value.resume_grant_sha256,
        value.finalizer_grant_sha256,
    ))
        return Error.InvalidAlias;
    if (!pairwiseDistinct(&.{
        value.supervisor_ready_sha256,
        value.supervisor_kill_sha256,
        value.generation_six_audit_sha256,
        value.recovery_ready_sha256,
        value.recovery_kill_sha256,
        value.final_audit_sha256,
    }))
        return Error.InvalidAlias;
}

fn validateSupervisorReadyV1(value: SupervisorReadyV1) Error!void {
    if (!validPid(value.pid) or !validPid(value.worker_pid))
        return Error.InvalidProcess;
    const actual = supervisorReadyScalarsV1(value);
    const expected = [_]u64{
        supervisor_ready_abi,
        supervisor_ready_bytes,
        allowed_flags,
        value.pid,
        value.worker_pid,
        0,
        0,
        0,
        1,
        expected_supervisor_generation,
        expected_supervisor_generation,
        0,
        selector_wire_bytes,
        1,
        1,
        0,
    };
    try expectCanonicalScalars(&actual, &expected);
    const digests = supervisorReadyDigestsV1(value);
    try requireNonzeroDigests(&digests);
    if (!digestEqual(
        value.root_sha256,
        supervisorReadySha256V1(value),
    ))
        return Error.InvalidRoot;
}

fn validateSupervisorKillV1(value: SupervisorKillV1) Error!void {
    if (!validPid(value.pid)) return Error.InvalidProcess;
    const actual = supervisorKillScalarsV1(value);
    const expected = [_]u64{
        supervisor_kill_abi,
        supervisor_kill_bytes,
        allowed_flags,
        value.pid,
        termination_signal_kill,
        killed_returncode_bits,
        supervisor_ready_bytes,
        0,
    };
    try expectCanonicalScalars(&actual, &expected);
    const digests = supervisorKillDigestsV1(value);
    try requireNonzeroDigests(&digests);
    if (!digestEqual(value.root_sha256, supervisorKillSha256V1(value)))
        return Error.InvalidRoot;
}

fn validateGenerationSixAuditV1(
    value: GenerationSixAuditV1,
) Error!void {
    if (!validPid(value.auditor_pid)) return Error.InvalidProcess;
    const actual = generationSixAuditScalarsV1(value);
    const expected = [_]u64{
        generation_six_audit_abi,
        generation_six_audit_bytes,
        allowed_flags,
        value.auditor_pid,
        expected_supervisor_generation,
        expected_supervisor_generation,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        expected_total_records / 2,
        expected_total_completed / 2,
    };
    try expectCanonicalScalars(&actual, &expected);
    const digests = generationSixAuditDigestsV1(value);
    try requireNonzeroDigests(&digests);
    if (!digestEqual(
        value.root_sha256,
        generationSixAuditSha256V1(value),
    ))
        return Error.InvalidRoot;
}

fn validateRecoveryReadyV1(value: RecoveryReadyV1) Error!void {
    if (!validPid(value.pid) or !validPid(value.worker_pid))
        return Error.InvalidProcess;
    const actual = recoveryReadyScalarsV1(value);
    const expected = [_]u64{
        recovery_ready_abi,
        recovery_ready_bytes,
        allowed_flags,
        value.pid,
        value.worker_pid,
        0,
        0,
        0,
        1,
        expected_recovery_selected_generation,
        expected_candidate_generation,
        expected_segment_count,
        1,
        selector_wire_bytes,
        0,
        26,
    };
    try expectCanonicalScalars(&actual, &expected);
    const digests = recoveryReadyDigestsV1(value);
    try requireNonzeroDigests(&digests);
    if (!digestEqual(
        value.root_sha256,
        recoveryReadySha256V1(value),
    ))
        return Error.InvalidRoot;
}

fn validateRecoveryKillV1(value: RecoveryKillV1) Error!void {
    if (!validPid(value.pid)) return Error.InvalidProcess;
    const actual = recoveryKillScalarsV1(value);
    const expected = [_]u64{
        recovery_kill_abi,
        recovery_kill_bytes,
        allowed_flags,
        value.pid,
        termination_signal_kill,
        killed_returncode_bits,
        recovery_ready_bytes,
        0,
    };
    try expectCanonicalScalars(&actual, &expected);
    const digests = recoveryKillDigestsV1(value);
    try requireNonzeroDigests(&digests);
    if (!digestEqual(value.root_sha256, recoveryKillSha256V1(value)))
        return Error.InvalidRoot;
}

fn validateFinalAuditV1(value: FinalAuditV1) Error!void {
    if (!validPid(value.finalizer_pid) or
        !validPid(value.auditor_pid))
        return Error.InvalidProcess;
    const actual = finalAuditScalarsV1(value);
    const expected = [_]u64{
        final_audit_abi,
        final_audit_bytes,
        allowed_flags,
        value.finalizer_pid,
        value.auditor_pid,
        expected_recovery_selected_generation,
        expected_candidate_generation,
        expected_segment_count,
        1,
        1,
        1,
        1,
        0,
        0,
        expected_total_records,
        expected_total_completed,
    };
    try expectCanonicalScalars(&actual, &expected);
    const digests = finalAuditDigestsV1(value);
    try requireNonzeroDigests(&digests);
    if (!digestEqual(value.root_sha256, finalAuditSha256V1(value)))
        return Error.InvalidRoot;
}

fn validateBindingsV1(
    value: NativeMetalSupervisorRecoveryDeathReportV1,
) Error!void {
    const header = value.header;
    const supervisor_ready = value.supervisor_ready;
    const supervisor_kill = value.supervisor_kill;
    const generation_six = value.generation_six_audit;
    const recovery_ready = value.recovery_ready;
    const recovery_kill = value.recovery_kill;
    const final_audit = value.final_audit;

    const role_pids = [_]u64{
        supervisor_ready.pid,
        supervisor_ready.worker_pid,
        generation_six.auditor_pid,
        recovery_ready.pid,
        recovery_ready.worker_pid,
        final_audit.finalizer_pid,
        final_audit.auditor_pid,
    };
    if (!pairwiseDistinctU64(&role_pids) or
        supervisor_ready.pid != supervisor_kill.pid or
        recovery_ready.pid != recovery_kill.pid or
        !validPid(supervisor_kill.pid) or
        !validPid(recovery_kill.pid))
        return Error.InvalidProcess;

    if (!digestEqual(
        header.component_set_sha256,
        componentSetSha256V1(
            header.controller_sha256,
            header.supervisor_sha256,
            header.recovery_sha256,
            header.worker_sha256,
            header.metallib_sha256,
            header.verifier_sha256,
        ),
    ) or !digestEqual(
        supervisor_ready.supervisor_challenge_sha256,
        supervisorChallengeSha256V1(
            header.campaign_challenge_sha256,
            header.schedule_sha256,
            header.component_set_sha256,
        ),
    ) or !digestEqual(
        supervisor_ready.machine_join_sha256,
        machineJoinSha256V1(
            header.machine_sha256,
            header.backend_sha256,
            header.device_sha256,
            header.placement_sha256,
        ),
    ))
        return Error.InvalidBinding;

    if (!digestEqual(
        header.resume_grant_sha256,
        resumeGrantSha256V1(
            header.controller_authority_sha256,
            header.campaign_challenge_sha256,
            header.schedule_sha256,
            header.component_set_sha256,
            supervisor_ready.root_sha256,
            supervisor_kill.root_sha256,
            header.generation_six_selector_sha256,
            supervisor_ready.canonical_store_sha256,
        ),
    ) or !digestEqual(
        header.finalizer_grant_sha256,
        finalizerGrantSha256V1(
            header.controller_authority_sha256,
            header.campaign_challenge_sha256,
            header.schedule_sha256,
            header.component_set_sha256,
            header.resume_grant_sha256,
            recovery_ready.root_sha256,
            recovery_kill.root_sha256,
            header.candidate_selector_sha256,
            recovery_ready.prepared_store_sha256,
        ),
    ))
        return Error.InvalidBinding;

    if (!allEqual(header.campaign_challenge_sha256, &.{
        supervisor_kill.campaign_challenge_sha256,
        recovery_kill.campaign_challenge_sha256,
    }) or !allEqual(header.controller_sha256, &.{
        supervisor_kill.controller_sha256,
        recovery_kill.controller_sha256,
    }) or !allEqual(header.component_set_sha256, &.{
        supervisor_kill.component_set_sha256,
        recovery_kill.component_set_sha256,
    }) or !allEqual(header.worker_sha256, &.{
        supervisor_ready.worker_sha256,
        recovery_ready.worker_sha256,
    }) or !digestEqual(
        header.metallib_sha256,
        supervisor_ready.metallib_sha256,
    ))
        return Error.InvalidBinding;

    if (!digestEqual(
        header.supervisor_sha256,
        supervisor_ready.supervisor_sha256,
    ) or !digestEqual(
        header.supervisor_sha256,
        supervisor_kill.supervisor_sha256,
    ) or !digestEqual(
        header.recovery_sha256,
        recovery_ready.recovery_sha256,
    ) or !digestEqual(
        header.recovery_sha256,
        recovery_kill.recovery_sha256,
    ) or !digestEqual(
        supervisor_ready.supervisor_challenge_sha256,
        supervisor_kill.supervisor_challenge_sha256,
    ))
        return Error.InvalidBinding;

    if (!allEqual(supervisor_ready.campaign_id_sha256, &.{
        generation_six.campaign_id_sha256,
        recovery_ready.campaign_id_sha256,
        final_audit.campaign_id_sha256,
    }) or !allEqual(supervisor_ready.lock_identity_sha256, &.{
        supervisor_kill.lock_identity_sha256,
        generation_six.lock_identity_sha256,
        recovery_ready.lock_identity_sha256,
        recovery_kill.lock_identity_sha256,
    }))
        return Error.InvalidBinding;

    if (!allEqual(header.resume_grant_sha256, &.{
        generation_six.resume_grant_sha256,
        recovery_ready.resume_grant_sha256,
        recovery_kill.resume_grant_sha256,
    }) or !digestEqual(
        header.finalizer_grant_sha256,
        final_audit.finalizer_grant_sha256,
    ) or !digestEqual(
        recovery_ready.recovery_challenge_sha256,
        recoveryChallengeSha256V1(
            header.resume_grant_sha256,
            generation_six.root_sha256,
        ),
    ))
        return Error.InvalidBinding;

    if (!digestEqual(
        header.generation_six_selector_sha256,
        supervisor_ready.selector_sha256,
    ) or !digestEqual(
        header.generation_six_selector_sha256,
        generation_six.selector_sha256,
    ) or !digestEqual(
        supervisor_ready.manifest_sha256,
        generation_six.manifest_sha256,
    ) or !digestEqual(
        supervisor_ready.final_entry_sha256,
        generation_six.final_entry_sha256,
    ) or !digestEqual(
        supervisor_ready.canonical_store_sha256,
        generation_six.canonical_store_sha256,
    ))
        return Error.InvalidBinding;

    if (!digestEqual(
        recovery_ready.selected_selector_sha256,
        final_audit.predecessor_selector_sha256,
    ) or !digestEqual(
        header.candidate_selector_sha256,
        recovery_ready.candidate_selector_sha256,
    ) or !digestEqual(
        header.candidate_selector_sha256,
        final_audit.candidate_selector_sha256,
    ) or !digestEqual(
        header.candidate_selector_sha256,
        final_audit.final_selector_sha256,
    ) or !digestEqual(
        recovery_ready.candidate_manifest_sha256,
        final_audit.final_manifest_sha256,
    ) or !digestEqual(
        header.final_store_sha256,
        final_audit.final_store_sha256,
    ))
        return Error.InvalidBinding;
    if (digestEqual(
        recovery_ready.selected_manifest_sha256,
        recovery_ready.candidate_manifest_sha256,
    ) or digestEqual(
        recovery_ready.selected_selector_sha256,
        recovery_ready.candidate_selector_sha256,
    ) or digestEqual(
        recovery_ready.prepared_store_sha256,
        header.final_store_sha256,
    ))
        return Error.InvalidAlias;

    if (!digestEqual(
        supervisor_kill.supervisor_ready_sha256,
        supervisor_ready.root_sha256,
    ) or !digestEqual(
        recovery_kill.recovery_ready_sha256,
        recovery_ready.root_sha256,
    ) or !digestEqual(
        header.supervisor_ready_sha256,
        supervisor_ready.root_sha256,
    ) or !digestEqual(
        header.supervisor_kill_sha256,
        supervisor_kill.root_sha256,
    ) or !digestEqual(
        header.generation_six_audit_sha256,
        generation_six.root_sha256,
    ) or !digestEqual(
        header.recovery_ready_sha256,
        recovery_ready.root_sha256,
    ) or !digestEqual(
        header.recovery_kill_sha256,
        recovery_kill.root_sha256,
    ) or !digestEqual(
        header.final_audit_sha256,
        final_audit.root_sha256,
    ))
        return Error.InvalidBinding;
}

fn headerScalarsV1(value: ReportHeaderV1) [header_scalar_count]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.header_bytes,
        value.supervisor_ready_bytes,
        value.supervisor_kill_bytes,
        value.generation_six_audit_bytes,
        value.recovery_ready_bytes,
        value.recovery_kill_bytes,
        value.final_audit_bytes,
        value.footer_bytes,
        value.segment_count,
        value.supervisor_generation,
        value.recovery_selected_generation,
        value.candidate_generation,
        value.worker_process_count,
        value.total_sigkill_count,
        value.total_records,
        value.total_completed,
        value.total_cancelled,
        value.total_failed,
        value.total_capacity_rejected,
        value.total_pin_completions,
        value.total_events,
    };
}

fn headerDigestsV1(value: ReportHeaderV1) [header_digest_count]Digest {
    return .{
        value.campaign_challenge_sha256,
        value.schedule_sha256,
        value.controller_authority_sha256,
        value.component_set_sha256,
        value.controller_sha256,
        value.supervisor_sha256,
        value.recovery_sha256,
        value.worker_sha256,
        value.metallib_sha256,
        value.verifier_sha256,
        value.machine_sha256,
        value.backend_sha256,
        value.device_sha256,
        value.placement_sha256,
        value.resume_grant_sha256,
        value.finalizer_grant_sha256,
        value.supervisor_ready_sha256,
        value.supervisor_kill_sha256,
        value.generation_six_audit_sha256,
        value.recovery_ready_sha256,
        value.recovery_kill_sha256,
        value.final_audit_sha256,
        value.generation_six_selector_sha256,
        value.candidate_selector_sha256,
        value.final_store_sha256,
        value.header_sha256,
    };
}

fn supervisorReadyScalarsV1(
    value: SupervisorReadyV1,
) [supervisor_ready_scalar_count]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.pid,
        value.worker_pid,
        value.worker_exit_code_bits,
        value.worker_termination_signal,
        value.active_worker_count,
        value.lock_held,
        value.selected_generation,
        value.completed_segment_count,
        value.publication_inflight,
        value.selector_bytes,
        value.process_session_isolated,
        value.lock_contended,
        value.reserved,
    };
}

fn supervisorReadyDigestsV1(
    value: SupervisorReadyV1,
) [supervisor_ready_digest_count]Digest {
    return .{
        value.supervisor_challenge_sha256,
        value.supervisor_sha256,
        value.worker_sha256,
        value.metallib_sha256,
        value.campaign_id_sha256,
        value.manifest_sha256,
        value.selector_sha256,
        value.final_entry_sha256,
        value.canonical_store_sha256,
        value.lock_identity_sha256,
        value.machine_join_sha256,
        value.root_sha256,
    };
}

fn supervisorKillScalarsV1(
    value: SupervisorKillV1,
) [kill_scalar_count]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.pid,
        value.termination_signal,
        value.returncode_bits,
        value.stdout_bytes,
        value.stderr_bytes,
    };
}

fn supervisorKillDigestsV1(
    value: SupervisorKillV1,
) [kill_digest_count]Digest {
    return .{
        value.campaign_challenge_sha256,
        value.supervisor_challenge_sha256,
        value.supervisor_ready_sha256,
        value.supervisor_sha256,
        value.controller_sha256,
        value.lock_identity_sha256,
        value.component_set_sha256,
        value.root_sha256,
    };
}

fn generationSixAuditScalarsV1(
    value: GenerationSixAuditV1,
) [audit_scalar_count]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.auditor_pid,
        value.selected_generation,
        value.segment_count,
        value.require_complete,
        value.complete,
        value.shared_lock_held,
        value.unknown_file_count,
        value.temporary_file_count,
        value.hardlink_count,
        value.symlink_count,
        value.process_generation_count,
        value.record_count,
        value.completed_count,
    };
}

fn generationSixAuditDigestsV1(
    value: GenerationSixAuditV1,
) [audit_digest_count]Digest {
    return .{
        value.resume_grant_sha256,
        value.campaign_id_sha256,
        value.manifest_sha256,
        value.selector_sha256,
        value.final_entry_sha256,
        value.canonical_store_sha256,
        value.lock_identity_sha256,
        value.root_sha256,
    };
}

fn recoveryReadyScalarsV1(
    value: RecoveryReadyV1,
) [supervisor_ready_scalar_count]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.pid,
        value.worker_pid,
        value.worker_exit_code_bits,
        value.worker_termination_signal,
        value.active_worker_count,
        value.lock_held,
        value.selected_generation,
        value.candidate_generation,
        value.segment_count,
        value.controller_lock_contention_acknowledged,
        value.candidate_selector_bytes,
        value.root_sync_completed,
        value.publication_phase_index,
    };
}

fn recoveryReadyDigestsV1(
    value: RecoveryReadyV1,
) [supervisor_ready_digest_count]Digest {
    return .{
        value.resume_grant_sha256,
        value.recovery_sha256,
        value.worker_sha256,
        value.recovery_challenge_sha256,
        value.campaign_id_sha256,
        value.selected_manifest_sha256,
        value.selected_selector_sha256,
        value.candidate_manifest_sha256,
        value.candidate_selector_sha256,
        value.prepared_store_sha256,
        value.lock_identity_sha256,
        value.root_sha256,
    };
}

fn recoveryKillScalarsV1(
    value: RecoveryKillV1,
) [kill_scalar_count]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.pid,
        value.termination_signal,
        value.returncode_bits,
        value.stdout_bytes,
        value.stderr_bytes,
    };
}

fn recoveryKillDigestsV1(
    value: RecoveryKillV1,
) [kill_digest_count]Digest {
    return .{
        value.campaign_challenge_sha256,
        value.resume_grant_sha256,
        value.recovery_ready_sha256,
        value.recovery_sha256,
        value.controller_sha256,
        value.lock_identity_sha256,
        value.component_set_sha256,
        value.root_sha256,
    };
}

fn finalAuditScalarsV1(
    value: FinalAuditV1,
) [audit_scalar_count]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.finalizer_pid,
        value.auditor_pid,
        value.predecessor_generation,
        value.final_generation,
        value.segment_count,
        value.rollforward_count,
        value.selector_replace_count,
        value.root_sync_count,
        value.complete,
        value.unknown_file_count,
        value.temporary_file_count,
        value.record_count,
        value.completed_count,
    };
}

fn finalAuditDigestsV1(
    value: FinalAuditV1,
) [audit_digest_count]Digest {
    return .{
        value.finalizer_grant_sha256,
        value.campaign_id_sha256,
        value.predecessor_selector_sha256,
        value.candidate_selector_sha256,
        value.final_manifest_sha256,
        value.final_selector_sha256,
        value.final_store_sha256,
        value.root_sha256,
    };
}

fn encodeUncheckedV1(
    value: NativeMetalSupervisorRecoveryDeathReportV1,
    output: []u8,
) void {
    std.debug.assert(output.len == report_encoded_bytes);
    var writer: Writer = .{ .bytes = output };
    writeBodyV1(value, &writer);
    writer.writeDigest(value.footer.body_sha256);
    writer.writeDigest(value.footer.report_sha256);
    std.debug.assert(writer.position == report_encoded_bytes);
}

fn writeBodyV1(
    value: NativeMetalSupervisorRecoveryDeathReportV1,
    writer: *Writer,
) void {
    writer.writeScalars(&headerScalarsV1(value.header));
    writer.writeDigests(&headerDigestsV1(value.header));
    writer.writeScalars(
        &supervisorReadyScalarsV1(value.supervisor_ready),
    );
    writer.writeDigests(
        &supervisorReadyDigestsV1(value.supervisor_ready),
    );
    writer.writeScalars(
        &supervisorKillScalarsV1(value.supervisor_kill),
    );
    writer.writeDigests(
        &supervisorKillDigestsV1(value.supervisor_kill),
    );
    writer.writeScalars(
        &generationSixAuditScalarsV1(value.generation_six_audit),
    );
    writer.writeDigests(
        &generationSixAuditDigestsV1(value.generation_six_audit),
    );
    writer.writeScalars(
        &recoveryReadyScalarsV1(value.recovery_ready),
    );
    writer.writeDigests(
        &recoveryReadyDigestsV1(value.recovery_ready),
    );
    writer.writeScalars(
        &recoveryKillScalarsV1(value.recovery_kill),
    );
    writer.writeDigests(
        &recoveryKillDigestsV1(value.recovery_kill),
    );
    writer.writeScalars(&finalAuditScalarsV1(value.final_audit));
    writer.writeDigests(&finalAuditDigestsV1(value.final_audit));
}

fn readHeaderV1(reader: *Reader) ReportHeaderV1 {
    var scalars: [header_scalar_count]u64 = undefined;
    var digests: [header_digest_count]Digest = undefined;
    reader.readScalars(&scalars);
    reader.readDigests(&digests);
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .header_bytes = scalars[3],
        .supervisor_ready_bytes = scalars[4],
        .supervisor_kill_bytes = scalars[5],
        .generation_six_audit_bytes = scalars[6],
        .recovery_ready_bytes = scalars[7],
        .recovery_kill_bytes = scalars[8],
        .final_audit_bytes = scalars[9],
        .footer_bytes = scalars[10],
        .segment_count = scalars[11],
        .supervisor_generation = scalars[12],
        .recovery_selected_generation = scalars[13],
        .candidate_generation = scalars[14],
        .worker_process_count = scalars[15],
        .total_sigkill_count = scalars[16],
        .total_records = scalars[17],
        .total_completed = scalars[18],
        .total_cancelled = scalars[19],
        .total_failed = scalars[20],
        .total_capacity_rejected = scalars[21],
        .total_pin_completions = scalars[22],
        .total_events = scalars[23],
        .campaign_challenge_sha256 = digests[0],
        .schedule_sha256 = digests[1],
        .controller_authority_sha256 = digests[2],
        .component_set_sha256 = digests[3],
        .controller_sha256 = digests[4],
        .supervisor_sha256 = digests[5],
        .recovery_sha256 = digests[6],
        .worker_sha256 = digests[7],
        .metallib_sha256 = digests[8],
        .verifier_sha256 = digests[9],
        .machine_sha256 = digests[10],
        .backend_sha256 = digests[11],
        .device_sha256 = digests[12],
        .placement_sha256 = digests[13],
        .resume_grant_sha256 = digests[14],
        .finalizer_grant_sha256 = digests[15],
        .supervisor_ready_sha256 = digests[16],
        .supervisor_kill_sha256 = digests[17],
        .generation_six_audit_sha256 = digests[18],
        .recovery_ready_sha256 = digests[19],
        .recovery_kill_sha256 = digests[20],
        .final_audit_sha256 = digests[21],
        .generation_six_selector_sha256 = digests[22],
        .candidate_selector_sha256 = digests[23],
        .final_store_sha256 = digests[24],
        .header_sha256 = digests[25],
    };
}

fn readSupervisorReadyV1(reader: *Reader) SupervisorReadyV1 {
    var scalars: [supervisor_ready_scalar_count]u64 = undefined;
    var digests: [supervisor_ready_digest_count]Digest = undefined;
    reader.readScalars(&scalars);
    reader.readDigests(&digests);
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .pid = scalars[3],
        .worker_pid = scalars[4],
        .worker_exit_code_bits = scalars[5],
        .worker_termination_signal = scalars[6],
        .active_worker_count = scalars[7],
        .lock_held = scalars[8],
        .selected_generation = scalars[9],
        .completed_segment_count = scalars[10],
        .publication_inflight = scalars[11],
        .selector_bytes = scalars[12],
        .process_session_isolated = scalars[13],
        .lock_contended = scalars[14],
        .reserved = scalars[15],
        .supervisor_challenge_sha256 = digests[0],
        .supervisor_sha256 = digests[1],
        .worker_sha256 = digests[2],
        .metallib_sha256 = digests[3],
        .campaign_id_sha256 = digests[4],
        .manifest_sha256 = digests[5],
        .selector_sha256 = digests[6],
        .final_entry_sha256 = digests[7],
        .canonical_store_sha256 = digests[8],
        .lock_identity_sha256 = digests[9],
        .machine_join_sha256 = digests[10],
        .root_sha256 = digests[11],
    };
}

fn readSupervisorKillV1(reader: *Reader) SupervisorKillV1 {
    var scalars: [kill_scalar_count]u64 = undefined;
    var digests: [kill_digest_count]Digest = undefined;
    reader.readScalars(&scalars);
    reader.readDigests(&digests);
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .pid = scalars[3],
        .termination_signal = scalars[4],
        .returncode_bits = scalars[5],
        .stdout_bytes = scalars[6],
        .stderr_bytes = scalars[7],
        .campaign_challenge_sha256 = digests[0],
        .supervisor_challenge_sha256 = digests[1],
        .supervisor_ready_sha256 = digests[2],
        .supervisor_sha256 = digests[3],
        .controller_sha256 = digests[4],
        .lock_identity_sha256 = digests[5],
        .component_set_sha256 = digests[6],
        .root_sha256 = digests[7],
    };
}

fn readGenerationSixAuditV1(
    reader: *Reader,
) GenerationSixAuditV1 {
    var scalars: [audit_scalar_count]u64 = undefined;
    var digests: [audit_digest_count]Digest = undefined;
    reader.readScalars(&scalars);
    reader.readDigests(&digests);
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .auditor_pid = scalars[3],
        .selected_generation = scalars[4],
        .segment_count = scalars[5],
        .require_complete = scalars[6],
        .complete = scalars[7],
        .shared_lock_held = scalars[8],
        .unknown_file_count = scalars[9],
        .temporary_file_count = scalars[10],
        .hardlink_count = scalars[11],
        .symlink_count = scalars[12],
        .process_generation_count = scalars[13],
        .record_count = scalars[14],
        .completed_count = scalars[15],
        .resume_grant_sha256 = digests[0],
        .campaign_id_sha256 = digests[1],
        .manifest_sha256 = digests[2],
        .selector_sha256 = digests[3],
        .final_entry_sha256 = digests[4],
        .canonical_store_sha256 = digests[5],
        .lock_identity_sha256 = digests[6],
        .root_sha256 = digests[7],
    };
}

fn readRecoveryReadyV1(reader: *Reader) RecoveryReadyV1 {
    var scalars: [supervisor_ready_scalar_count]u64 = undefined;
    var digests: [supervisor_ready_digest_count]Digest = undefined;
    reader.readScalars(&scalars);
    reader.readDigests(&digests);
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .pid = scalars[3],
        .worker_pid = scalars[4],
        .worker_exit_code_bits = scalars[5],
        .worker_termination_signal = scalars[6],
        .active_worker_count = scalars[7],
        .lock_held = scalars[8],
        .selected_generation = scalars[9],
        .candidate_generation = scalars[10],
        .segment_count = scalars[11],
        .controller_lock_contention_acknowledged = scalars[12],
        .candidate_selector_bytes = scalars[13],
        .root_sync_completed = scalars[14],
        .publication_phase_index = scalars[15],
        .resume_grant_sha256 = digests[0],
        .recovery_sha256 = digests[1],
        .worker_sha256 = digests[2],
        .recovery_challenge_sha256 = digests[3],
        .campaign_id_sha256 = digests[4],
        .selected_manifest_sha256 = digests[5],
        .selected_selector_sha256 = digests[6],
        .candidate_manifest_sha256 = digests[7],
        .candidate_selector_sha256 = digests[8],
        .prepared_store_sha256 = digests[9],
        .lock_identity_sha256 = digests[10],
        .root_sha256 = digests[11],
    };
}

fn readRecoveryKillV1(reader: *Reader) RecoveryKillV1 {
    var scalars: [kill_scalar_count]u64 = undefined;
    var digests: [kill_digest_count]Digest = undefined;
    reader.readScalars(&scalars);
    reader.readDigests(&digests);
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .pid = scalars[3],
        .termination_signal = scalars[4],
        .returncode_bits = scalars[5],
        .stdout_bytes = scalars[6],
        .stderr_bytes = scalars[7],
        .campaign_challenge_sha256 = digests[0],
        .resume_grant_sha256 = digests[1],
        .recovery_ready_sha256 = digests[2],
        .recovery_sha256 = digests[3],
        .controller_sha256 = digests[4],
        .lock_identity_sha256 = digests[5],
        .component_set_sha256 = digests[6],
        .root_sha256 = digests[7],
    };
}

fn readFinalAuditV1(reader: *Reader) FinalAuditV1 {
    var scalars: [audit_scalar_count]u64 = undefined;
    var digests: [audit_digest_count]Digest = undefined;
    reader.readScalars(&scalars);
    reader.readDigests(&digests);
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .finalizer_pid = scalars[3],
        .auditor_pid = scalars[4],
        .predecessor_generation = scalars[5],
        .final_generation = scalars[6],
        .segment_count = scalars[7],
        .rollforward_count = scalars[8],
        .selector_replace_count = scalars[9],
        .root_sync_count = scalars[10],
        .complete = scalars[11],
        .unknown_file_count = scalars[12],
        .temporary_file_count = scalars[13],
        .record_count = scalars[14],
        .completed_count = scalars[15],
        .finalizer_grant_sha256 = digests[0],
        .campaign_id_sha256 = digests[1],
        .predecessor_selector_sha256 = digests[2],
        .candidate_selector_sha256 = digests[3],
        .final_manifest_sha256 = digests[4],
        .final_selector_sha256 = digests[5],
        .final_store_sha256 = digests[6],
        .root_sha256 = digests[7],
    };
}

fn rootRegion(
    comptime rooted_bytes: usize,
    domain: []const u8,
    scalars: []const u64,
    digests: []const Digest,
) Digest {
    var encoded: [rooted_bytes]u8 = undefined;
    var writer: Writer = .{ .bytes = &encoded };
    writer.writeScalars(scalars);
    writer.writeDigests(digests);
    std.debug.assert(writer.position == rooted_bytes);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(&encoded);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn hashDigests(domain: []const u8, digests: []const Digest) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    for (digests) |digest| hash.update(&digest);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn expectCanonicalScalars(
    actual: []const u64,
    expected: []const u64,
) Error!void {
    if (actual.len != expected.len)
        return Error.InvalidLength;
    if (actual[0] != expected[0]) return Error.InvalidAbi;
    if (actual[1] != expected[1]) return Error.InvalidLength;
    if (actual[2] != expected[2]) return Error.InvalidFlags;
    if (!std.mem.eql(u64, actual[3..], expected[3..]))
        return Error.InvalidState;
}

fn requireNonzeroDigests(values: []const Digest) Error!void {
    for (values) |value| {
        if (digestIsZero(value)) return Error.InvalidIdentity;
    }
}

fn validPid(value: u64) bool {
    return value != 0 and value != std.math.maxInt(u64);
}

fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn allEqual(expected: Digest, values: []const Digest) bool {
    for (values) |value| {
        if (!digestEqual(expected, value)) return false;
    }
    return true;
}

fn pairwiseDistinct(values: []const Digest) bool {
    for (values, 0..) |left, left_index| {
        for (values[left_index + 1 ..]) |right| {
            if (digestEqual(left, right)) return false;
        }
    }
    return true;
}

fn pairwiseDistinctU64(values: []const u64) bool {
    for (values, 0..) |left, left_index| {
        for (values[left_index + 1 ..]) |right| {
            if (left == right) return false;
        }
    }
    return true;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeScalars(self: *Writer, values: []const u64) void {
        for (values) |value| self.writeU64(value);
    }

    fn writeDigests(self: *Writer, values: []const Digest) void {
        for (values) |value| self.writeDigest(value);
    }

    fn writeU64(self: *Writer, value: u64) void {
        const end = self.position + @sizeOf(u64);
        std.mem.writeInt(
            u64,
            self.bytes[self.position..end][0..8],
            value,
            .little,
        );
        self.position = end;
    }

    fn writeDigest(self: *Writer, value: Digest) void {
        const end = self.position + @sizeOf(Digest);
        @memcpy(self.bytes[self.position..end], &value);
        self.position = end;
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readScalars(self: *Reader, output: []u64) void {
        for (output) |*value| value.* = self.readU64();
    }

    fn readDigests(self: *Reader, output: []Digest) void {
        for (output) |*value| value.* = self.readDigest();
    }

    fn readU64(self: *Reader) u64 {
        const end = self.position + @sizeOf(u64);
        const result = std.mem.readInt(
            u64,
            self.bytes[self.position..end][0..8],
            .little,
        );
        self.position = end;
        return result;
    }

    fn readDigest(self: *Reader) Digest {
        const end = self.position + @sizeOf(Digest);
        var result: Digest = undefined;
        @memcpy(&result, self.bytes[self.position..end]);
        self.position = end;
        return result;
    }
};

fn testDigest(label: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(label, &result, .{});
    return result;
}

fn testReport() Error!NativeMetalSupervisorRecoveryDeathReportV1 {
    const campaign = testDigest("campaign-challenge");
    const schedule = testDigest("schedule");
    const authority = testDigest("controller-authority");
    const controller = testDigest("controller");
    const supervisor = testDigest("supervisor");
    const recovery = testDigest("recovery");
    const worker = testDigest("worker");
    const metallib = testDigest("metallib");
    const verifier = testDigest("verifier");
    const campaign_id = testDigest("campaign-id");
    const lock_identity = testDigest("lock-identity");
    const manifest_six = testDigest("generation-six-manifest");
    const selector_six = testDigest("generation-six-selector");
    const entry_six = testDigest("generation-six-entry");
    const store_six = testDigest("generation-six-store");
    const manifest_eleven = testDigest("generation-eleven-manifest");
    const selector_eleven = testDigest("generation-eleven-selector");
    const manifest_twelve = testDigest("generation-twelve-manifest");
    const selector_twelve = testDigest("generation-twelve-selector");
    const prepared_store =
        testDigest("generation-twelve-prepared-store");
    const final_store = testDigest("generation-twelve-final-store");

    return sealReportV1(.{
        .header = .{
            .campaign_challenge_sha256 = campaign,
            .schedule_sha256 = schedule,
            .controller_authority_sha256 = authority,
            .controller_sha256 = controller,
            .supervisor_sha256 = supervisor,
            .recovery_sha256 = recovery,
            .worker_sha256 = worker,
            .metallib_sha256 = metallib,
            .verifier_sha256 = verifier,
            .machine_sha256 = testDigest("machine"),
            .backend_sha256 = testDigest("backend"),
            .device_sha256 = testDigest("device"),
            .placement_sha256 = testDigest("placement"),
            .generation_six_selector_sha256 = selector_six,
            .candidate_selector_sha256 = selector_twelve,
            .final_store_sha256 = final_store,
        },
        .supervisor_ready = .{
            .pid = 1_001,
            .worker_pid = 1_002,
            .supervisor_sha256 = supervisor,
            .worker_sha256 = worker,
            .metallib_sha256 = metallib,
            .campaign_id_sha256 = campaign_id,
            .manifest_sha256 = manifest_six,
            .selector_sha256 = selector_six,
            .final_entry_sha256 = entry_six,
            .canonical_store_sha256 = store_six,
            .lock_identity_sha256 = lock_identity,
        },
        .supervisor_kill = .{
            .pid = 1_001,
            .campaign_challenge_sha256 = campaign,
            .supervisor_sha256 = supervisor,
            .controller_sha256 = controller,
            .lock_identity_sha256 = lock_identity,
        },
        .generation_six_audit = .{
            .auditor_pid = 1_003,
            .campaign_id_sha256 = campaign_id,
            .manifest_sha256 = manifest_six,
            .selector_sha256 = selector_six,
            .final_entry_sha256 = entry_six,
            .canonical_store_sha256 = store_six,
            .lock_identity_sha256 = lock_identity,
        },
        .recovery_ready = .{
            .pid = 2_001,
            .worker_pid = 2_002,
            .recovery_sha256 = recovery,
            .worker_sha256 = worker,
            .campaign_id_sha256 = campaign_id,
            .selected_manifest_sha256 = manifest_eleven,
            .selected_selector_sha256 = selector_eleven,
            .candidate_manifest_sha256 = manifest_twelve,
            .candidate_selector_sha256 = selector_twelve,
            .prepared_store_sha256 = prepared_store,
            .lock_identity_sha256 = lock_identity,
        },
        .recovery_kill = .{
            .pid = 2_001,
            .campaign_challenge_sha256 = campaign,
            .recovery_sha256 = recovery,
            .controller_sha256 = controller,
            .lock_identity_sha256 = lock_identity,
        },
        .final_audit = .{
            .finalizer_pid = 3_001,
            .auditor_pid = 3_002,
            .campaign_id_sha256 = campaign_id,
            .predecessor_selector_sha256 = selector_eleven,
            .candidate_selector_sha256 = selector_twelve,
            .final_manifest_sha256 = manifest_twelve,
            .final_selector_sha256 = selector_twelve,
            .final_store_sha256 = final_store,
        },
    });
}

fn resealAfterAuditKeepingRecoveryChallengeV1(
    value: *NativeMetalSupervisorRecoveryDeathReportV1,
) void {
    value.generation_six_audit.root_sha256 =
        generationSixAuditSha256V1(value.generation_six_audit);
    value.recovery_ready.root_sha256 =
        recoveryReadySha256V1(value.recovery_ready);
    value.recovery_kill.recovery_ready_sha256 =
        value.recovery_ready.root_sha256;
    value.recovery_kill.root_sha256 =
        recoveryKillSha256V1(value.recovery_kill);

    const finalizer_grant = finalizerGrantSha256V1(
        value.header.controller_authority_sha256,
        value.header.campaign_challenge_sha256,
        value.header.schedule_sha256,
        value.header.component_set_sha256,
        value.header.resume_grant_sha256,
        value.recovery_ready.root_sha256,
        value.recovery_kill.root_sha256,
        value.header.candidate_selector_sha256,
        value.recovery_ready.prepared_store_sha256,
    );
    value.header.finalizer_grant_sha256 = finalizer_grant;
    value.final_audit.finalizer_grant_sha256 = finalizer_grant;
    value.final_audit.root_sha256 =
        finalAuditSha256V1(value.final_audit);

    value.header.generation_six_audit_sha256 =
        value.generation_six_audit.root_sha256;
    value.header.recovery_ready_sha256 =
        value.recovery_ready.root_sha256;
    value.header.recovery_kill_sha256 =
        value.recovery_kill.root_sha256;
    value.header.final_audit_sha256 =
        value.final_audit.root_sha256;
    value.header.header_sha256 = headerSha256V1(value.header);
    value.footer.body_sha256 = bodySha256V1(value.*);
    value.footer.report_sha256 =
        reportSha256V1(value.footer.body_sha256);
}

fn expectDecodeFailure(encoded: []const u8) !void {
    if (decodeReportV1(encoded)) |_| {
        return error.TestExpectedDecodeFailure;
    } else |_| {}
}

fn rolePidsV1(
    value: NativeMetalSupervisorRecoveryDeathReportV1,
) [7]u64 {
    return .{
        value.supervisor_ready.pid,
        value.supervisor_ready.worker_pid,
        value.generation_six_audit.auditor_pid,
        value.recovery_ready.pid,
        value.recovery_ready.worker_pid,
        value.final_audit.finalizer_pid,
        value.final_audit.auditor_pid,
    };
}

fn setRolePidV1(
    value: *NativeMetalSupervisorRecoveryDeathReportV1,
    role_index: usize,
    pid: u64,
) void {
    switch (role_index) {
        0 => {
            value.supervisor_ready.pid = pid;
            value.supervisor_kill.pid = pid;
        },
        1 => value.supervisor_ready.worker_pid = pid,
        2 => value.generation_six_audit.auditor_pid = pid,
        3 => {
            value.recovery_ready.pid = pid;
            value.recovery_kill.pid = pid;
        },
        4 => value.recovery_ready.worker_pid = pid,
        5 => value.final_audit.finalizer_pid = pid,
        6 => value.final_audit.auditor_pid = pid,
        else => unreachable,
    }
}

fn expectDigestHex(expected_hex: *const [64]u8, actual: Digest) !void {
    var expected: Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    try std.testing.expectEqual(expected, actual);
}

test "supervisor recovery death report has exact fixed geometry" {
    try std.testing.expectEqual(
        @as(usize, 3_520),
        report_encoded_bytes,
    );
    try std.testing.expectEqual(
        report_encoded_bytes,
        report_footer_offset + report_footer_bytes,
    );
}

test "supervisor recovery death report matches independent golden roots" {
    const report = try testReport();
    try expectDigestHex(
        "7f1c4e2d1b52275e2ab94718f0ff2d6b77a17742f18ab5dbaa54c17d24846d01",
        report.supervisor_ready.root_sha256,
    );
    try expectDigestHex(
        "9330d28b6d058b486fa0aaebc9703cc980e6e5c958bbc0f56fd77417336d648c",
        report.supervisor_kill.root_sha256,
    );
    try expectDigestHex(
        "56d96ce5093e4c5b22b2e8fba687ac285d79fdd2c8fc1af68cbb1b380d41d30e",
        report.generation_six_audit.root_sha256,
    );
    try expectDigestHex(
        "103e9e98f684867d61118343e1df79a809eb9e6aa69335a61e488edf3f4821dc",
        report.recovery_ready.root_sha256,
    );
    try expectDigestHex(
        "4e4039341a67b72b3e95a8f9d8fe84e77f8344dd86fd1372b7bc2e23097c6cb4",
        report.recovery_kill.root_sha256,
    );
    try expectDigestHex(
        "fea73e6ef648f43f1b7086e7e7f7f7d354b978befc546966af0027a65ad0892f",
        report.final_audit.root_sha256,
    );
    try expectDigestHex(
        "f88c7df352973ae119ef95a05cc1576e79afed0c496afbc4fb3f998b11ac11e8",
        report.header.header_sha256,
    );
    try expectDigestHex(
        "f17873d08cf38205b02162fc8035517c49096c00898f476913228d0a1071b23b",
        report.footer.body_sha256,
    );
    try expectDigestHex(
        "0260c4a008fa5b27c78ed793feceb1107bf7615b373b76982f4d96a2b9cf58c9",
        report.footer.report_sha256,
    );
}

test "supervisor recovery death report round trips canonically" {
    const report = try testReport();
    try validateReportV1(report);
    var wire: [report_encoded_bytes]u8 = undefined;
    const encoded = try encodeReportV1(report, &wire);
    try std.testing.expectEqual(
        @as(usize, report_encoded_bytes),
        encoded.len,
    );
    try std.testing.expectEqualDeep(
        report,
        try decodeReportV1(encoded),
    );
}

test "supervisor recovery death report rejects every one-bit mutation" {
    const report = try testReport();
    var wire: [report_encoded_bytes]u8 = undefined;
    _ = try encodeReportV1(report, &wire);

    for (0..report_encoded_bytes) |byte_index| {
        for (0..8) |bit_index| {
            var mutated = wire;
            mutated[byte_index] ^=
                @as(u8, 1) << @intCast(bit_index);
            try expectDecodeFailure(&mutated);
        }
    }
}

test "supervisor recovery death report rejects every wrong length" {
    const report = try testReport();
    var wire: [report_encoded_bytes]u8 = undefined;
    _ = try encodeReportV1(report, &wire);

    for (0..report_encoded_bytes) |length|
        try std.testing.expectError(
            Error.InvalidLength,
            decodeReportV1(wire[0..length]),
        );

    var extended: [report_encoded_bytes + 1]u8 = undefined;
    @memcpy(extended[0..report_encoded_bytes], &wire);
    extended[report_encoded_bytes] = 0;
    try std.testing.expectError(
        Error.InvalidLength,
        decodeReportV1(&extended),
    );
}

test "supervisor recovery death report rejects rerooted semantic drift" {
    var report = try testReport();
    report.header.total_events -= 1;
    resealDerivedV1(&report);
    var wire: [report_encoded_bytes]u8 = undefined;
    encodeUncheckedV1(report, &wire);
    try std.testing.expectError(
        Error.InvalidState,
        decodeReportV1(&wire),
    );

    report = try testReport();
    report.recovery_ready.publication_phase_index -= 1;
    resealDerivedV1(&report);
    encodeUncheckedV1(report, &wire);
    try std.testing.expectError(
        Error.InvalidState,
        decodeReportV1(&wire),
    );

    report = try testReport();
    report.final_audit.selector_replace_count = 2;
    resealDerivedV1(&report);
    encodeUncheckedV1(report, &wire);
    try std.testing.expectError(
        Error.InvalidState,
        decodeReportV1(&wire),
    );
}

test "supervisor recovery death report rejects rerooted substitutions" {
    var report = try testReport();
    report.recovery_ready.selected_selector_sha256 =
        testDigest("substituted predecessor");
    resealDerivedV1(&report);
    var wire: [report_encoded_bytes]u8 = undefined;
    encodeUncheckedV1(report, &wire);
    try std.testing.expectError(
        Error.InvalidBinding,
        decodeReportV1(&wire),
    );

    report = try testReport();
    report.header.backend_sha256 = report.header.machine_sha256;
    resealDerivedV1(&report);
    encodeUncheckedV1(report, &wire);
    try std.testing.expectError(
        Error.InvalidAlias,
        decodeReportV1(&wire),
    );

    report = try testReport();
    report.header.final_store_sha256 =
        report.recovery_ready.prepared_store_sha256;
    report.final_audit.final_store_sha256 =
        report.recovery_ready.prepared_store_sha256;
    resealDerivedV1(&report);
    encodeUncheckedV1(report, &wire);
    try std.testing.expectError(
        Error.InvalidAlias,
        decodeReportV1(&wire),
    );
}

test "controller supervisor and recovery may share one executable identity" {
    var report = try testReport();
    const shared = testDigest("shared-role-component");
    report.header.controller_sha256 = shared;
    report.header.supervisor_sha256 = shared;
    report.header.recovery_sha256 = shared;
    report.supervisor_ready.supervisor_sha256 = shared;
    report.supervisor_kill.supervisor_sha256 = shared;
    report.supervisor_kill.controller_sha256 = shared;
    report.recovery_ready.recovery_sha256 = shared;
    report.recovery_kill.recovery_sha256 = shared;
    report.recovery_kill.controller_sha256 = shared;
    report = try sealReportV1(report);

    var wire: [report_encoded_bytes]u8 = undefined;
    _ = try encodeReportV1(report, &wire);
    try std.testing.expectEqualDeep(
        report,
        try decodeReportV1(&wire),
    );
}

test "all seven observed process role PIDs are pairwise fresh" {
    const baseline = try testReport();
    const pids = rolePidsV1(baseline);
    var wire: [report_encoded_bytes]u8 = undefined;

    for (0..pids.len) |left_index| {
        for (left_index + 1..pids.len) |right_index| {
            var report = baseline;
            setRolePidV1(&report, right_index, pids[left_index]);
            resealDerivedV1(&report);
            encodeUncheckedV1(report, &wire);
            try std.testing.expectError(
                Error.InvalidProcess,
                decodeReportV1(&wire),
            );
        }
    }
}

test "recovery challenge rejects stale and spliced generation-six audits" {
    var report = try testReport();
    const retained_challenge =
        report.recovery_ready.recovery_challenge_sha256;
    report.generation_six_audit.auditor_pid = 4_001;
    resealAfterAuditKeepingRecoveryChallengeV1(&report);
    try std.testing.expectEqual(
        retained_challenge,
        report.recovery_ready.recovery_challenge_sha256,
    );
    var wire: [report_encoded_bytes]u8 = undefined;
    encodeUncheckedV1(report, &wire);
    try std.testing.expectError(
        Error.InvalidBinding,
        decodeReportV1(&wire),
    );

    report = try testReport();
    report.recovery_ready.recovery_challenge_sha256 =
        testDigest("spliced-recovery-challenge");
    resealAfterAuditKeepingRecoveryChallengeV1(&report);
    encodeUncheckedV1(report, &wire);
    try std.testing.expectError(
        Error.InvalidBinding,
        decodeReportV1(&wire),
    );
}
