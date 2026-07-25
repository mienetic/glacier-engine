//! Canonical model-free retained workload corpus and shrinker report.

const std = @import("std");
const core = @import("core");
const corpus = core.workload_scenario_corpus;

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

    var retained: corpus.RetainedCorpusV1 = undefined;
    try corpus.runRetainedCorpusV1(&retained);

    var original: corpus.OwnedScenarioV1 = undefined;
    try corpus.generateRetainedCaseV1(3, &original);
    const original_complexity = try corpus.complexityV1(&original);

    var shrunk: corpus.ShrinkResultV1 = undefined;
    try corpus.runSyntheticShrinkV1(&shrunk);
    const minimized_complexity = try corpus.complexityV1(
        &shrunk.scenario,
    );

    var second: corpus.ShrinkResultV1 = undefined;
    try corpus.shrinkFailureV1(
        &shrunk.scenario,
        corpus.syntheticFailureSignatureV1(),
        corpus.syntheticFailureProbeV1(),
        corpus.maximum_shrink_evaluations,
        &second,
    );
    const idempotent =
        std.mem.eql(
            u8,
            &shrunk.minimized_scenario_sha256,
            &second.minimized_scenario_sha256,
        ) and
        second.reductions == 0 and
        second.locally_minimal and
        !second.budget_exhausted;
    if (!shrunk.locally_minimal or
        shrunk.budget_exhausted or
        !minimized_complexity.lessThan(original_complexity) or
        !idempotent)
        return error.InvalidSyntheticShrink;

    const corpus_hex = std.fmt.bytesToHex(
        retained.corpus_sha256,
        .lower,
    );
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;

    try writer.print(
        "{{\"schema\":\"glacier.workload-scenario-corpus/v1\"," ++
            "\"generator_abi\":\"{x:0>16}\"," ++
            "\"shrinker_abi\":\"{x:0>16}\"," ++
            "\"corpus_abi\":\"{x:0>16}\"," ++
            "\"coverage_abi\":\"{x:0>16}\"," ++
            "\"failure_abi\":\"{x:0>16}\"," ++
            "\"retained_seed_count\":{d}," ++
            "\"class_count\":{d},\"case_count\":{d}," ++
            "\"coverage_bits\":\"{x:0>16}\"," ++
            "\"item_count\":{d},\"admitted\":{d}," ++
            "\"rejected\":{d},\"completed\":{d}," ++
            "\"cancelled\":{d},\"timed_out\":{d}," ++
            "\"service_quanta\":{d},\"driver_steps\":{d}," ++
            "\"publications\":{d}," ++
            "\"closed_terminal_sessions\":{d}," ++
            "\"zero_orphan_ownership\":{s}," ++
            "\"corpus_sha256\":\"{s}\",\"cases\":[",
        .{
            corpus.generator_abi,
            corpus.shrinker_abi,
            corpus.corpus_abi,
            corpus.coverage_abi,
            corpus.failure_abi,
            corpus.retained_seed_count,
            corpus.class_count,
            corpus.retained_case_count,
            retained.coverage_bits,
            retained.item_count,
            retained.admitted,
            retained.rejected,
            retained.completed,
            retained.cancelled,
            retained.timed_out,
            retained.service_quanta,
            retained.driver_steps,
            retained.publications,
            retained.closed_terminal_sessions,
            boolJson(retained.zero_orphan_ownership),
            &corpus_hex,
        },
    );

    for (retained.cases, 0..) |case, index| {
        if (index != 0) try writer.writeByte(',');
        try writeCase(writer, case, index / corpus.class_count);
    }

    try writer.writeAll("],\"synthetic_shrinker\":");
    try writeSynthetic(
        writer,
        shrunk,
        original_complexity,
        minimized_complexity,
        second,
        idempotent,
    );
    try writer.writeAll("}\n");
    try writer.flush();
}

fn writeCase(
    writer: anytype,
    case: corpus.CaseEvidenceV1,
    seed_index: usize,
) !void {
    const scenario_hex = std.fmt.bytesToHex(case.scenario_sha256, .lower);
    const outcome_hex = std.fmt.bytesToHex(case.outcome_sha256, .lower);
    const trace_hex = std.fmt.bytesToHex(case.trace_sha256, .lower);
    const summary_hex = std.fmt.bytesToHex(case.summary_sha256, .lower);
    const scheduled_hex = std.fmt.bytesToHex(
        case.scheduled_evidence_sha256,
        .lower,
    );
    const case_hex = std.fmt.bytesToHex(case.case_sha256, .lower);
    try writer.print(
        "{{\"case_index\":{d},\"seed_index\":{d}," ++
            "\"generator_seed\":\"{x:0>16}\"," ++
            "\"class\":\"{s}\",\"item_count\":{d}," ++
            "\"coverage_bits\":\"{x:0>16}\"," ++
            "\"admitted\":{d},\"rejected\":{d}," ++
            "\"completed\":{d},\"cancelled\":{d}," ++
            "\"timed_out\":{d},\"service_quanta\":{d}," ++
            "\"driver_steps\":{d},\"publications\":{d}," ++
            "\"closed_terminal_sessions\":{d}," ++
            "\"zero_orphan_ownership\":{s}," ++
            "\"scenario_sha256\":\"{s}\"," ++
            "\"outcome_sha256\":\"{s}\"," ++
            "\"trace_sha256\":\"{s}\"," ++
            "\"summary_sha256\":\"{s}\"," ++
            "\"scheduled_evidence_sha256\":\"{s}\"," ++
            "\"case_sha256\":\"{s}\"}}",
        .{
            case.case_index,
            seed_index,
            case.seed,
            corpus.classNameV1(case.scenario_class),
            case.item_count,
            case.coverage_bits,
            case.admitted,
            case.rejected,
            case.completed,
            case.cancelled,
            case.timed_out,
            case.service_quanta,
            case.driver_steps,
            case.publications,
            case.closed_terminal_sessions,
            boolJson(case.zero_orphan_ownership),
            &scenario_hex,
            &outcome_hex,
            &trace_hex,
            &summary_hex,
            &scheduled_hex,
            &case_hex,
        },
    );
}

fn writeSynthetic(
    writer: anytype,
    shrunk: corpus.ShrinkResultV1,
    original_complexity: corpus.ComplexityV1,
    minimized_complexity: corpus.ComplexityV1,
    second: corpus.ShrinkResultV1,
    idempotent: bool,
) !void {
    const failure_hex = std.fmt.bytesToHex(
        shrunk.failure_signature_sha256,
        .lower,
    );
    const original_hex = std.fmt.bytesToHex(
        shrunk.original_scenario_sha256,
        .lower,
    );
    const minimized_hex = std.fmt.bytesToHex(
        shrunk.minimized_scenario_sha256,
        .lower,
    );
    const idempotent_hex = std.fmt.bytesToHex(
        second.minimized_scenario_sha256,
        .lower,
    );
    try writer.print(
        "{{\"label\":\"synthetic_shrinker_conformance\"," ++
            "\"shrinker_abi\":\"{x:0>16}\"," ++
            "\"failure_signature_sha256\":\"{s}\"," ++
            "\"original_scenario_sha256\":\"{s}\"," ++
            "\"minimized_scenario_sha256\":\"{s}\"," ++
            "\"original_complexity\":",
        .{
            corpus.shrinker_abi,
            &failure_hex,
            &original_hex,
            &minimized_hex,
        },
    );
    try writeComplexity(writer, original_complexity);
    try writer.writeAll(",\"minimized_complexity\":");
    try writeComplexity(writer, minimized_complexity);
    try writer.print(
        ",\"evaluations\":{d},\"reductions\":{d}," ++
            "\"budget_exhausted\":{s},\"locally_minimal\":{s}," ++
            "\"idempotent_scenario_sha256\":\"{s}\"," ++
            "\"idempotent\":{s}}}",
        .{
            shrunk.evaluations,
            shrunk.reductions,
            boolJson(shrunk.budget_exhausted),
            boolJson(shrunk.locally_minimal),
            &idempotent_hex,
            boolJson(idempotent),
        },
    );
}

fn writeComplexity(
    writer: anytype,
    complexity: corpus.ComplexityV1,
) !void {
    try writer.writeByte('[');
    for (complexity.orderedValues(), 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{value});
    }
    try writer.writeByte(']');
}

fn boolJson(value: bool) []const u8 {
    return if (value) "true" else "false";
}
