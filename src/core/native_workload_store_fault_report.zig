//! Fixed-width durable-store fault evidence for native workload campaigns.
//!
//! This sidecar deliberately does not extend or reinterpret the W7 campaign
//! manifest, attempt, or selector V1 wires. It binds one prepared selector
//! transition, an ordered matrix of controlled storage faults, the raw
//! selector accepted after each fault, and a fresh-process roll-forward to the
//! exact prepared successor. The embedded selector wires are validated with
//! the existing selector V1 codec. Their manifests and filesystem snapshots
//! remain externally supplied objects that an outer verifier must resolve.

const std = @import("std");
const campaign = @import("native_workload_campaign_manifest.zig");

pub const Digest = campaign.Digest;
pub const zero_digest = campaign.zero_digest;
pub const SelectorWireV1 = [campaign.selector_bytes]u8;

pub const report_abi: u64 = 0x4757_4652_0000_0001;
pub const case_abi: u64 = 0x4757_4643_0000_0001;

pub const report_header_bytes: usize = 960;
pub const case_bytes: usize = 512;
pub const report_footer_bytes: usize = 64;
pub const selector_pair_bytes: usize = 2 * campaign.selector_bytes;
pub const report_fixed_bytes: usize =
    report_header_bytes + selector_pair_bytes + report_footer_bytes;
pub const max_case_count: usize = 128;
pub const allowed_flags: u64 = 0;
pub const injected_errno_exit_code: u64 = 74;
pub const termination_signal_kill: u64 = 9;
pub const running_exit_code_bits: u64 = std.math.maxInt(u64);
pub const posix_errno_eio: u64 = 5;
pub const posix_errno_enospc: u64 = 28;

pub const state_mask_before: u64 = 1 << 0;
pub const state_mask_after: u64 = 1 << 1;
pub const state_mask_either: u64 =
    state_mask_before | state_mask_after;

pub const provenance_native_host_filesystem: u64 = 1 << 0;
pub const provenance_controlled_software: u64 = 1 << 1;
pub const provenance_derived_synthetic_fault: u64 = 1 << 2;
pub const provenance_fresh_process_recovery: u64 = 1 << 3;
pub const provenance_real_os_process_signal: u64 = 1 << 4;
pub const allowed_provenance_bits: u64 =
    provenance_native_host_filesystem |
    provenance_controlled_software |
    provenance_derived_synthetic_fault |
    provenance_fresh_process_recovery |
    provenance_real_os_process_signal;
pub const errno_provenance: u64 =
    provenance_native_host_filesystem |
    provenance_controlled_software |
    provenance_derived_synthetic_fault |
    provenance_fresh_process_recovery;
pub const signal_provenance: u64 =
    provenance_native_host_filesystem |
    provenance_controlled_software |
    provenance_fresh_process_recovery |
    provenance_real_os_process_signal;

const matrix_id_domain =
    "glacier-native-workload-store-fault-matrix-id-v1\x00";
const failpoint_domain =
    "glacier-native-workload-store-fault-failpoint-v1\x00";
const case_domain =
    "glacier-native-workload-store-fault-case-v1\x00";
const report_body_domain =
    "glacier-native-workload-store-fault-report-body-v1\x00";
const report_footer_domain =
    "glacier-native-workload-store-fault-report-footer-v1\x00";

comptime {
    if (report_header_bytes !=
        24 * @sizeOf(u64) + 24 * @sizeOf(Digest))
        @compileError("store-fault report header layout drift");
    if (case_bytes != 24 * @sizeOf(u64) + 10 * @sizeOf(Digest))
        @compileError("store-fault case layout drift");
    if (report_fixed_bytes != 1_408)
        @compileError("store-fault fixed report layout drift");
}

pub const Error = error{
    ArithmeticOverflow,
    CapacityExceeded,
    InvalidAbi,
    InvalidBodyDigest,
    InvalidCase,
    InvalidChain,
    InvalidCounts,
    InvalidEnum,
    InvalidFlags,
    InvalidFooterDigest,
    InvalidHeader,
    InvalidIdentity,
    InvalidLength,
    InvalidRoot,
    InvalidSelector,
};

pub const ObjectKindV1 = enum(u64) {
    segment = 1,
    environment = 2,
    manifest = 3,
    selector = 4,
    store_root = 5,
};

pub const OperationKindV1 = enum(u64) {
    create = 1,
    write = 2,
    file_sync = 3,
    link = 4,
    replace = 5,
    directory_sync = 6,
    unlink = 7,
};

pub const FaultTimingV1 = enum(u64) {
    before = 1,
    after = 2,
};

pub const FaultKindV1 = enum(u64) {
    injected_errno = 1,
    partial_write_errno = 2,
    forced_signal = 3,
};

pub const ErrorClassV1 = enum(u64) {
    none = 0,
    io = 1,
    storage_full = 2,
};

pub const NativeErrorDomainV1 = enum(u64) {
    none = 0,
    posix_errno = 1,
};

pub const SelectorStateV1 = enum(u64) {
    before = 1,
    after = 2,
};

pub const RecoveryDispositionV1 = enum(u64) {
    unchanged_before = 1,
    cleaned_to_before = 2,
    unchanged_after = 3,
    cleaned_to_after = 4,
};

/// Canonical 960-byte report header.
pub const ReportHeaderV1 = struct {
    abi_version: u64 = report_abi,
    encoded_bytes: u64 = 0,
    flags: u64 = allowed_flags,
    case_count: u64 = 0,
    case_wire_bytes: u64 = case_bytes,
    selector_wire_bytes: u64 = campaign.selector_bytes,
    generation_before: u64,
    generation_after: u64,
    failpoint_count: u64 = 0,
    errno_case_count: u64 = 0,
    signal_case_count: u64 = 0,
    expected_before_only_count: u64 = 0,
    expected_after_only_count: u64 = 0,
    expected_either_count: u64 = 0,
    observed_before_count: u64 = 0,
    observed_after_count: u64 = 0,
    recovered_before_count: u64 = 0,
    recovered_after_count: u64 = 0,
    synthetic_fault_count: u64 = 0,
    real_signal_count: u64 = 0,
    store_max_bytes: u64,
    store_max_files: u64,
    total_trigger_count: u64 = 0,
    reserved: u64 = 0,

    matrix_challenge_sha256: Digest,
    schedule_sha256: Digest,
    matrix_id_sha256: Digest = zero_digest,
    campaign_id_sha256: Digest,
    plan_sha256: Digest,
    manifest_before_sha256: Digest,
    manifest_after_sha256: Digest,
    selector_before_wire_sha256: Digest,
    selector_after_wire_sha256: Digest,
    canonical_store_before_sha256: Digest,
    canonical_store_after_sha256: Digest,
    transition_entry_sha256: Digest,
    worker_sha256: Digest,
    backend_library_sha256: Digest,
    campaign_codec_sha256: Digest,
    store_adapter_sha256: Digest,
    fault_injector_sha256: Digest,
    supervisor_sha256: Digest,
    offline_verifier_sha256: Digest,
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    filesystem_profile_sha256: Digest,
};

/// Canonical 512-byte case entry.
pub const FaultCaseV1 = struct {
    abi_version: u64 = case_abi,
    encoded_bytes: u64 = case_bytes,
    flags: u64 = allowed_flags,
    ordinal: u64 = 0,
    object_kind: ObjectKindV1,
    operation_kind: OperationKindV1,
    timing: FaultTimingV1,
    occurrence: u64,
    fault_kind: FaultKindV1,
    error_class: ErrorClassV1,
    native_error_domain: NativeErrorDomainV1,
    native_error_code: u64,
    injected_signal: u64,
    bytes_requested: u64,
    bytes_completed: u64,
    child_exit_code_bits: u64,
    child_termination_signal: u64,
    provenance_bits: u64,
    expected_state_mask: u64 = 0,
    observed_selector_state: SelectorStateV1,
    recovered_selector_state: SelectorStateV1 = .after,
    recovery_disposition: RecoveryDispositionV1,
    trigger_count: u64 = 1,
    reserved: u64 = 0,

    case_challenge_sha256: Digest,
    failpoint_sha256: Digest = zero_digest,
    observed_selector_wire_sha256: Digest = zero_digest,
    raw_store_snapshot_sha256: Digest,
    recovered_selector_wire_sha256: Digest = zero_digest,
    recovered_store_snapshot_sha256: Digest = zero_digest,
    fault_control_receipt_sha256: Digest,
    recovery_result_sha256: Digest,
    previous_case_sha256: Digest = zero_digest,
    case_sha256: Digest = zero_digest,
};

pub const ReportV1 = struct {
    header: ReportHeaderV1,
    selector_before: SelectorWireV1,
    selector_after: SelectorWireV1,
    cases: []const FaultCaseV1,
    report_body_sha256: Digest,
    report_footer_sha256: Digest,
};

pub const DecodedReportV1 = struct {
    report: ReportV1,
    encoded: []const u8,
};

pub fn reportEncodedBytesV1(case_count: u64) Error!usize {
    if (case_count == 0 or case_count > max_case_count)
        return Error.CapacityExceeded;
    const count = std.math.cast(usize, case_count) orelse
        return Error.ArithmeticOverflow;
    const entries = std.math.mul(usize, count, case_bytes) catch
        return Error.ArithmeticOverflow;
    return std.math.add(usize, report_fixed_bytes, entries) catch
        return Error.ArithmeticOverflow;
}

pub fn sealReportV1(
    header_seed: ReportHeaderV1,
    selector_before: SelectorWireV1,
    selector_after: SelectorWireV1,
    cases: []FaultCaseV1,
) Error!ReportV1 {
    if (cases.len == 0 or cases.len > max_case_count)
        return Error.CapacityExceeded;

    var header = header_seed;
    header.abi_version = report_abi;
    header.encoded_bytes = try reportEncodedBytesV1(cases.len);
    header.flags = allowed_flags;
    header.case_count = @intCast(cases.len);
    header.case_wire_bytes = case_bytes;
    header.selector_wire_bytes = campaign.selector_bytes;
    header.failpoint_count = @intCast(cases.len);
    header.errno_case_count = 0;
    header.signal_case_count = 0;
    header.expected_before_only_count = 0;
    header.expected_after_only_count = 0;
    header.expected_either_count = 0;
    header.observed_before_count = 0;
    header.observed_after_count = 0;
    header.recovered_before_count = 0;
    header.recovered_after_count = @intCast(cases.len);
    header.synthetic_fault_count = 0;
    header.real_signal_count = 0;
    header.total_trigger_count = @intCast(cases.len);
    header.reserved = 0;

    if (header.generation_before == 0) {
        header.manifest_before_sha256 = zero_digest;
        header.selector_before_wire_sha256 = zero_digest;
    } else {
        header.selector_before_wire_sha256 =
            campaign.digestV1(&selector_before);
    }
    header.selector_after_wire_sha256 =
        campaign.digestV1(&selector_after);

    for (cases, 0..) |*fault_case, index| {
        fault_case.abi_version = case_abi;
        fault_case.encoded_bytes = case_bytes;
        fault_case.flags = allowed_flags;
        fault_case.ordinal = @intCast(index);
        fault_case.expected_state_mask =
            try expectedStateMaskV1(fault_case.*);
        fault_case.recovered_selector_state = .after;
        fault_case.trigger_count = 1;
        fault_case.reserved = 0;
        fault_case.observed_selector_wire_sha256 = switch (fault_case.observed_selector_state) {
            .before => header.selector_before_wire_sha256,
            .after => header.selector_after_wire_sha256,
        };
        fault_case.recovered_selector_wire_sha256 =
            header.selector_after_wire_sha256;
        fault_case.recovered_store_snapshot_sha256 =
            header.canonical_store_after_sha256;
        fault_case.failpoint_sha256 = zero_digest;
        fault_case.previous_case_sha256 = zero_digest;
        fault_case.case_sha256 = zero_digest;

        switch (fault_case.fault_kind) {
            .injected_errno, .partial_write_errno => {
                header.errno_case_count += 1;
                header.synthetic_fault_count += 1;
            },
            .forced_signal => {
                header.signal_case_count += 1;
                header.real_signal_count += 1;
            },
        }
        switch (fault_case.expected_state_mask) {
            state_mask_before => header.expected_before_only_count += 1,
            state_mask_after => header.expected_after_only_count += 1,
            state_mask_either => header.expected_either_count += 1,
            else => return Error.InvalidCase,
        }
        switch (fault_case.observed_selector_state) {
            .before => header.observed_before_count += 1,
            .after => header.observed_after_count += 1,
        }
    }

    header.matrix_id_sha256 = zero_digest;
    try validateHeaderBaseV1(
        header,
        &selector_before,
        &selector_after,
        false,
    );
    header.matrix_id_sha256 = matrixIdSha256V1(
        header,
        &selector_before,
        &selector_after,
    );

    var previous = zero_digest;
    for (cases) |*fault_case| {
        fault_case.failpoint_sha256 =
            failpointSha256V1(header.matrix_id_sha256, fault_case.*);
        fault_case.previous_case_sha256 = previous;
        fault_case.case_sha256 =
            caseSha256V1(header.matrix_id_sha256, fault_case.*);
        previous = fault_case.case_sha256;
    }

    var report: ReportV1 = .{
        .header = header,
        .selector_before = selector_before,
        .selector_after = selector_after,
        .cases = cases,
        .report_body_sha256 = zero_digest,
        .report_footer_sha256 = zero_digest,
    };
    report.report_body_sha256 = reportBodySha256V1(report);
    report.report_footer_sha256 = reportFooterSha256V1(report);
    try validateReportV1(report);
    return report;
}

pub fn validateReportV1(report: ReportV1) Error!void {
    try validateHeaderBaseV1(
        report.header,
        &report.selector_before,
        &report.selector_after,
        true,
    );
    if (report.cases.len != report.header.case_count)
        return Error.InvalidCounts;

    var errno_count: u64 = 0;
    var signal_count: u64 = 0;
    var expected_before: u64 = 0;
    var expected_after: u64 = 0;
    var expected_either: u64 = 0;
    var observed_before: u64 = 0;
    var observed_after: u64 = 0;
    var previous = zero_digest;

    for (report.cases, 0..) |fault_case, index| {
        if (fault_case.ordinal != index or
            !digestEqual(fault_case.previous_case_sha256, previous))
            return Error.InvalidChain;
        try validateCaseV1(report.header, fault_case);
        if (!digestEqual(
            fault_case.failpoint_sha256,
            failpointSha256V1(
                report.header.matrix_id_sha256,
                fault_case,
            ),
        ) or !digestEqual(
            fault_case.case_sha256,
            caseSha256V1(
                report.header.matrix_id_sha256,
                fault_case,
            ),
        )) return Error.InvalidRoot;

        for (report.cases[0..index]) |prior| {
            if (digestEqual(
                fault_case.case_challenge_sha256,
                prior.case_challenge_sha256,
            ) or digestEqual(
                fault_case.failpoint_sha256,
                prior.failpoint_sha256,
            ) or digestEqual(
                fault_case.fault_control_receipt_sha256,
                prior.fault_control_receipt_sha256,
            ) or digestEqual(
                fault_case.recovery_result_sha256,
                prior.recovery_result_sha256,
            ) or digestEqual(
                fault_case.case_sha256,
                prior.case_sha256,
            )) return Error.InvalidIdentity;
        }

        switch (fault_case.fault_kind) {
            .injected_errno, .partial_write_errno => errno_count += 1,
            .forced_signal => signal_count += 1,
        }
        switch (fault_case.expected_state_mask) {
            state_mask_before => expected_before += 1,
            state_mask_after => expected_after += 1,
            state_mask_either => expected_either += 1,
            else => return Error.InvalidCase,
        }
        switch (fault_case.observed_selector_state) {
            .before => observed_before += 1,
            .after => observed_after += 1,
        }
        previous = fault_case.case_sha256;
    }

    const header = report.header;
    if (header.failpoint_count != report.cases.len or
        header.errno_case_count != errno_count or
        header.signal_case_count != signal_count or
        header.expected_before_only_count != expected_before or
        header.expected_after_only_count != expected_after or
        header.expected_either_count != expected_either or
        header.observed_before_count != observed_before or
        header.observed_after_count != observed_after or
        header.recovered_before_count != 0 or
        header.recovered_after_count != report.cases.len or
        header.synthetic_fault_count != errno_count or
        header.real_signal_count != signal_count or
        header.total_trigger_count != report.cases.len)
        return Error.InvalidCounts;

    if (!digestEqual(
        report.report_body_sha256,
        reportBodySha256V1(report),
    )) return Error.InvalidBodyDigest;
    if (!digestEqual(
        report.report_footer_sha256,
        reportFooterSha256V1(report),
    )) return Error.InvalidFooterDigest;
}

fn validateHeaderBaseV1(
    header: ReportHeaderV1,
    selector_before_wire: *const SelectorWireV1,
    selector_after_wire: *const SelectorWireV1,
    require_matrix_id: bool,
) Error!void {
    if (header.abi_version != report_abi)
        return Error.InvalidAbi;
    if (header.flags != allowed_flags or header.reserved != 0)
        return Error.InvalidFlags;
    if (header.case_count == 0 or
        header.case_count > max_case_count or
        header.encoded_bytes != try reportEncodedBytesV1(
            header.case_count,
        ) or
        header.case_wire_bytes != case_bytes or
        header.selector_wire_bytes != campaign.selector_bytes or
        header.generation_after !=
            try addU64(header.generation_before, 1) or
        header.store_max_bytes == 0 or
        header.store_max_files == 0)
        return Error.InvalidHeader;

    if (header.failpoint_count != header.case_count or
        try addU64(
            header.errno_case_count,
            header.signal_case_count,
        ) != header.case_count or
        try addU64(
            try addU64(
                header.expected_before_only_count,
                header.expected_after_only_count,
            ),
            header.expected_either_count,
        ) != header.case_count or
        try addU64(
            header.observed_before_count,
            header.observed_after_count,
        ) != header.case_count or
        header.recovered_before_count != 0 or
        header.recovered_after_count != header.case_count or
        header.synthetic_fault_count != header.errno_case_count or
        header.real_signal_count != header.signal_case_count or
        header.total_trigger_count != header.case_count)
        return Error.InvalidCounts;

    const digests = headerDigestsV1(header);
    for (digests, 0..) |digest, index| {
        if (index == 2 and !require_matrix_id) continue;
        if ((index == 5 or index == 7) and
            header.generation_before == 0)
        {
            if (!digestIsZero(digest)) return Error.InvalidIdentity;
            continue;
        }
        if (digestIsZero(digest)) return Error.InvalidIdentity;
    }
    if (digestEqual(
        header.manifest_before_sha256,
        header.manifest_after_sha256,
    ) or digestEqual(
        header.canonical_store_before_sha256,
        header.canonical_store_after_sha256,
    )) return Error.InvalidIdentity;

    const selector_after = campaign.decodeSelectorV1(
        selector_after_wire,
    ) catch return Error.InvalidSelector;
    if (selector_after.generation != header.generation_after or
        !digestEqual(
            selector_after.manifest_sha256,
            header.manifest_after_sha256,
        ) or !digestEqual(
        campaign.digestV1(selector_after_wire),
        header.selector_after_wire_sha256,
    ))
        return Error.InvalidSelector;

    if (header.generation_before == 0) {
        if (!std.mem.allEqual(u8, selector_before_wire, 0) or
            !digestIsZero(header.manifest_before_sha256) or
            !digestIsZero(header.selector_before_wire_sha256) or
            selector_after.generation != 1)
            return Error.InvalidSelector;
    } else {
        const selector_before = campaign.decodeSelectorV1(
            selector_before_wire,
        ) catch return Error.InvalidSelector;
        if (selector_before.generation != header.generation_before or
            selector_before.segment_count !=
                selector_after.segment_count or
            !digestEqual(
                selector_before.authority_challenge_sha256,
                selector_after.authority_challenge_sha256,
            ) or !digestEqual(
            selector_before.manifest_sha256,
            header.manifest_before_sha256,
        ) or !digestEqual(
            campaign.digestV1(selector_before_wire),
            header.selector_before_wire_sha256,
        ) or selector_after.total_records <=
            selector_before.total_records or
            selector_after.total_completed <=
                selector_before.total_completed or
            selector_after.total_events <=
                selector_before.total_events)
            return Error.InvalidSelector;
    }

    if (require_matrix_id and !digestEqual(
        header.matrix_id_sha256,
        matrixIdSha256V1(
            header,
            selector_before_wire,
            selector_after_wire,
        ),
    )) return Error.InvalidRoot;
}

fn validateCaseV1(
    header: ReportHeaderV1,
    fault_case: FaultCaseV1,
) Error!void {
    if (fault_case.abi_version != case_abi)
        return Error.InvalidAbi;
    if (fault_case.encoded_bytes != case_bytes)
        return Error.InvalidLength;
    if (fault_case.flags != allowed_flags or fault_case.reserved != 0)
        return Error.InvalidFlags;
    if (fault_case.ordinal >= header.case_count or
        (fault_case.operation_kind == .write and
            fault_case.occurrence != 1 and
            fault_case.occurrence != 2) or
        (fault_case.operation_kind != .write and
            fault_case.occurrence != 1) or
        fault_case.trigger_count != 1 or
        (fault_case.provenance_bits & ~allowed_provenance_bits) != 0)
        return Error.InvalidCase;
    try validateOperationV1(
        fault_case.object_kind,
        fault_case.operation_kind,
    );
    if (fault_case.expected_state_mask !=
        try expectedStateMaskV1(fault_case))
        return Error.InvalidCase;
    const observed_mask = switch (fault_case.observed_selector_state) {
        .before => state_mask_before,
        .after => state_mask_after,
    };
    if ((fault_case.expected_state_mask & observed_mask) == 0 or
        fault_case.recovered_selector_state != .after)
        return Error.InvalidCase;

    switch (fault_case.fault_kind) {
        .injected_errno, .partial_write_errno => {
            if (fault_case.error_class == .none or
                fault_case.native_error_domain != .posix_errno or
                fault_case.injected_signal != 0 or
                fault_case.child_exit_code_bits !=
                    injected_errno_exit_code or
                fault_case.child_termination_signal != 0 or
                fault_case.provenance_bits != errno_provenance)
                return Error.InvalidCase;
            switch (fault_case.error_class) {
                .none => unreachable,
                .io => if (fault_case.native_error_code !=
                    posix_errno_eio) return Error.InvalidCase,
                .storage_full => if (fault_case.native_error_code !=
                    posix_errno_enospc) return Error.InvalidCase,
            }
            if (fault_case.operation_kind == .write) {
                if (fault_case.bytes_requested == 0)
                    return Error.InvalidCase;
                switch (fault_case.fault_kind) {
                    .injected_errno => if (fault_case.bytes_completed != 0) return Error.InvalidCase,
                    .partial_write_errno => if (fault_case.timing != .after or
                        fault_case.bytes_completed == 0 or
                        fault_case.bytes_completed >=
                            fault_case.bytes_requested) return Error.InvalidCase,
                    .forced_signal => unreachable,
                }
            } else if (fault_case.bytes_requested != 0 or
                fault_case.bytes_completed != 0 or
                fault_case.fault_kind == .partial_write_errno)
                return Error.InvalidCase;
        },
        .forced_signal => {
            if (fault_case.error_class != .none or
                fault_case.native_error_domain != .none or
                fault_case.native_error_code != 0 or
                fault_case.injected_signal !=
                    termination_signal_kill or
                fault_case.bytes_requested != 0 or
                fault_case.bytes_completed != 0 or
                fault_case.child_exit_code_bits !=
                    running_exit_code_bits or
                fault_case.child_termination_signal !=
                    termination_signal_kill or
                fault_case.provenance_bits != signal_provenance)
                return Error.InvalidCase;
        },
    }

    const expected_observed_selector = switch (fault_case.observed_selector_state) {
        .before => header.selector_before_wire_sha256,
        .after => header.selector_after_wire_sha256,
    };
    if (!digestEqual(
        fault_case.observed_selector_wire_sha256,
        expected_observed_selector,
    ) or !digestEqual(
        fault_case.recovered_selector_wire_sha256,
        header.selector_after_wire_sha256,
    ) or !digestEqual(
        fault_case.recovered_store_snapshot_sha256,
        header.canonical_store_after_sha256,
    )) return Error.InvalidCase;

    switch (fault_case.recovery_disposition) {
        .unchanged_after => {
            if (fault_case.observed_selector_state != .after or
                !digestEqual(
                    fault_case.raw_store_snapshot_sha256,
                    header.canonical_store_after_sha256,
                ))
                return Error.InvalidCase;
        },
        .cleaned_to_after => {
            if (digestEqual(
                fault_case.raw_store_snapshot_sha256,
                header.canonical_store_after_sha256,
            )) return Error.InvalidCase;
        },
        .unchanged_before, .cleaned_to_before => return Error.InvalidCase,
    }

    const case_digests = caseDigestsV1(fault_case);
    for (case_digests, 0..) |digest, index| {
        if (index == 8 and fault_case.ordinal == 0) {
            if (!digestIsZero(digest)) return Error.InvalidChain;
            continue;
        }
        if ((index == 2) and
            fault_case.observed_selector_state == .before and
            header.generation_before == 0)
        {
            if (!digestIsZero(digest)) return Error.InvalidCase;
            continue;
        }
        if (digestIsZero(digest)) return Error.InvalidIdentity;
    }
}

fn validateOperationV1(
    object: ObjectKindV1,
    operation: OperationKindV1,
) Error!void {
    const valid = switch (object) {
        .segment, .environment, .manifest => switch (operation) {
            .create, .write, .file_sync, .link, .directory_sync, .unlink => true,
            .replace => false,
        },
        .selector => switch (operation) {
            .create, .write, .file_sync, .replace => true,
            .link, .directory_sync, .unlink => false,
        },
        .store_root => operation == .directory_sync,
    };
    if (!valid) return Error.InvalidCase;
}

pub fn expectedStateMaskV1(
    fault_case: FaultCaseV1,
) Error!u64 {
    try validateOperationV1(
        fault_case.object_kind,
        fault_case.operation_kind,
    );
    if (fault_case.object_kind == .selector and
        fault_case.operation_kind == .replace)
    {
        if (fault_case.timing == .before)
            return state_mask_before;
        return switch (fault_case.fault_kind) {
            .injected_errno, .partial_write_errno => state_mask_either,
            .forced_signal => state_mask_after,
        };
    }
    if (fault_case.object_kind == .store_root and
        fault_case.operation_kind == .directory_sync)
        return state_mask_after;
    return state_mask_before;
}

pub fn matrixIdSha256V1(
    header: ReportHeaderV1,
    selector_before: *const SelectorWireV1,
    selector_after: *const SelectorWireV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(matrix_id_domain);
    for (headerScalarsV1(header)) |field| hashU64(&hash, field);
    for (headerDigestsV1(header), 0..) |field, index| {
        if (index != 2) hash.update(&field);
    }
    hash.update(selector_before);
    hash.update(selector_after);
    return finishHash(&hash);
}

pub fn failpointSha256V1(
    matrix_id_sha256: Digest,
    fault_case: FaultCaseV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(failpoint_domain);
    hash.update(&matrix_id_sha256);
    const scalars = caseScalarsV1(fault_case);
    // A failpoint names one logical injection coordinate. Ordinal,
    // challenge, and observed/recovered outcome fields are deliberately
    // excluded so replaying one coordinate cannot manufacture a new leaf.
    for (scalars[4..18]) |field| hashU64(&hash, field);
    return finishHash(&hash);
}

pub fn caseSha256V1(
    matrix_id_sha256: Digest,
    fault_case: FaultCaseV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(case_domain);
    hash.update(&matrix_id_sha256);
    for (caseScalarsV1(fault_case)) |field| hashU64(&hash, field);
    const digests = caseDigestsV1(fault_case);
    for (digests[0..9]) |field| hash.update(&field);
    return finishHash(&hash);
}

pub fn reportBodySha256V1(report: ReportV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(report_body_domain);
    hashReportBodyV1(&hash, report);
    return finishHash(&hash);
}

pub fn reportFooterSha256V1(report: ReportV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(report_footer_domain);
    hashReportBodyV1(&hash, report);
    hash.update(&report.report_body_sha256);
    return finishHash(&hash);
}

fn hashReportBodyV1(
    hash: *std.crypto.hash.sha2.Sha256,
    report: ReportV1,
) void {
    for (headerScalarsV1(report.header)) |field|
        hashU64(hash, field);
    for (headerDigestsV1(report.header)) |field|
        hash.update(&field);
    hash.update(&report.selector_before);
    hash.update(&report.selector_after);
    for (report.cases) |fault_case| {
        for (caseScalarsV1(fault_case)) |field|
            hashU64(hash, field);
        for (caseDigestsV1(fault_case)) |field|
            hash.update(&field);
    }
}

pub fn encodeReportV1(
    report: ReportV1,
    destination: []u8,
) Error![]const u8 {
    try validateReportV1(report);
    const encoded_bytes = std.math.cast(
        usize,
        report.header.encoded_bytes,
    ) orelse return Error.ArithmeticOverflow;
    if (destination.len < encoded_bytes)
        return Error.CapacityExceeded;
    const output = destination[0..encoded_bytes];
    @memset(output, 0);
    errdefer @memset(output, 0);

    var writer: Writer = .{ .bytes = output };
    try writeHeaderV1(&writer, report.header);
    try writer.writeBytes(&report.selector_before);
    try writer.writeBytes(&report.selector_after);
    for (report.cases) |fault_case|
        try writeCaseV1(&writer, fault_case);
    try writer.writeDigest(report.report_body_sha256);
    try writer.writeDigest(report.report_footer_sha256);
    if (writer.position != encoded_bytes)
        return Error.InvalidLength;
    return output;
}

pub fn decodeReportV1(
    encoded: []const u8,
    case_storage: []FaultCaseV1,
) Error!DecodedReportV1 {
    if (encoded.len < report_fixed_bytes + case_bytes)
        return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    const header = try readHeaderV1(&reader);
    const expected_bytes = try reportEncodedBytesV1(header.case_count);
    if (encoded.len != expected_bytes or
        header.encoded_bytes != expected_bytes)
        return Error.InvalidLength;
    const count = std.math.cast(usize, header.case_count) orelse
        return Error.ArithmeticOverflow;
    if (case_storage.len < count)
        return Error.CapacityExceeded;

    var selector_before: SelectorWireV1 = undefined;
    try reader.readBytes(&selector_before);
    var selector_after: SelectorWireV1 = undefined;
    try reader.readBytes(&selector_after);
    for (case_storage[0..count]) |*fault_case|
        fault_case.* = try readCaseV1(&reader);
    const body_sha256 = try reader.readDigest();
    const footer_sha256 = try reader.readDigest();
    if (reader.position != encoded.len)
        return Error.InvalidLength;

    const report: ReportV1 = .{
        .header = header,
        .selector_before = selector_before,
        .selector_after = selector_after,
        .cases = case_storage[0..count],
        .report_body_sha256 = body_sha256,
        .report_footer_sha256 = footer_sha256,
    };
    try validateReportV1(report);
    return .{ .report = report, .encoded = encoded };
}

pub fn headerScalarsV1(value: ReportHeaderV1) [24]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.case_count,
        value.case_wire_bytes,
        value.selector_wire_bytes,
        value.generation_before,
        value.generation_after,
        value.failpoint_count,
        value.errno_case_count,
        value.signal_case_count,
        value.expected_before_only_count,
        value.expected_after_only_count,
        value.expected_either_count,
        value.observed_before_count,
        value.observed_after_count,
        value.recovered_before_count,
        value.recovered_after_count,
        value.synthetic_fault_count,
        value.real_signal_count,
        value.store_max_bytes,
        value.store_max_files,
        value.total_trigger_count,
        value.reserved,
    };
}

pub fn headerDigestsV1(value: ReportHeaderV1) [24]Digest {
    return .{
        value.matrix_challenge_sha256,
        value.schedule_sha256,
        value.matrix_id_sha256,
        value.campaign_id_sha256,
        value.plan_sha256,
        value.manifest_before_sha256,
        value.manifest_after_sha256,
        value.selector_before_wire_sha256,
        value.selector_after_wire_sha256,
        value.canonical_store_before_sha256,
        value.canonical_store_after_sha256,
        value.transition_entry_sha256,
        value.worker_sha256,
        value.backend_library_sha256,
        value.campaign_codec_sha256,
        value.store_adapter_sha256,
        value.fault_injector_sha256,
        value.supervisor_sha256,
        value.offline_verifier_sha256,
        value.machine_sha256,
        value.backend_sha256,
        value.device_sha256,
        value.placement_sha256,
        value.filesystem_profile_sha256,
    };
}

pub fn caseScalarsV1(value: FaultCaseV1) [24]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.ordinal,
        @intFromEnum(value.object_kind),
        @intFromEnum(value.operation_kind),
        @intFromEnum(value.timing),
        value.occurrence,
        @intFromEnum(value.fault_kind),
        @intFromEnum(value.error_class),
        @intFromEnum(value.native_error_domain),
        value.native_error_code,
        value.injected_signal,
        value.bytes_requested,
        value.bytes_completed,
        value.child_exit_code_bits,
        value.child_termination_signal,
        value.provenance_bits,
        value.expected_state_mask,
        @intFromEnum(value.observed_selector_state),
        @intFromEnum(value.recovered_selector_state),
        @intFromEnum(value.recovery_disposition),
        value.trigger_count,
        value.reserved,
    };
}

pub fn caseDigestsV1(value: FaultCaseV1) [10]Digest {
    return .{
        value.case_challenge_sha256,
        value.failpoint_sha256,
        value.observed_selector_wire_sha256,
        value.raw_store_snapshot_sha256,
        value.recovered_selector_wire_sha256,
        value.recovered_store_snapshot_sha256,
        value.fault_control_receipt_sha256,
        value.recovery_result_sha256,
        value.previous_case_sha256,
        value.case_sha256,
    };
}

fn writeHeaderV1(
    writer: *Writer,
    value: ReportHeaderV1,
) Error!void {
    const start = writer.position;
    for (headerScalarsV1(value)) |field|
        try writer.writeU64(field);
    for (headerDigestsV1(value)) |field|
        try writer.writeDigest(field);
    if (writer.position - start != report_header_bytes)
        return Error.InvalidLength;
}

fn readHeaderV1(reader: *Reader) Error!ReportHeaderV1 {
    const start = reader.position;
    var scalars: [24]u64 = undefined;
    for (&scalars) |*field| field.* = try reader.readU64();
    var digests: [24]Digest = undefined;
    for (&digests) |*field| field.* = try reader.readDigest();
    if (reader.position - start != report_header_bytes)
        return Error.InvalidLength;
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .case_count = scalars[3],
        .case_wire_bytes = scalars[4],
        .selector_wire_bytes = scalars[5],
        .generation_before = scalars[6],
        .generation_after = scalars[7],
        .failpoint_count = scalars[8],
        .errno_case_count = scalars[9],
        .signal_case_count = scalars[10],
        .expected_before_only_count = scalars[11],
        .expected_after_only_count = scalars[12],
        .expected_either_count = scalars[13],
        .observed_before_count = scalars[14],
        .observed_after_count = scalars[15],
        .recovered_before_count = scalars[16],
        .recovered_after_count = scalars[17],
        .synthetic_fault_count = scalars[18],
        .real_signal_count = scalars[19],
        .store_max_bytes = scalars[20],
        .store_max_files = scalars[21],
        .total_trigger_count = scalars[22],
        .reserved = scalars[23],
        .matrix_challenge_sha256 = digests[0],
        .schedule_sha256 = digests[1],
        .matrix_id_sha256 = digests[2],
        .campaign_id_sha256 = digests[3],
        .plan_sha256 = digests[4],
        .manifest_before_sha256 = digests[5],
        .manifest_after_sha256 = digests[6],
        .selector_before_wire_sha256 = digests[7],
        .selector_after_wire_sha256 = digests[8],
        .canonical_store_before_sha256 = digests[9],
        .canonical_store_after_sha256 = digests[10],
        .transition_entry_sha256 = digests[11],
        .worker_sha256 = digests[12],
        .backend_library_sha256 = digests[13],
        .campaign_codec_sha256 = digests[14],
        .store_adapter_sha256 = digests[15],
        .fault_injector_sha256 = digests[16],
        .supervisor_sha256 = digests[17],
        .offline_verifier_sha256 = digests[18],
        .machine_sha256 = digests[19],
        .backend_sha256 = digests[20],
        .device_sha256 = digests[21],
        .placement_sha256 = digests[22],
        .filesystem_profile_sha256 = digests[23],
    };
}

fn writeCaseV1(
    writer: *Writer,
    value: FaultCaseV1,
) Error!void {
    const start = writer.position;
    for (caseScalarsV1(value)) |field|
        try writer.writeU64(field);
    for (caseDigestsV1(value)) |field|
        try writer.writeDigest(field);
    if (writer.position - start != case_bytes)
        return Error.InvalidLength;
}

fn readCaseV1(reader: *Reader) Error!FaultCaseV1 {
    const start = reader.position;
    var scalars: [24]u64 = undefined;
    for (&scalars) |*field| field.* = try reader.readU64();
    var digests: [10]Digest = undefined;
    for (&digests) |*field| field.* = try reader.readDigest();
    if (reader.position - start != case_bytes)
        return Error.InvalidLength;
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .ordinal = scalars[3],
        .object_kind = std.meta.intToEnum(
            ObjectKindV1,
            scalars[4],
        ) catch return Error.InvalidEnum,
        .operation_kind = std.meta.intToEnum(
            OperationKindV1,
            scalars[5],
        ) catch return Error.InvalidEnum,
        .timing = std.meta.intToEnum(
            FaultTimingV1,
            scalars[6],
        ) catch return Error.InvalidEnum,
        .occurrence = scalars[7],
        .fault_kind = std.meta.intToEnum(
            FaultKindV1,
            scalars[8],
        ) catch return Error.InvalidEnum,
        .error_class = std.meta.intToEnum(
            ErrorClassV1,
            scalars[9],
        ) catch return Error.InvalidEnum,
        .native_error_domain = std.meta.intToEnum(
            NativeErrorDomainV1,
            scalars[10],
        ) catch return Error.InvalidEnum,
        .native_error_code = scalars[11],
        .injected_signal = scalars[12],
        .bytes_requested = scalars[13],
        .bytes_completed = scalars[14],
        .child_exit_code_bits = scalars[15],
        .child_termination_signal = scalars[16],
        .provenance_bits = scalars[17],
        .expected_state_mask = scalars[18],
        .observed_selector_state = std.meta.intToEnum(
            SelectorStateV1,
            scalars[19],
        ) catch return Error.InvalidEnum,
        .recovered_selector_state = std.meta.intToEnum(
            SelectorStateV1,
            scalars[20],
        ) catch return Error.InvalidEnum,
        .recovery_disposition = std.meta.intToEnum(
            RecoveryDispositionV1,
            scalars[21],
        ) catch return Error.InvalidEnum,
        .trigger_count = scalars[22],
        .reserved = scalars[23],
        .case_challenge_sha256 = digests[0],
        .failpoint_sha256 = digests[1],
        .observed_selector_wire_sha256 = digests[2],
        .raw_store_snapshot_sha256 = digests[3],
        .recovered_selector_wire_sha256 = digests[4],
        .recovered_store_snapshot_sha256 = digests[5],
        .fault_control_receipt_sha256 = digests[6],
        .recovery_result_sha256 = digests[7],
        .previous_case_sha256 = digests[8],
        .case_sha256 = digests[9],
    };
}

fn addU64(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn digestIsZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn finishHash(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeU64(self: *Writer, value: u64) Error!void {
        const end = std.math.add(
            usize,
            self.position,
            @sizeOf(u64),
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.CapacityExceeded;
        std.mem.writeInt(
            u64,
            self.bytes[self.position..end][0..8],
            value,
            .little,
        );
        self.position = end;
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        try self.writeBytes(&value);
    }

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        const end = std.math.add(
            usize,
            self.position,
            value.len,
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.CapacityExceeded;
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readU64(self: *Reader) Error!u64 {
        const end = std.math.add(
            usize,
            self.position,
            @sizeOf(u64),
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.InvalidLength;
        const value = std.mem.readInt(
            u64,
            self.bytes[self.position..end][0..8],
            .little,
        );
        self.position = end;
        return value;
    }

    fn readDigest(self: *Reader) Error!Digest {
        var result: Digest = undefined;
        try self.readBytes(&result);
        return result;
    }

    fn readBytes(self: *Reader, output: []u8) Error!void {
        const end = std.math.add(
            usize,
            self.position,
            output.len,
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.InvalidLength;
        @memcpy(output, self.bytes[self.position..end]);
        self.position = end;
    }
};

const golden_case_count: usize = 5;
const golden_report_bytes: usize =
    report_fixed_bytes + golden_case_count * case_bytes;

fn goldenDigest(label: []const u8) Digest {
    return campaign.digestV1(label);
}

fn goldenSelector(
    generation: u64,
    manifest_label: []const u8,
    environment_label: []const u8,
    total_records: u64,
    total_completed: u64,
    total_events: u64,
) !SelectorWireV1 {
    var selector: campaign.SelectorV1 = .{
        .generation = generation,
        .segment_count = 12,
        .total_records = total_records,
        .total_completed = total_completed,
        .total_events = total_events,
        .authority_challenge_sha256 = goldenDigest("selector-authority"),
        .manifest_sha256 = goldenDigest(manifest_label),
        .environment_sha256 = goldenDigest(environment_label),
        .selector_sha256 = zero_digest,
    };
    selector.selector_sha256 = campaign.selectorSha256V1(selector);
    var wire: SelectorWireV1 = undefined;
    _ = try campaign.encodeSelectorV1(selector, &wire);
    return wire;
}

fn goldenHeader() ReportHeaderV1 {
    return .{
        .generation_before = 5,
        .generation_after = 6,
        .store_max_bytes = 4 * 1024 * 1024,
        .store_max_files = 32,
        .matrix_challenge_sha256 = goldenDigest("matrix-challenge"),
        .schedule_sha256 = goldenDigest("schedule"),
        .campaign_id_sha256 = goldenDigest("campaign-id"),
        .plan_sha256 = goldenDigest("plan"),
        .manifest_before_sha256 = goldenDigest("manifest-before"),
        .manifest_after_sha256 = goldenDigest("manifest-after"),
        .selector_before_wire_sha256 = zero_digest,
        .selector_after_wire_sha256 = zero_digest,
        .canonical_store_before_sha256 = goldenDigest("canonical-store-before"),
        .canonical_store_after_sha256 = goldenDigest("canonical-store-after"),
        .transition_entry_sha256 = goldenDigest("transition-entry"),
        .worker_sha256 = goldenDigest("worker"),
        .backend_library_sha256 = goldenDigest("backend-library"),
        .campaign_codec_sha256 = goldenDigest("campaign-codec"),
        .store_adapter_sha256 = goldenDigest("store-adapter"),
        .fault_injector_sha256 = goldenDigest("fault-injector"),
        .supervisor_sha256 = goldenDigest("supervisor"),
        .offline_verifier_sha256 = goldenDigest("offline-verifier"),
        .machine_sha256 = goldenDigest("machine"),
        .backend_sha256 = goldenDigest("backend"),
        .device_sha256 = goldenDigest("device"),
        .placement_sha256 = goldenDigest("placement"),
        .filesystem_profile_sha256 = goldenDigest("filesystem-profile"),
    };
}

fn ordinalGoldenDigest(
    prefix: []const u8,
    ordinal: usize,
) !Digest {
    var storage: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(
        &storage,
        "{s}-{d}",
        .{ prefix, ordinal },
    );
    return goldenDigest(label);
}

fn goldenCases(
    header: ReportHeaderV1,
) ![golden_case_count]FaultCaseV1 {
    const before_store = header.canonical_store_before_sha256;
    const after_store = header.canonical_store_after_sha256;
    return .{
        .{
            .object_kind = .segment,
            .operation_kind = .create,
            .timing = .before,
            .occurrence = 1,
            .fault_kind = .injected_errno,
            .error_class = .io,
            .native_error_domain = .posix_errno,
            .native_error_code = posix_errno_eio,
            .injected_signal = 0,
            .bytes_requested = 0,
            .bytes_completed = 0,
            .child_exit_code_bits = injected_errno_exit_code,
            .child_termination_signal = 0,
            .provenance_bits = errno_provenance,
            .observed_selector_state = .before,
            .recovery_disposition = .cleaned_to_after,
            .case_challenge_sha256 = try ordinalGoldenDigest("case-challenge", 0),
            .raw_store_snapshot_sha256 = before_store,
            .fault_control_receipt_sha256 = try ordinalGoldenDigest("fault-control-receipt", 0),
            .recovery_result_sha256 = try ordinalGoldenDigest("recovery-result", 0),
        },
        .{
            .object_kind = .environment,
            .operation_kind = .write,
            .timing = .after,
            .occurrence = 1,
            .fault_kind = .partial_write_errno,
            .error_class = .storage_full,
            .native_error_domain = .posix_errno,
            .native_error_code = posix_errno_enospc,
            .injected_signal = 0,
            .bytes_requested = 4_096,
            .bytes_completed = 1_024,
            .child_exit_code_bits = injected_errno_exit_code,
            .child_termination_signal = 0,
            .provenance_bits = errno_provenance,
            .observed_selector_state = .before,
            .recovery_disposition = .cleaned_to_after,
            .case_challenge_sha256 = try ordinalGoldenDigest("case-challenge", 1),
            .raw_store_snapshot_sha256 = before_store,
            .fault_control_receipt_sha256 = try ordinalGoldenDigest("fault-control-receipt", 1),
            .recovery_result_sha256 = try ordinalGoldenDigest("recovery-result", 1),
        },
        .{
            .object_kind = .selector,
            .operation_kind = .replace,
            .timing = .after,
            .occurrence = 1,
            .fault_kind = .injected_errno,
            .error_class = .io,
            .native_error_domain = .posix_errno,
            .native_error_code = posix_errno_eio,
            .injected_signal = 0,
            .bytes_requested = 0,
            .bytes_completed = 0,
            .child_exit_code_bits = injected_errno_exit_code,
            .child_termination_signal = 0,
            .provenance_bits = errno_provenance,
            .observed_selector_state = .before,
            .recovery_disposition = .cleaned_to_after,
            .case_challenge_sha256 = try ordinalGoldenDigest("case-challenge", 2),
            .raw_store_snapshot_sha256 = before_store,
            .fault_control_receipt_sha256 = try ordinalGoldenDigest("fault-control-receipt", 2),
            .recovery_result_sha256 = try ordinalGoldenDigest("recovery-result", 2),
        },
        .{
            .object_kind = .selector,
            .operation_kind = .replace,
            .timing = .after,
            .occurrence = 1,
            .fault_kind = .forced_signal,
            .error_class = .none,
            .native_error_domain = .none,
            .native_error_code = 0,
            .injected_signal = termination_signal_kill,
            .bytes_requested = 0,
            .bytes_completed = 0,
            .child_exit_code_bits = running_exit_code_bits,
            .child_termination_signal = termination_signal_kill,
            .provenance_bits = signal_provenance,
            .observed_selector_state = .after,
            .recovery_disposition = .unchanged_after,
            .case_challenge_sha256 = try ordinalGoldenDigest("case-challenge", 3),
            .raw_store_snapshot_sha256 = after_store,
            .fault_control_receipt_sha256 = try ordinalGoldenDigest("fault-control-receipt", 3),
            .recovery_result_sha256 = try ordinalGoldenDigest("recovery-result", 3),
        },
        .{
            .object_kind = .store_root,
            .operation_kind = .directory_sync,
            .timing = .after,
            .occurrence = 1,
            .fault_kind = .injected_errno,
            .error_class = .storage_full,
            .native_error_domain = .posix_errno,
            .native_error_code = posix_errno_enospc,
            .injected_signal = 0,
            .bytes_requested = 0,
            .bytes_completed = 0,
            .child_exit_code_bits = injected_errno_exit_code,
            .child_termination_signal = 0,
            .provenance_bits = errno_provenance,
            .observed_selector_state = .after,
            .recovery_disposition = .cleaned_to_after,
            .case_challenge_sha256 = try ordinalGoldenDigest("case-challenge", 4),
            .raw_store_snapshot_sha256 = goldenDigest("raw-store-4"),
            .fault_control_receipt_sha256 = try ordinalGoldenDigest("fault-control-receipt", 4),
            .recovery_result_sha256 = try ordinalGoldenDigest("recovery-result", 4),
        },
    };
}

fn makeGoldenReport(
    cases: *[golden_case_count]FaultCaseV1,
) !ReportV1 {
    const selector_before = try goldenSelector(
        5,
        "manifest-before",
        "environment-before",
        1_250,
        500,
        6_250,
    );
    const selector_after = try goldenSelector(
        6,
        "manifest-after",
        "environment-after",
        1_500,
        600,
        7_500,
    );
    const header = goldenHeader();
    cases.* = try goldenCases(header);
    return sealReportV1(
        header,
        selector_before,
        selector_after,
        cases,
    );
}

fn expectDigestHex(
    expected: []const u8,
    actual: Digest,
) !void {
    const actual_hex = std.fmt.bytesToHex(actual, .lower);
    try std.testing.expectEqualStrings(expected, &actual_hex);
}

fn expectDecodeFailure(encoded: []const u8) !void {
    var case_storage: [max_case_count]FaultCaseV1 = undefined;
    if (decodeReportV1(encoded, &case_storage)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "five-vector wire matches independent Python golden" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 960), report_header_bytes);
    try testing.expectEqual(@as(usize, 512), case_bytes);
    try testing.expectEqual(@as(usize, 1_408), report_fixed_bytes);
    try testing.expectEqual(
        @as(usize, 3_968),
        try reportEncodedBytesV1(golden_case_count),
    );

    var cases: [golden_case_count]FaultCaseV1 = undefined;
    const report = try makeGoldenReport(&cases);
    try expectDigestHex(
        "e8aafce2b7d617667f634d95b259732365817035180ddceda447b90b8e05358e",
        report.header.selector_before_wire_sha256,
    );
    try expectDigestHex(
        "c0b26290f1c1b050fba6ab9cc9b275257388380b43035870fa0b59ab28148b71",
        report.header.selector_after_wire_sha256,
    );
    try expectDigestHex(
        "bd502cf19ee722379fb0ceceeabf6402973d312aa0e5984cceb10bea0e24b6b8",
        report.header.matrix_id_sha256,
    );

    const expected_failpoints = [_][]const u8{
        "95ae648f24a90f4fa5d84b35f60db93f30eff014def7dab6e96d5e956596179c",
        "57355ba8fa646dd8164e24cc420e3c40a4062965771b0e1143b64304ffb8c8de",
        "befb46e5c9011886bb934f5a6ce400fa82c856ad54cefffc47692e3b480a645a",
        "d0cf1afcfd0de2994ad79c869ac1a2ff1a2c1a430621c86d408f2b2c366ab11f",
        "6f1beeda70753cbaa6153ea5e1b6020637c5a21c47bc294a3ac4f65909772eb2",
    };
    const expected_cases = [_][]const u8{
        "418222cda9341d87f4252e9afe1a531c502d9e5c1fbd525b9d60ebe9120529b8",
        "7747a4ca1c50883c7fc52f13560fc56c4a8dfc3da6c7013cba7a38a0ea7de5ab",
        "03627c9d7f7567e293b7ff0c31e6d24d8d16b67b80013e8018577349ea563992",
        "85644252502d5cbdcd70eafd8289f9478ad43c0f1a611f5be3468ec3c85b3d3c",
        "ade1bf2cce3fe530a1f48432f669256ab6e083afa10a62a49648bac49d7d9f5f",
    };
    for (report.cases, 0..) |fault_case, index| {
        try expectDigestHex(
            expected_failpoints[index],
            fault_case.failpoint_sha256,
        );
        try expectDigestHex(
            expected_cases[index],
            fault_case.case_sha256,
        );
    }
    try expectDigestHex(
        "a88e145fe22062f0f9ae6eb89906c40ad71ffc23b6572d2fda77f6b777f507d3",
        report.report_body_sha256,
    );
    try expectDigestHex(
        "e8332398aa0552e2d5ec99f134e27fbc50e9750e8c32d18ded011ebc14271f56",
        report.report_footer_sha256,
    );

    var wire: [golden_report_bytes]u8 = undefined;
    const encoded = try encodeReportV1(report, &wire);
    try expectDigestHex(
        "63742152cbba93d2b935e397b7353138c1d0c472f920899f707237f49a5a35fc",
        campaign.digestV1(encoded),
    );

    var decoded_cases: [golden_case_count]FaultCaseV1 = undefined;
    const decoded = try decodeReportV1(encoded, &decoded_cases);
    try testing.expectEqualDeep(report.header, decoded.report.header);
    try testing.expectEqualSlices(
        u8,
        &report.selector_before,
        &decoded.report.selector_before,
    );
    try testing.expectEqualSlices(
        u8,
        &report.selector_after,
        &decoded.report.selector_after,
    );
    try testing.expectEqualDeep(
        report.cases,
        decoded.report.cases,
    );
}

test "initial publication uses absent predecessor and rolls forward" {
    const testing = std.testing;
    const selector_before: SelectorWireV1 =
        [_]u8{0} ** campaign.selector_bytes;
    const selector_after = try goldenSelector(
        1,
        "manifest-after",
        "environment-after",
        250,
        100,
        1_250,
    );
    var header = goldenHeader();
    header.generation_before = 0;
    header.generation_after = 1;
    header.manifest_before_sha256 = goldenDigest("ignored-predecessor");
    var cases = [_]FaultCaseV1{.{
        .object_kind = .selector,
        .operation_kind = .create,
        .timing = .after,
        .occurrence = 1,
        .fault_kind = .forced_signal,
        .error_class = .none,
        .native_error_domain = .none,
        .native_error_code = 0,
        .injected_signal = termination_signal_kill,
        .bytes_requested = 0,
        .bytes_completed = 0,
        .child_exit_code_bits = running_exit_code_bits,
        .child_termination_signal = termination_signal_kill,
        .provenance_bits = signal_provenance,
        .observed_selector_state = .before,
        .recovery_disposition = .cleaned_to_after,
        .case_challenge_sha256 = goldenDigest("initial-challenge"),
        .raw_store_snapshot_sha256 = header.canonical_store_before_sha256,
        .fault_control_receipt_sha256 = goldenDigest("initial-control"),
        .recovery_result_sha256 = goldenDigest("initial-recovery"),
    }};
    const report = try sealReportV1(
        header,
        selector_before,
        selector_after,
        &cases,
    );
    try testing.expectEqual(
        zero_digest,
        report.header.manifest_before_sha256,
    );
    try testing.expectEqual(
        zero_digest,
        report.header.selector_before_wire_sha256,
    );
    try testing.expectEqual(
        zero_digest,
        report.cases[0].observed_selector_wire_sha256,
    );
    try testing.expectEqual(
        SelectorStateV1.after,
        report.cases[0].recovered_selector_state,
    );
    try testing.expectEqual(
        @as(u64, 0),
        report.header.recovered_before_count,
    );
    try testing.expectEqual(
        @as(u64, 1),
        report.header.recovered_after_count,
    );

    var wire: [report_fixed_bytes + case_bytes]u8 = undefined;
    const encoded = try encodeReportV1(report, &wire);
    var decoded_cases: [1]FaultCaseV1 = undefined;
    _ = try decodeReportV1(encoded, &decoded_cases);
}

test "decoder rejects mutation truncation and extension" {
    var cases: [golden_case_count]FaultCaseV1 = undefined;
    const report = try makeGoldenReport(&cases);
    var wire: [golden_report_bytes]u8 = undefined;
    const encoded = try encodeReportV1(report, &wire);

    for (encoded, 0..) |_, index| {
        var mutated = wire;
        mutated[index] ^= 1;
        try expectDecodeFailure(&mutated);
    }
    for (0..encoded.len) |length|
        try expectDecodeFailure(encoded[0..length]);

    var extended: [golden_report_bytes + 1]u8 = undefined;
    @memcpy(extended[0..golden_report_bytes], encoded);
    extended[golden_report_bytes] = 0;
    try expectDecodeFailure(&extended);
}

test "case semantics reject operation occurrence provenance and recovery drift" {
    const testing = std.testing;
    var cases: [golden_case_count]FaultCaseV1 = undefined;
    const report = try makeGoldenReport(&cases);
    const header = report.header;

    var invalid_operation = cases[0];
    invalid_operation.operation_kind = .replace;
    try testing.expectError(
        Error.InvalidCase,
        validateCaseV1(header, invalid_operation),
    );

    var invalid_occurrence = cases[0];
    invalid_occurrence.occurrence = 2;
    try testing.expectError(
        Error.InvalidCase,
        validateCaseV1(header, invalid_occurrence),
    );
    invalid_occurrence = cases[1];
    invalid_occurrence.occurrence = 3;
    try testing.expectError(
        Error.InvalidCase,
        validateCaseV1(header, invalid_occurrence),
    );

    var invalid_provenance = cases[3];
    invalid_provenance.provenance_bits = errno_provenance;
    try testing.expectError(
        Error.InvalidCase,
        validateCaseV1(header, invalid_provenance),
    );

    var outside_mask = cases[0];
    outside_mask.observed_selector_state = .after;
    outside_mask.observed_selector_wire_sha256 =
        header.selector_after_wire_sha256;
    try testing.expectError(
        Error.InvalidCase,
        validateCaseV1(header, outside_mask),
    );

    var recovered_before = cases[0];
    recovered_before.recovered_selector_state = .before;
    try testing.expectError(
        Error.InvalidCase,
        validateCaseV1(header, recovered_before),
    );

    var reserved_disposition = cases[0];
    reserved_disposition.recovery_disposition =
        .cleaned_to_before;
    try testing.expectError(
        Error.InvalidCase,
        validateCaseV1(header, reserved_disposition),
    );

    var partial_without_prefix = cases[1];
    partial_without_prefix.bytes_completed =
        partial_without_prefix.bytes_requested;
    try testing.expectError(
        Error.InvalidCase,
        validateCaseV1(header, partial_without_prefix),
    );

    var root_sync_either = cases[4];
    root_sync_either.expected_state_mask = state_mask_either;
    try testing.expectError(
        Error.InvalidCase,
        validateCaseV1(header, root_sync_either),
    );
}

test "report rejects case chain and summary drift" {
    const testing = std.testing;
    var cases: [golden_case_count]FaultCaseV1 = undefined;
    var report = try makeGoldenReport(&cases);

    cases[2].previous_case_sha256 = zero_digest;
    cases[2].case_sha256 = caseSha256V1(
        report.header.matrix_id_sha256,
        cases[2],
    );
    report.report_body_sha256 = reportBodySha256V1(report);
    report.report_footer_sha256 = reportFooterSha256V1(report);
    try testing.expectError(
        Error.InvalidChain,
        validateReportV1(report),
    );

    report = try makeGoldenReport(&cases);
    report.header.synthetic_fault_count += 1;
    report.header.matrix_id_sha256 = matrixIdSha256V1(
        report.header,
        &report.selector_before,
        &report.selector_after,
    );
    try testing.expectError(
        Error.InvalidCounts,
        validateReportV1(report),
    );
}

test "logical duplicate rejects despite fresh ordinal challenge and outcome" {
    const testing = std.testing;
    var cases: [golden_case_count]FaultCaseV1 = undefined;
    var report = try makeGoldenReport(&cases);

    // Replacing the final AFTER-only coordinate with another copy of the
    // EITHER coordinate changes the schedule counts and therefore matrix ID.
    // Reseal every leaf under that coherent alternate matrix before checking
    // duplicate-coordinate rejection.
    report.header.expected_after_only_count -= 1;
    report.header.expected_either_count += 1;
    report.header.matrix_id_sha256 = matrixIdSha256V1(
        report.header,
        &report.selector_before,
        &report.selector_after,
    );
    var duplicate = cases[2];
    duplicate.ordinal = 4;
    duplicate.case_challenge_sha256 =
        goldenDigest("duplicate-coordinate-challenge");
    duplicate.fault_control_receipt_sha256 =
        goldenDigest("duplicate-coordinate-control");
    duplicate.recovery_result_sha256 =
        goldenDigest("duplicate-coordinate-recovery");
    duplicate.observed_selector_state = .after;
    duplicate.observed_selector_wire_sha256 =
        report.header.selector_after_wire_sha256;
    duplicate.raw_store_snapshot_sha256 =
        goldenDigest("duplicate-coordinate-raw-store");
    cases[4] = duplicate;
    var previous = zero_digest;
    for (&cases) |*fault_case| {
        fault_case.failpoint_sha256 = failpointSha256V1(
            report.header.matrix_id_sha256,
            fault_case.*,
        );
        fault_case.previous_case_sha256 = previous;
        fault_case.case_sha256 = caseSha256V1(
            report.header.matrix_id_sha256,
            fault_case.*,
        );
        previous = fault_case.case_sha256;
    }
    try testing.expectEqual(
        cases[2].failpoint_sha256,
        cases[4].failpoint_sha256,
    );
    report.report_body_sha256 = reportBodySha256V1(report);
    report.report_footer_sha256 = reportFooterSha256V1(report);
    try testing.expectError(
        Error.InvalidIdentity,
        validateReportV1(report),
    );
}

test "report rejects duplicate fault-control and recovery-result identities" {
    const testing = std.testing;
    var cases: [golden_case_count]FaultCaseV1 = undefined;
    var report = try makeGoldenReport(&cases);

    cases[4].fault_control_receipt_sha256 =
        cases[0].fault_control_receipt_sha256;
    var previous = zero_digest;
    for (&cases) |*fault_case| {
        fault_case.previous_case_sha256 = previous;
        fault_case.case_sha256 = caseSha256V1(
            report.header.matrix_id_sha256,
            fault_case.*,
        );
        previous = fault_case.case_sha256;
    }
    report.report_body_sha256 = reportBodySha256V1(report);
    report.report_footer_sha256 = reportFooterSha256V1(report);
    try testing.expectError(
        Error.InvalidIdentity,
        validateReportV1(report),
    );

    report = try makeGoldenReport(&cases);
    cases[4].recovery_result_sha256 =
        cases[0].recovery_result_sha256;
    previous = zero_digest;
    for (&cases) |*fault_case| {
        fault_case.previous_case_sha256 = previous;
        fault_case.case_sha256 = caseSha256V1(
            report.header.matrix_id_sha256,
            fault_case.*,
        );
        previous = fault_case.case_sha256;
    }
    report.report_body_sha256 = reportBodySha256V1(report);
    report.report_footer_sha256 = reportFooterSha256V1(report);
    try testing.expectError(
        Error.InvalidIdentity,
        validateReportV1(report),
    );
}

test "report case bound is fixed and campaign ABI remains unchanged" {
    const testing = std.testing;
    try testing.expectEqual(
        @as(usize, report_fixed_bytes + max_case_count * case_bytes),
        try reportEncodedBytesV1(max_case_count),
    );
    try testing.expectError(
        Error.CapacityExceeded,
        reportEncodedBytesV1(0),
    );
    try testing.expectError(
        Error.CapacityExceeded,
        reportEncodedBytesV1(max_case_count + 1),
    );
    try testing.expectEqual(
        @as(u64, 0x4757_434d_0000_0001),
        campaign.manifest_abi,
    );
    try testing.expectEqual(
        @as(u64, 0x4757_4345_0000_0001),
        campaign.attempt_abi,
    );
    try testing.expectEqual(
        @as(u64, 0x4757_4353_0000_0001),
        campaign.selector_abi,
    );
    try testing.expectEqual(@as(usize, 192), campaign.selector_bytes);
}
