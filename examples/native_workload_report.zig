//! Deterministic, hardware-independent Native Workload Report V1 wire.

const std = @import("std");
const native_report = @import("native_workload_report");

const record_count: usize = 6;
const encoded_bytes: usize =
    native_report.minimum_encoded_bytes +
    record_count * native_report.record_wire_bytes;

pub fn main() !void {
    var argument_storage: [4096]u8 = undefined;
    var argument_allocator = std.heap.FixedBufferAllocator.init(
        &argument_storage,
    );
    var args = try std.process.argsWithAllocator(
        argument_allocator.allocator(),
    );
    defer args.deinit();
    _ = args.next();
    if (args.next() != null) return error.UnexpectedArgument;

    const scenario = try referenceScenario();
    var records: [record_count]native_report.RecordV1 = undefined;
    try fillReferenceRecords(scenario, &records);
    const closure = try native_report.makeClosureV1(5, 5);
    const report = try native_report.sealV1(
        scenario,
        &records,
        closure,
    );

    var storage: [encoded_bytes]u8 = undefined;
    const wire = try native_report.encodeV1(report, &storage);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.writeAll(wire);
    try stdout_writer.interface.flush();
}

fn taggedDigest(tag: u8, ordinal: u32) native_report.Digest {
    var bytes: [5]u8 = undefined;
    bytes[0] = tag;
    std.mem.writeInt(u32, bytes[1..5], ordinal, .little);
    return native_report.digestV1(&bytes);
}

fn referenceScenario() !native_report.ScenarioV1 {
    return native_report.makeScenarioV1(.{
        .mode = .closed,
        .evidence = .synthetic,
        .warmup_count = 2,
        .measured_count = 4,
        .max_in_flight = 2,
        .queue_count = 2,
        .flow_count = 2,
        .workload_sha256 = taggedDigest(1, 0),
        .profile_sha256 = taggedDigest(2, 0),
        .artifact_sha256 = taggedDigest(3, 0),
        .build_sha256 = taggedDigest(4, 0),
        .machine_sha256 = taggedDigest(5, 0),
        .backend_sha256 = taggedDigest(6, 0),
        .device_sha256 = taggedDigest(7, 0),
        .placement_sha256 = taggedDigest(8, 0),
        .host_source_sha256 = taggedDigest(9, 0),
        .host_clock_sha256 = taggedDigest(10, 0),
        .device_source_sha256 = taggedDigest(11, 0),
        .device_clock_sha256 = taggedDigest(12, 0),
        .challenge_sha256 = taggedDigest(13, 0),
    });
}

fn completeHost(
    timestamps: [native_report.event_count]u64,
    sequences: [native_report.event_count]u64,
) native_report.HostEventsV1 {
    return .{
        .presence_mask = native_report.event_presence_all,
        .arrival = .{
            .ns = timestamps[0],
            .sequence = sequences[0],
        },
        .admission = .{
            .ns = timestamps[1],
            .sequence = sequences[1],
        },
        .first_service = .{
            .ns = timestamps[2],
            .sequence = sequences[2],
        },
        .submit_return = .{
            .ns = timestamps[3],
            .sequence = sequences[3],
        },
        .first_output = .{
            .ns = timestamps[4],
            .sequence = sequences[4],
        },
        .terminal = .{
            .ns = timestamps[5],
            .sequence = sequences[5],
        },
        .settlement = .{
            .ns = timestamps[6],
            .sequence = sequences[6],
        },
    };
}

fn completedRecord(
    scenario: native_report.ScenarioV1,
    ordinal: u32,
    cohort: native_report.CohortV1,
    flow_id: u32,
    timestamps: [native_report.event_count]u64,
    sequences: [native_report.event_count]u64,
) !native_report.RecordV1 {
    const start = 10.0 + @as(f64, @floatFromInt(ordinal));
    const end = start + 0.000001;
    const start_bits: u64 = @bitCast(start);
    const end_bits: u64 = @bitCast(end);
    return native_report.makeRecordV1(.{
        .ordinal = ordinal,
        .cohort = cohort,
        .outcome = .completed,
        .correctness = .correct,
        .flow_id = flow_id,
        .work_units = 10,
        .adapter_queue_slot = flow_id,
        .host = completeHost(timestamps, sequences),
        .roots = .{
            .request_sha256 = taggedDigest(20, ordinal),
            .ticket_sha256 = taggedDigest(21, ordinal),
            .pin_sha256 = taggedDigest(22, ordinal),
            .dispatch_sha256 = taggedDigest(23, ordinal),
            .submission_sha256 = taggedDigest(24, ordinal),
            .output_sha256 = taggedDigest(25, ordinal),
            .oracle_sha256 = taggedDigest(26, ordinal),
            .terminal_sha256 = taggedDigest(27, ordinal),
            .completion_sha256 = taggedDigest(28, ordinal),
        },
        .maximum_abs_error_f64_bits = @bitCast(@as(f64, 0.001)),
        .device_timing = .{
            .availability = .present,
            .raw_start_f64_bits = start_bits,
            .raw_end_f64_bits = end_bits,
            .duration_ns = native_report.deviceDurationNsV1(
                start_bits,
                end_bits,
            ).?,
            .source_sha256 = scenario.device_source_sha256,
            .clock_sha256 = scenario.device_clock_sha256,
        },
        .allocated_context = .{
            .availability = .present,
            .before_bytes = 4_096 + ordinal,
            .after_bytes = 4_112 + ordinal,
            .source_sha256 = scenario.device_source_sha256,
        },
        .logical = .{
            .bank_acquisitions = 1,
            .bank_completions = 1,
            .bank_used_before = 100,
            .bank_used_after_settlement = 100,
            .pin_count_before = 1,
            .pin_count_after_settlement = 0,
            .dispatch_count_before = 1,
            .dispatch_count_after_settlement = 0,
            .native_command_count_before = 1,
            .native_command_count_after_settlement = 0,
        },
    });
}

fn unavailableTiming(
    scenario: native_report.ScenarioV1,
    ordinal: u32,
) native_report.DeviceTimingV1 {
    return .{
        .availability = .unsupported,
        .source_sha256 = scenario.device_source_sha256,
        .clock_sha256 = scenario.device_clock_sha256,
        .reason_sha256 = taggedDigest(30, ordinal),
    };
}

fn unavailableAllocation(
    scenario: native_report.ScenarioV1,
    ordinal: u32,
) native_report.AllocatedContextV1 {
    return .{
        .availability = .unsupported,
        .source_sha256 = scenario.device_source_sha256,
        .reason_sha256 = taggedDigest(31, ordinal),
    };
}

fn capacityRejectedRecord(
    scenario: native_report.ScenarioV1,
    ordinal: u32,
) !native_report.RecordV1 {
    return native_report.makeRecordV1(.{
        .ordinal = ordinal,
        .cohort = .measured,
        .outcome = .capacity_rejected,
        .work_units = 10,
        .host = .{
            .presence_mask = native_report.capacity_rejected_presence,
            .arrival = .{ .ns = 1_030, .sequence = 38 },
            .terminal = .{ .ns = 1_031, .sequence = 39 },
            .settlement = .{ .ns = 1_031, .sequence = 40 },
        },
        .roots = .{
            .request_sha256 = taggedDigest(20, ordinal),
            .terminal_sha256 = taggedDigest(27, ordinal),
            .completion_sha256 = taggedDigest(28, ordinal),
        },
        .device_timing = unavailableTiming(scenario, ordinal),
        .allocated_context = unavailableAllocation(scenario, ordinal),
    });
}

fn timedOutRecord(
    scenario: native_report.ScenarioV1,
    ordinal: u32,
) !native_report.RecordV1 {
    return native_report.makeRecordV1(.{
        .ordinal = ordinal,
        .cohort = .measured,
        .outcome = .timed_out,
        .work_units = 10,
        .adapter_queue_slot = 0,
        .host = .{
            .presence_mask = native_report.event_presence_all &
                ~native_report.event_first_output,
            .arrival = .{ .ns = 1_040, .sequence = 41 },
            .admission = .{ .ns = 1_041, .sequence = 42 },
            .first_service = .{ .ns = 1_042, .sequence = 43 },
            .submit_return = .{ .ns = 1_043, .sequence = 44 },
            .terminal = .{ .ns = 1_045, .sequence = 45 },
            .settlement = .{ .ns = 1_046, .sequence = 46 },
        },
        .roots = .{
            .request_sha256 = taggedDigest(20, ordinal),
            .ticket_sha256 = taggedDigest(21, ordinal),
            .pin_sha256 = taggedDigest(22, ordinal),
            .dispatch_sha256 = taggedDigest(23, ordinal),
            .submission_sha256 = taggedDigest(24, ordinal),
            .terminal_sha256 = taggedDigest(27, ordinal),
            .completion_sha256 = taggedDigest(28, ordinal),
        },
        .device_timing = unavailableTiming(scenario, ordinal),
        .allocated_context = unavailableAllocation(scenario, ordinal),
        .logical = .{
            .bank_acquisitions = 1,
            .bank_completions = 1,
            .bank_used_before = 100,
            .bank_used_after_settlement = 100,
            .pin_count_before = 1,
            .pin_count_after_settlement = 0,
            .dispatch_count_before = 1,
            .dispatch_count_after_settlement = 0,
            .native_command_count_before = 1,
            .native_command_count_after_settlement = 0,
        },
    });
}

fn fillReferenceRecords(
    scenario: native_report.ScenarioV1,
    records: *[record_count]native_report.RecordV1,
) !void {
    records[0] = try completedRecord(
        scenario,
        0,
        .warmup,
        0,
        [_]u64{100} ** native_report.event_count,
        .{ 1, 2, 3, 4, 5, 6, 7 },
    );
    records[1] = try completedRecord(
        scenario,
        1,
        .warmup,
        1,
        .{ 200, 201, 202, 203, 204, 205, 206 },
        .{ 8, 9, 10, 11, 12, 13, 14 },
    );
    records[2] = try completedRecord(
        scenario,
        2,
        .measured,
        0,
        .{ 1_000, 1_001, 1_002, 1_003, 1_010, 1_012, 1_016 },
        .{ 20, 21, 22, 23, 30, 32, 36 },
    );
    records[3] = try completedRecord(
        scenario,
        3,
        .measured,
        1,
        .{ 1_004, 1_005, 1_006, 1_007, 1_011, 1_013, 1_017 },
        .{ 24, 25, 26, 27, 31, 33, 37 },
    );
    records[4] = try capacityRejectedRecord(scenario, 4);
    records[5] = try timedOutRecord(scenario, 5);
}
