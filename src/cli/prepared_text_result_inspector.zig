//! Read-only inspector for one prepared-text checkpoint/result-sink view.
//!
//! The command opens only existing content-addressed storage through the
//! descriptor-relative read-only adapters. It grants no lease or authority,
//! performs no recovery, and discloses output bytes only after the caller
//! supplies `--reveal-output`.

const std = @import("std");
const engine = @import("engine");

const checkpoint_file = engine.core.continuation_checkpoint_file;
const committed = engine.prepared_text_committed_output;
const durable_handoff = engine.prepared_text_durable_handoff;
const input_archive = engine.prepared_text_input_archive;
const progress = engine.prepared_text_acknowledged_progress;
const restart_manifest = engine.prepared_text_restart_manifest;
const result_sink = engine.prepared_text_result_sink;
const sink_file = engine.prepared_text_result_sink_file;
const tokenizer = engine.tokenizer;

const schema = "glacier.prepared-text-committed-output/v1";
const milestone = "R1k-b3";
const output_encoding = "utf8-byte-v1";
const default_max_set_bytes: usize = 1024 * 1024 * 1024;
const maximum_sink_acknowledgements: usize =
    committed.maximum_visible_tokens;

const Options = struct {
    directory: []const u8,
    reveal_output: bool = false,
    max_set_bytes: usize = default_max_set_bytes,
};

const RootsV1 = struct {
    package_sha256: committed.Digest,
    representation_sha256: committed.Digest,
    input_archive_sha256: committed.Digest,
    tokenizer_domain_sha256: committed.Digest,
    tokenizer_behavior_sha256: committed.Digest,
    tokenizer_config_sha256: committed.Digest,
    local_plan_sha256: committed.Digest,
    request_sha256: committed.Digest,
    checkpoint_selector_sha256: committed.Digest,
    checkpoint_set_sha256: committed.Digest,
    checkpoint_state_sha256: committed.Digest,
    sink_selector_sha256: committed.Digest,
    sink_ledger_sha256: committed.Digest,
    sink_implementation_sha256: committed.Digest,
    sink_instance_sha256: committed.Digest,
    head_acknowledgement_sha256: committed.Digest,
    result_sink_prefix_sha256: committed.Digest,
    visible_tokens_sha256: committed.Digest,
    visible_bytes_sha256: committed.Digest,
    view_sha256: committed.Digest,
};

const ReportV1 = struct {
    sequence_state: []const u8,
    terminal: bool,
    checkpoint_pending: bool,
    checkpoint_generation: u64,
    checkpoint_next_sequence: u64,
    sink_initial_sequence: u64,
    visible_next_sequence: u64,
    output_token_count: usize,
    acknowledgement_count: usize,
    request_epoch: u64,
    output_bytes: []const u8,
    output_utf8_valid: bool,
    roots: RootsV1,
};

pub fn main() void {
    run() catch |err| {
        const stderr = std.fs.File.stderr();
        var buffer: [256]u8 = undefined;
        var writer = std.fs.File.Writer.init(stderr, &buffer);
        writer.interface.print(
            "prepared-text-result-inspector: {s}\n",
            .{@errorName(err)},
        ) catch {};
        writer.interface.flush() catch {};
        std.process.exit(2);
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    const options = try parseOptions(arguments);
    const output_storage = try allocator.alloc(
        u8,
        committed.maximum_visible_tokens,
    );
    defer allocator.free(output_storage);
    const report = try inspectDirectoryV1(
        allocator,
        options,
        output_storage,
    );

    var encoded = std.Io.Writer.Allocating.init(allocator);
    defer encoded.deinit();
    try renderReportV1(
        &encoded.writer,
        report,
        options.reveal_output,
    );

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(encoded.writer.buffered());
}

fn parseOptions(arguments: []const []const u8) !Options {
    var directory: ?[]const u8 = null;
    var reveal_output = false;
    var max_set_bytes: ?usize = null;
    var index: usize = 1;
    while (index < arguments.len) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--directory")) {
            if (directory != null or index + 1 >= arguments.len or
                arguments[index + 1].len == 0)
                return error.InvalidArguments;
            directory = arguments[index + 1];
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, argument, "--reveal-output")) {
            if (reveal_output) return error.InvalidArguments;
            reveal_output = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, argument, "--max-set-bytes")) {
            if (max_set_bytes != null or index + 1 >= arguments.len)
                return error.InvalidArguments;
            const parsed = std.fmt.parseInt(
                usize,
                arguments[index + 1],
                10,
            ) catch return error.InvalidArguments;
            if (parsed == 0) return error.InvalidArguments;
            max_set_bytes = parsed;
            index += 2;
            continue;
        }
        return error.InvalidArguments;
    }
    return .{
        .directory = directory orelse return error.InvalidArguments,
        .reveal_output = reveal_output,
        .max_set_bytes = max_set_bytes orelse default_max_set_bytes,
    };
}

fn inspectDirectoryV1(
    allocator: std.mem.Allocator,
    options: Options,
    output_storage: []u8,
) !ReportV1 {
    var directory = if (std.fs.path.isAbsolute(options.directory))
        try std.fs.openDirAbsolute(options.directory, .{
            .no_follow = true,
        })
    else
        try std.fs.cwd().openDir(options.directory, .{
            .no_follow = true,
        });
    defer directory.close();

    var sizing_selector_storage: [checkpoint_file.selector_bytes]u8 = undefined;
    const sizing_selector =
        try checkpoint_file.readActiveSelectorReadOnlyV1(
            directory,
            &sizing_selector_storage,
        );
    const selected_set_bytes = std.math.cast(
        usize,
        sizing_selector.checkpoint_bytes,
    ) orelse return error.CheckpointSetTooLarge;
    if (selected_set_bytes > options.max_set_bytes)
        return error.CheckpointSetTooLarge;
    const selected_set_storage = try allocator.alloc(
        u8,
        selected_set_bytes,
    );
    defer allocator.free(selected_set_storage);

    var checkpoint_selector_storage: [checkpoint_file.selector_bytes]u8 = undefined;
    const checkpoint_snapshot =
        checkpoint_file.readSelectedSnapshotReadOnlyV1(
            directory,
            &checkpoint_selector_storage,
            selected_set_storage,
            selected_set_storage.len,
        ) catch |snapshot_error| switch (snapshot_error) {
            error.BufferTooSmall, error.CapacityExceeded => {
                try requireCheckpointSizingSelectorUnchangedV1(
                    directory,
                    &sizing_selector_storage,
                );
                return snapshot_error;
            },
            else => return snapshot_error,
        };
    const normalized = try normalizeCheckpointV1(
        allocator,
        directory,
        checkpoint_snapshot,
        options.max_set_bytes,
    );

    const maximum_sink_ledger_bytes =
        try sink_file.ledgerBytesForCountV1(
            maximum_sink_acknowledgements,
        );
    var sink_sizing_storage: [sink_file.selector_bytes]u8 =
        undefined;
    const sink_sizing =
        try sink_file.readActiveSelectorReadOnlyV1(
            directory,
            &sink_sizing_storage,
        );
    if (sink_sizing.acknowledgement_count >
        maximum_sink_acknowledgements or
        sink_sizing.ledger_bytes > maximum_sink_ledger_bytes)
        return error.ResultSinkTooLarge;
    const sink_ledger_storage = try allocator.alloc(
        u8,
        sink_sizing.ledger_bytes,
    );
    defer allocator.free(sink_ledger_storage);
    var sink_selector_storage: [sink_file.selector_bytes]u8 =
        undefined;
    const sink_snapshot =
        sink_file.readSelectedSnapshotReadOnlyV1(
            directory,
            &sink_selector_storage,
            sink_ledger_storage,
            maximum_sink_acknowledgements,
        ) catch |snapshot_error| switch (snapshot_error) {
            error.BufferTooSmall, error.CapacityExceeded => {
                try requireSinkSizingSelectorUnchangedV1(
                    directory,
                    &sink_sizing_storage,
                );
                return snapshot_error;
            },
            else => return snapshot_error,
        };
    if (sink_snapshot.selector.acknowledgement_count >
        maximum_sink_acknowledgements or
        sink_snapshot.selector.ledger_bytes >
            maximum_sink_ledger_bytes)
        return error.ResultSinkTooLarge;

    const view = try committed.reconcileV1(
        normalized.context,
        normalized.checkpoint,
        .{
            .selector = sink_snapshot.selector,
            .ledger = sink_snapshot.ledger,
        },
        output_storage,
    );

    // Both byte-identical selectors must still be selected after both full
    // snapshots and the pure join. This establishes an overlapping observed
    // interval without acquiring either writer lease.
    var checkpoint_recheck: [checkpoint_file.selector_bytes]u8 = undefined;
    _ = checkpoint_file.readActiveSelectorReadOnlyV1(
        directory,
        &checkpoint_recheck,
    ) catch return error.SelectionChanged;
    if (!std.mem.eql(
        u8,
        &checkpoint_selector_storage,
        &checkpoint_recheck,
    )) return error.SelectionChanged;
    var sink_recheck: [sink_file.selector_bytes]u8 = undefined;
    _ = sink_file.readActiveSelectorReadOnlyV1(
        directory,
        &sink_recheck,
    ) catch return error.SelectionChanged;
    if (!std.mem.eql(
        u8,
        &sink_selector_storage,
        &sink_recheck,
    )) return error.SelectionChanged;

    return .{
        .sequence_state = view.sequence_state.label(),
        .terminal = view.terminal,
        .checkpoint_pending = view.checkpoint_pending,
        .checkpoint_generation = view.generation,
        .checkpoint_next_sequence = view.checkpoint_next_sequence,
        .sink_initial_sequence = view.sink_initial_sequence,
        .visible_next_sequence = view.visible_next_sequence,
        .output_token_count = view.visible_bytes.len,
        .acknowledgement_count = view.acknowledgement_count,
        .request_epoch = view.request_epoch,
        .output_bytes = view.visible_bytes,
        .output_utf8_valid = view.utf8_valid,
        .roots = .{
            .package_sha256 = view.package_sha256,
            .representation_sha256 = view.representation_sha256,
            .input_archive_sha256 = view.input_archive_sha256,
            .tokenizer_domain_sha256 = view.tokenizer_domain_sha256,
            .tokenizer_behavior_sha256 = view.tokenizer_behavior_sha256,
            .tokenizer_config_sha256 = view.tokenizer_config_sha256,
            .local_plan_sha256 = view.local_plan_sha256,
            .request_sha256 = view.request_sha256,
            .checkpoint_selector_sha256 = view.checkpoint_selector_sha256,
            .checkpoint_set_sha256 = view.checkpoint_set_sha256,
            .checkpoint_state_sha256 = view.checkpoint_state_sha256,
            .sink_selector_sha256 = view.sink_selector_sha256,
            .sink_ledger_sha256 = view.sink_ledger_sha256,
            .sink_implementation_sha256 = view.sink_implementation_sha256,
            .sink_instance_sha256 = view.sink_instance_sha256,
            .head_acknowledgement_sha256 = view.head_acknowledgement_sha256,
            .result_sink_prefix_sha256 = view.result_sink_prefix_sha256,
            .visible_tokens_sha256 = view.visible_tokens_sha256,
            .visible_bytes_sha256 = view.visible_bytes_sha256,
            .view_sha256 = view.view_sha256,
        },
    };
}

fn requireCheckpointSizingSelectorUnchangedV1(
    directory: std.fs.Dir,
    expected: *const [checkpoint_file.selector_bytes]u8,
) !void {
    var current: [checkpoint_file.selector_bytes]u8 = undefined;
    _ = checkpoint_file.readActiveSelectorReadOnlyV1(
        directory,
        &current,
    ) catch return error.SelectionChanged;
    if (!std.mem.eql(u8, expected, &current))
        return error.SelectionChanged;
}

fn requireSinkSizingSelectorUnchangedV1(
    directory: std.fs.Dir,
    expected: *const [sink_file.selector_bytes]u8,
) !void {
    var current: [sink_file.selector_bytes]u8 = undefined;
    _ = sink_file.readActiveSelectorReadOnlyV1(
        directory,
        &current,
    ) catch return error.SelectionChanged;
    if (!std.mem.eql(u8, expected, &current))
        return error.SelectionChanged;
}

const NormalizedCheckpointV1 = struct {
    context: committed.ContextV1,
    checkpoint: committed.CheckpointV1,
};

fn normalizeCheckpointV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    selected: checkpoint_file.ReadOnlySelectedSnapshotV1,
    max_set_bytes: usize,
) !NormalizedCheckpointV1 {
    if (selected.selector.generation ==
        progress.minimum_predecessor_generation)
    {
        const source_exited =
            try durable_handoff.decodeSourceExitedSetV1(
                selected.set_bytes,
                selected.selector,
                selected.set.metadata.parent_checkpoint_sha256,
            );
        const bound_input = source_exited.input_archive orelse
            return error.BoundInputArchiveRequired;
        const recovery =
            source_exited.source_recovery_contract orelse
            return error.SourceRecoveryContractRequired;
        const context = try contextFromInputV1(
            bound_input,
            source_exited.evidence.manifest,
        );
        return .{
            .context = context,
            .checkpoint = checkpointFromStateV1(
                context,
                selected,
                source_exited.evidence.checkpoint.request_epoch,
                source_exited.evidence.checkpoint
                    .publication_next_sequence,
                recovery.sink.initial_sequence,
                source_exited.evidence.checkpoint
                    .canonical_output_u32_le,
                source_exited.evidence.manifest.plan.plan_sha256,
                recovery.sink.implementation_sha256,
                recovery.sink.instance_sha256,
                result_sink.zero_digest,
                result_sink.zero_digest,
                source_exited.evidence.checkpoint
                    .state_commitment_sha256,
                false,
            ),
        };
    }
    if (selected.selector.generation <
        progress.minimum_predecessor_generation)
        return error.UnsupportedCheckpointGeneration;

    const terminal =
        selected.set.object_count == progress.terminal_object_count;
    if (!terminal and
        selected.set.object_count !=
            progress.nonterminal_object_count and
        selected.set.object_count !=
            progress.bound_nonterminal_object_count)
        return error.UnsupportedCheckpointShape;
    const embedded_selector = try embeddedPredecessorSelectorV1(
        selected,
        terminal,
    );
    const predecessor_selector =
        try checkpoint_file.decodeSelectorV1(
            embedded_selector.bytes,
        );
    const predecessor_bytes = std.math.cast(
        usize,
        predecessor_selector.checkpoint_bytes,
    ) orelse return error.CheckpointSetTooLarge;
    if (predecessor_bytes > max_set_bytes)
        return error.CheckpointSetTooLarge;
    const predecessor_storage = try allocator.alloc(
        u8,
        predecessor_bytes,
    );
    defer allocator.free(predecessor_storage);
    const predecessor =
        try checkpoint_file.loadRetainedSetReadOnlyV1(
            directory,
            predecessor_selector,
            predecessor_storage,
            predecessor_storage.len,
        );

    if (!terminal) {
        const decoded = try progress.decodeNonterminalV1(
            predecessor.bytes,
            embedded_selector.bytes,
            selected.set_bytes,
            selected.selector_bytes,
        );
        const bound_input = decoded.input_archive orelse
            return error.BoundInputArchiveRequired;
        const context = try contextFromInputV1(
            bound_input,
            decoded.manifest,
        );
        const sink_initial = try acknowledgementInitialSequenceV1(
            decoded.acknowledgement,
        );
        return .{
            .context = context,
            .checkpoint = checkpointFromStateV1(
                context,
                selected,
                decoded.checkpoint.request_epoch,
                decoded.checkpoint.publication_next_sequence,
                sink_initial,
                decoded.checkpoint.canonical_output_u32_le,
                decoded.manifest.plan.plan_sha256,
                decoded.acknowledgement
                    .sink_implementation_sha256,
                decoded.acknowledgement.sink_instance_sha256,
                decoded.acknowledgement
                    .acknowledgement_sha256,
                decoded.acknowledgement
                    .result_sink_prefix_sha256,
                decoded.checkpoint.state_commitment_sha256,
                false,
            ),
        };
    }

    const decoded = try progress.decodeTerminalV1(
        predecessor.bytes,
        embedded_selector.bytes,
        selected.set_bytes,
        selected.selector_bytes,
    );
    const producer = try progress.decodeProducerContextV1(
        decoded.predecessor,
    );
    const bound_input = producer.input_archive orelse
        return error.BoundInputArchiveRequired;
    const context = try contextFromInputV1(
        bound_input,
        producer.manifest,
    );
    const sink_initial = try acknowledgementInitialSequenceV1(
        decoded.acknowledgement,
    );
    return .{
        .context = context,
        .checkpoint = checkpointFromStateV1(
            context,
            selected,
            decoded.semantic.request_epoch,
            decoded.semantic.publication_next_sequence,
            sink_initial,
            decoded.canonical_output_u32_le,
            producer.manifest.plan.plan_sha256,
            decoded.acknowledgement.sink_implementation_sha256,
            decoded.acknowledgement.sink_instance_sha256,
            decoded.acknowledgement.acknowledgement_sha256,
            decoded.acknowledgement.result_sink_prefix_sha256,
            decoded.semantic.state_commitment_sha256,
            true,
        ),
    };
}

fn embeddedPredecessorSelectorV1(
    selected: checkpoint_file.ReadOnlySelectedSnapshotV1,
    terminal: bool,
) !checkpoint_file.ObjectViewV1 {
    if (selected.set.object_count == 0)
        return error.UnsupportedCheckpointShape;
    const object = selected.set.objects[0];
    const expected_kind: checkpoint_file.ObjectKindV1 =
        if (terminal) .extension else .runtime_state;
    const expected_ordinal =
        if (terminal)
            progress.terminal_predecessor_selector_object_ordinal
        else
            progress.nonterminal_predecessor_selector_object_ordinal;
    if (object.kind != expected_kind or
        object.ordinal != expected_ordinal or
        object.abi_version != checkpoint_file.selector_abi or
        object.bytes.len != checkpoint_file.selector_bytes)
        return error.UnsupportedCheckpointShape;
    return object;
}

fn contextFromInputV1(
    bound_input: input_archive.DecodedV1,
    manifest: restart_manifest.DecodedV1,
) !committed.ContextV1 {
    if (!tokenizer.utf8ByteManifestValidV1(
        bound_input.tokenizer_manifest,
    )) return error.CanonicalTokenizerRequired;
    try input_archive.verifyCurrentPlanV1(
        bound_input,
        manifest.plan,
        manifest.bound_plan,
    );
    return .{
        .package_sha256 = bound_input.package.package_sha256,
        .representation_sha256 = bound_input.representation.representation_sha256,
        .input_archive_sha256 = bound_input.archive_sha256,
        .tokenizer_manifest = bound_input.tokenizer_manifest,
        .local_plan_sha256 = manifest.plan.plan_sha256,
    };
}

fn checkpointFromStateV1(
    context: committed.ContextV1,
    selected: checkpoint_file.ReadOnlySelectedSnapshotV1,
    request_epoch: u64,
    next_sequence: u64,
    sink_initial_sequence: u64,
    canonical_output_u32_le: []const u8,
    request_sha256: committed.Digest,
    sink_implementation_sha256: committed.Digest,
    sink_instance_sha256: committed.Digest,
    head_acknowledgement_sha256: committed.Digest,
    result_sink_prefix_sha256: committed.Digest,
    state_sha256: committed.Digest,
    terminal: bool,
) committed.CheckpointV1 {
    return .{
        .context = context,
        .generation = selected.selector.generation,
        .terminal = terminal,
        .request_epoch = request_epoch,
        .next_sequence = next_sequence,
        .sink_initial_sequence = sink_initial_sequence,
        .canonical_output_u32_le = canonical_output_u32_le,
        .request_sha256 = request_sha256,
        .sink_implementation_sha256 = sink_implementation_sha256,
        .sink_instance_sha256 = sink_instance_sha256,
        .head_acknowledgement_sha256 = head_acknowledgement_sha256,
        .result_sink_prefix_sha256 = result_sink_prefix_sha256,
        .selector_sha256 = selected.selector.selector_sha256,
        .selected_set_sha256 = selected.set.checkpoint_sha256,
        .state_sha256 = state_sha256,
    };
}

fn acknowledgementInitialSequenceV1(
    acknowledgement: result_sink.ResultAcknowledgementV1,
) !u64 {
    if (acknowledgement.application_ordinal == 0)
        return error.InvalidAcknowledgementOrdinal;
    const preceding = acknowledgement.application_ordinal - 1;
    return std.math.sub(
        u64,
        acknowledgement.transaction_sequence,
        preceding,
    ) catch return error.InvalidAcknowledgementOrdinal;
}

fn renderReportV1(
    writer: *std.Io.Writer,
    report: ReportV1,
    reveal_output: bool,
) !void {
    if (report.output_token_count != report.output_bytes.len or
        report.output_utf8_valid !=
            std.unicode.utf8ValidateSlice(report.output_bytes))
        return error.InvalidReport;
    try writer.print(
        "{{\"schema\":\"{s}\",\"milestone\":\"{s}\"," ++
            "\"wire_bytes_verified\":true,\"read_only\":true," ++
            "\"authority\":false,\"output_disclosed\":{s}," ++
            "\"output_encoding\":\"{s}\"," ++
            "\"sequence_state\":\"{s}\"," ++
            "\"terminal\":{s},\"checkpoint_pending\":{s}," ++
            "\"checkpoint_generation\":{d}," ++
            "\"checkpoint_next_sequence\":{d}," ++
            "\"sink_initial_sequence\":{d}," ++
            "\"visible_next_sequence\":{d}," ++
            "\"output_token_count\":{d}," ++
            "\"acknowledgement_count\":{d}," ++
            "\"request_epoch\":{d}," ++
            "\"output_utf8_valid\":{s},\"roots\":{{",
        .{
            schema,
            milestone,
            boolJson(reveal_output),
            output_encoding,
            report.sequence_state,
            boolJson(report.terminal),
            boolJson(report.checkpoint_pending),
            report.checkpoint_generation,
            report.checkpoint_next_sequence,
            report.sink_initial_sequence,
            report.visible_next_sequence,
            report.output_token_count,
            report.acknowledgement_count,
            report.request_epoch,
            boolJson(report.output_utf8_valid),
        },
    );
    try writeDigestField(
        writer,
        "package_sha256",
        report.roots.package_sha256,
        true,
    );
    try writeDigestField(
        writer,
        "representation_sha256",
        report.roots.representation_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "input_archive_sha256",
        report.roots.input_archive_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "tokenizer_domain_sha256",
        report.roots.tokenizer_domain_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "tokenizer_behavior_sha256",
        report.roots.tokenizer_behavior_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "tokenizer_config_sha256",
        report.roots.tokenizer_config_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "local_plan_sha256",
        report.roots.local_plan_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "request_sha256",
        report.roots.request_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "checkpoint_selector_sha256",
        report.roots.checkpoint_selector_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "checkpoint_set_sha256",
        report.roots.checkpoint_set_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "checkpoint_state_sha256",
        report.roots.checkpoint_state_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "sink_selector_sha256",
        report.roots.sink_selector_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "sink_ledger_sha256",
        report.roots.sink_ledger_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "sink_implementation_sha256",
        report.roots.sink_implementation_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "sink_instance_sha256",
        report.roots.sink_instance_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "head_acknowledgement_sha256",
        report.roots.head_acknowledgement_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "result_sink_prefix_sha256",
        report.roots.result_sink_prefix_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "visible_tokens_sha256",
        report.roots.visible_tokens_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "visible_bytes_sha256",
        report.roots.visible_bytes_sha256,
        false,
    );
    try writeDigestField(
        writer,
        "view_sha256",
        report.roots.view_sha256,
        false,
    );
    try writer.writeByte('}');
    if (reveal_output) {
        try writer.writeAll(
            ",\"output\":{\"token_ids\":[",
        );
        for (report.output_bytes, 0..) |byte, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{d}", .{byte});
        }
        try writer.writeAll("],\"bytes_hex\":\"");
        try writeLowerHex(writer, report.output_bytes);
        try writer.writeAll("\",\"escaped_bytes\":");
        try writeEscapedBytesJsonValue(
            writer,
            report.output_bytes,
        );
        try writer.writeAll(",\"utf8_text\":");
        if (report.output_utf8_valid)
            try writeJsonString(writer, report.output_bytes)
        else
            try writer.writeAll("null");
        try writer.writeByte('}');
    }
    try writer.writeAll("}\n");
}

fn writeDigestField(
    writer: *std.Io.Writer,
    name: []const u8,
    digest: committed.Digest,
    first: bool,
) !void {
    if (!first) try writer.writeByte(',');
    try writer.print("\"{s}\":\"", .{name});
    try writeLowerHex(writer, &digest);
    try writer.writeByte('"');
}

fn writeLowerHex(
    writer: *std.Io.Writer,
    bytes: []const u8,
) !void {
    for (bytes) |byte| try writer.print("{x:0>2}", .{byte});
}

fn writeEscapedBytesJsonValue(
    writer: *std.Io.Writer,
    bytes: []const u8,
) !void {
    try writer.writeByte('"');
    for (bytes) |byte| {
        if (byte == '\\') {
            try writer.writeAll("\\\\\\\\");
        } else if (byte >= 0x20 and byte <= 0x7e) {
            if (byte == '"')
                try writer.writeAll("\\\"")
            else
                try writer.writeByte(byte);
        } else {
            try writer.print("\\\\x{x:0>2}", .{byte});
        }
    }
    try writer.writeByte('"');
}

fn writeJsonString(
    writer: *std.Io.Writer,
    value: []const u8,
) !void {
    if (!std.unicode.utf8ValidateSlice(value))
        return error.InvalidUtf8;
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try writer.print("\\u{x:0>4}", .{byte});
            },
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn boolJson(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn testDigest(byte: u8) committed.Digest {
    return [_]u8{byte} ** 32;
}

fn testReport(output: []const u8, utf8_valid: bool) ReportV1 {
    return .{
        .sequence_state = "aligned",
        .terminal = false,
        .checkpoint_pending = false,
        .checkpoint_generation = 4,
        .checkpoint_next_sequence = output.len,
        .sink_initial_sequence = 1,
        .visible_next_sequence = output.len,
        .output_token_count = output.len,
        .acknowledgement_count = if (output.len == 0)
            0
        else
            output.len - 1,
        .request_epoch = 71,
        .output_bytes = output,
        .output_utf8_valid = utf8_valid,
        .roots = .{
            .package_sha256 = testDigest(1),
            .representation_sha256 = testDigest(2),
            .input_archive_sha256 = testDigest(3),
            .tokenizer_domain_sha256 = testDigest(4),
            .tokenizer_behavior_sha256 = testDigest(5),
            .tokenizer_config_sha256 = testDigest(6),
            .local_plan_sha256 = testDigest(7),
            .request_sha256 = testDigest(8),
            .checkpoint_selector_sha256 = testDigest(9),
            .checkpoint_set_sha256 = testDigest(10),
            .checkpoint_state_sha256 = testDigest(11),
            .sink_selector_sha256 = testDigest(12),
            .sink_ledger_sha256 = testDigest(13),
            .sink_implementation_sha256 = testDigest(14),
            .sink_instance_sha256 = testDigest(15),
            .head_acknowledgement_sha256 = testDigest(16),
            .result_sink_prefix_sha256 = testDigest(17),
            .visible_tokens_sha256 = testDigest(18),
            .visible_bytes_sha256 = testDigest(19),
            .view_sha256 = testDigest(20),
        },
    };
}

test "prepared text result inspector parses bounded explicit options" {
    const defaults = try parseOptions(&.{
        "inspector",
        "--directory",
        "checkpoint-dir",
    });
    try std.testing.expectEqualStrings(
        "checkpoint-dir",
        defaults.directory,
    );
    try std.testing.expect(!defaults.reveal_output);
    try std.testing.expectEqual(
        default_max_set_bytes,
        defaults.max_set_bytes,
    );

    const explicit = try parseOptions(&.{
        "inspector",
        "--max-set-bytes",
        "4096",
        "--reveal-output",
        "--directory",
        "/checkpoint",
    });
    try std.testing.expectEqualStrings(
        "/checkpoint",
        explicit.directory,
    );
    try std.testing.expect(explicit.reveal_output);
    try std.testing.expectEqual(@as(usize, 4096), explicit.max_set_bytes);

    for ([_][]const []const u8{
        &.{"inspector"},
        &.{ "inspector", "--directory" },
        &.{ "inspector", "--directory", "" },
        &.{ "inspector", "--unknown", "x" },
        &.{ "inspector", "--max-set-bytes", "0", "--directory", "x" },
        &.{ "inspector", "--max-set-bytes", "x", "--directory", "x" },
        &.{
            "inspector",
            "--directory",
            "a",
            "--directory",
            "b",
        },
        &.{
            "inspector",
            "--directory",
            "a",
            "--reveal-output",
            "--reveal-output",
        },
    }) |invalid| {
        try std.testing.expectError(
            error.InvalidArguments,
            parseOptions(invalid),
        );
    }
}

test "prepared text result inspector hides output by default" {
    const report = testReport("secret-output", true);
    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    try renderReportV1(&first.writer, report, false);
    var second = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second.deinit();
    try renderReportV1(&second.writer, report, false);
    const encoded = first.writer.buffered();
    try std.testing.expectEqualSlices(
        u8,
        encoded,
        second.writer.buffered(),
    );
    try std.testing.expect(std.mem.endsWith(u8, encoded, "\n"));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, encoded, "\n"),
    );
    for ([_][]const u8{
        "secret-output",
        "\"output\":",
        "token_ids",
        "bytes_hex",
        "escaped_bytes",
        "utf8_text",
        "raw_text",
        "prompt",
        "license",
    }) |forbidden| {
        try std.testing.expect(
            std.mem.indexOf(u8, encoded, forbidden) == null,
        );
    }
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            encoded,
            "\"wire_bytes_verified\":true",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            encoded,
            "\"output_disclosed\":false",
        ) != null,
    );
}

test "prepared text result inspector reveals lossless canonical bytes" {
    const valid = [_]u8{ 'A', '"', '\\', '\n', 0xe2, 0x9d, 0x84 };
    var valid_output =
        std.Io.Writer.Allocating.init(std.testing.allocator);
    defer valid_output.deinit();
    try renderReportV1(
        &valid_output.writer,
        testReport(&valid, true),
        true,
    );
    const valid_json = valid_output.writer.buffered();
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            valid_json,
            "\"token_ids\":[65,34,92,10,226,157,132]",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            valid_json,
            "\"bytes_hex\":\"41225c0ae29d84\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            valid_json,
            "\"escaped_bytes\":\"A\\\"\\\\\\\\\\\\x0a" ++
                "\\\\xe2\\\\x9d\\\\x84\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            valid_json,
            "\"utf8_text\":\"A\\\"\\\\\\n❄\"",
        ) != null,
    );

    const invalid = [_]u8{ 'T', 'x', 0xdb, 'i' };
    var invalid_output =
        std.Io.Writer.Allocating.init(std.testing.allocator);
    defer invalid_output.deinit();
    try renderReportV1(
        &invalid_output.writer,
        testReport(&invalid, false),
        true,
    );
    const invalid_json = invalid_output.writer.buffered();
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            invalid_json,
            "\"bytes_hex\":\"5478db69\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            invalid_json,
            "\"escaped_bytes\":\"Tx\\\\xdbi\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            invalid_json,
            "\"utf8_text\":null",
        ) != null,
    );
}
