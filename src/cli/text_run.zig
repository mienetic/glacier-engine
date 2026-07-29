//! Supported experimental raw-text command for one prepared CPU profile.
//!
//! This path intentionally bypasses the compatibility `generate` command. It
//! validates a prepared GLRT image, hashes exact license bytes, tokenizes one
//! strict UTF-8 prompt, binds that evidence into the Common Model Contract,
//! executes through SessionV3, seals the terminal result, and proves final
//! logical ownership returns to zero.

const std = @import("std");
const engine = @import("engine");

const maximum_license_bytes: u64 = 64 * 1024;
const tokenizer_input_limit: u64 = 4096;
const maximum_new_tokens: usize = 64;
const request_epoch: u64 = 0x5231_4b42_0000_0001;
const bank_epoch: u64 = 0x5231_4b42_0000_0002;
const scheduler_epoch: u64 = 0x5231_4b42_0000_0003;
const coordinator_id: u64 = 0x5231_4b42_0000_0004;
const retained_fixture_source_fingerprint = [32]u8{
    0x85, 0x3f, 0xd0, 0xc2, 0x4d, 0x0c, 0x5a, 0x84,
    0x74, 0x17, 0x29, 0x2a, 0xfe, 0x09, 0xe2, 0x98,
    0x47, 0xc7, 0xef, 0x72, 0x07, 0x0e, 0x2a, 0x6f,
    0xd6, 0x40, 0x8a, 0x90, 0x67, 0x7c, 0xf7, 0x47,
};
const retained_fixture_license_sha256 = [32]u8{
    0x43, 0xc3, 0xaf, 0xa8, 0x1d, 0x9e, 0xa0, 0xff,
    0xdd, 0xe3, 0x29, 0x3b, 0x4d, 0xcc, 0x0f, 0x8d,
    0x17, 0xe2, 0xa0, 0xfb, 0x76, 0xb7, 0xd2, 0xd8,
    0xff, 0x8a, 0x84, 0x1f, 0xd5, 0x6f, 0x58, 0x88,
};

const ReceiptSinkV1 = struct {
    prepare_calls: usize = 0,
    commit_calls: usize = 0,
    abort_calls: usize = 0,
    last_transcript_sha256: [32]u8 = [_]u8{0} ** 32,

    fn interface(self: *ReceiptSinkV1) engine.lane_publication_txn.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        raw: *anyopaque,
        proposal: *const engine.lane_publication_txn.ProposalV1,
        acknowledgement: *engine.lane_publication_txn.PrepareAckV1,
    ) engine.lane_publication_txn.SinkPrepareError!void {
        const self: *ReceiptSinkV1 = @ptrCast(@alignCast(raw));
        self.prepare_calls += 1;
        acknowledgement.* = .{
            .proposal_sha256 = engine.lane_publication_txn.proposalSha256(proposal.*),
            .sink_epoch = 0x5231_4b42_0000_0010,
            .reservation_id = self.prepare_calls,
        };
    }

    fn commit(
        raw: *anyopaque,
        receipt: *const engine.lane_publication_txn.CommitReceiptV1,
    ) void {
        const self: *ReceiptSinkV1 = @ptrCast(@alignCast(raw));
        self.commit_calls += 1;
        self.last_transcript_sha256 = receipt.transcript_sha256;
    }

    fn abort(
        raw: *anyopaque,
        _: *const engine.lane_publication_txn.ProposalV1,
        _: *const engine.lane_publication_txn.PrepareAckV1,
    ) void {
        const self: *ReceiptSinkV1 = @ptrCast(@alignCast(raw));
        self.abort_calls += 1;
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    writer: *std.Io.Writer,
) !void {
    if (args.len < 7) {
        try usage(writer);
        return error.InvalidUsage;
    }
    const model_path = args[2];
    var raw_text: ?[]const u8 = null;
    var raw_text_path: ?[]const u8 = null;
    var license_path: ?[]const u8 = null;
    var new_tokens: usize = 4;
    var index: usize = 3;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--text")) {
            if (raw_text != null or raw_text_path != null)
                return error.InvalidUsage;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            raw_text = args[index];
        } else if (std.mem.eql(u8, argument, "--text-file")) {
            if (raw_text != null or raw_text_path != null)
                return error.InvalidUsage;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            raw_text_path = args[index];
        } else if (std.mem.eql(u8, argument, "--license")) {
            if (license_path != null) return error.InvalidUsage;
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            license_path = args[index];
        } else if (std.mem.eql(u8, argument, "--n")) {
            index += 1;
            if (index >= args.len) return error.InvalidUsage;
            new_tokens = std.fmt.parseInt(
                usize,
                args[index],
                10,
            ) catch return error.InvalidUsage;
        } else {
            return error.InvalidUsage;
        }
    }
    var owned_text: ?[]u8 = null;
    defer if (owned_text) |bytes| allocator.free(bytes);
    const text = raw_text orelse blk: {
        const path = raw_text_path orelse {
            try usage(writer);
            return error.InvalidUsage;
        };
        const bytes = try readBoundedStableFile(
            allocator,
            path,
            tokenizer_input_limit,
        );
        owned_text = bytes;
        break :blk bytes;
    };
    const retained_license_path = license_path orelse {
        try usage(writer);
        return error.InvalidUsage;
    };
    if (new_tokens == 0 or new_tokens > maximum_new_tokens)
        return error.InvalidUsage;
    if (text.len == 0) return error.EmptyInput;
    if (text.len > tokenizer_input_limit)
        return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(text))
        return error.InvalidUtf8;

    const license_bytes = try readBoundedStableFile(
        allocator,
        retained_license_path,
        maximum_license_bytes,
    );
    defer allocator.free(license_bytes);
    if (license_bytes.len == 0) return error.InvalidLicense;
    const artifact_license_sha256 =
        engine.core.model_contract.sha256(license_bytes);
    if (!std.mem.eql(
        u8,
        &artifact_license_sha256,
        &retained_fixture_license_sha256,
    ))
        return error.UnsupportedFixtureLicense;

    var model = try engine.loader.loadPreparedWithOptions(
        allocator,
        model_path,
        .{ .mlp_layout = .separate_required },
    );
    defer model.deinit();
    const image_identity = (model.prepared_image orelse
        return error.PreparedImageRequired).identityV1();
    if (!std.mem.eql(
        u8,
        &image_identity.source_fingerprint,
        &retained_fixture_source_fingerprint,
    ) or
        model.config.dim != 32 or
        model.config.hidden_dim != 32 or
        model.config.num_layers != 1 or
        model.config.vocab_size != 256 or
        model.config.num_heads != 1 or
        model.config.head_dim != 32 or
        model.config.num_kv_heads != 1 or
        model.config.rms_eps != @as(f32, 1e-6) or
        model.config.rope_theta != @as(f32, 10000.0) or
        model.config.tie_word_embeddings)
        return error.UnsupportedFixtureImage;
    const vocab_size = std.math.cast(
        u32,
        model.config.vocab_size,
    ) orelse return error.UnsupportedVocabulary;
    const manifest = try engine.tokenizer.makeUtf8ByteManifestV1(
        vocab_size,
        tokenizer_input_limit,
    );
    var tokenized = try engine.tokenizer.tokenizeUtf8BytesV1(
        allocator,
        manifest,
        text,
    );
    defer tokenized.deinit();

    var bank_slots: [2]engine.resource_bank.Slot = undefined;
    var lane_slots: [2]engine.lane_weave_qos.Slot = undefined;
    var projection_slots: [2]engine.lane_weave_qos.ProjectionSlot =
        undefined;
    var bank = try engine.resource_bank.Bank.init(
        &bank_slots,
        .{},
        bank_epoch,
    );
    var scheduler = try engine.lane_weave_qos.Scheduler.init(
        &bank,
        .{
            .slots = &lane_slots,
            .projection = &projection_slots,
        },
        .{
            .scheduler_epoch = scheduler_epoch,
            .coordinator_id = coordinator_id,
            .challenge = tokenized.receipt.receipt_sha256,
            .max_weight = 1,
        },
    );
    var scheduler_closed = false;
    defer if (!scheduler_closed) {
        _ = scheduler.close() catch {};
    };
    const scheduling: engine.prepared_text_session.SchedulingV1 = .{
        .tenant_key = 0x5231_4b42_0000_0021,
        .request_key = 0x5231_4b42_0000_0022,
        .request_generation = 1,
        .resource_owner_key = 0x5231_4b42_0000_0023,
        .weight = 1,
    };
    const options: engine.prepared_text_session.OptionsV1 = .{
        .max_new_tokens = new_tokens,
    };
    const local_plan = try engine.prepared_text_session.makePlanV1(
        model,
        tokenized.tokens,
        options,
    );
    const bound_input =
        try engine.prepared_text_raw_input.makeBoundPlanInputV1(
            request_epoch,
            manifest,
            artifact_license_sha256,
        );
    const bound_plan =
        try engine.prepared_text_session.makeBoundPlanV1(
            model,
            tokenized.tokens,
            options,
            local_plan,
            scheduling,
            &scheduler,
            bound_input,
        );
    const raw_input_binding =
        try engine.prepared_text_raw_input.makeBindingV1(
            text,
            &tokenized,
            local_plan,
            bound_plan,
        );

    var session: engine.prepared_text_session.SessionV3 = .{};
    defer session.deinit();
    const start = try session.start(
        allocator,
        &model,
        tokenized.tokens,
        options,
        local_plan,
        bound_input,
        bound_plan,
        scheduling,
        &scheduler,
        &bank,
    );
    switch (start) {
        .started => {},
        .rejected => return error.AdmissionRejected,
    }

    var sink: ReceiptSinkV1 = .{};
    while (!session.isFinished()) {
        _ = try session.step(
            try scheduler.prepareService(),
            sink.interface(),
        );
    }
    if (sink.prepare_calls != new_tokens or
        sink.commit_calls != new_tokens or
        sink.abort_calls != 0)
        return error.PublicationMismatch;
    const terminal = try session.sealTerminalResult();
    const output = session.outputTokens();
    if (output.len != new_tokens)
        return error.PublicationMismatch;
    _ = try session.retire();
    _ = try scheduler.close();
    scheduler_closed = true;
    const bank_snapshot = try bank.snapshot();
    if (!bank_snapshot.used.isZero() or
        bank_snapshot.committed_receipts != 0)
        return error.ResourceLeak;

    var tokenizer_manifest_wire: [engine.tokenizer.utf8_byte_manifest_bytes]u8 = undefined;
    _ = try engine.tokenizer.encodeUtf8ByteManifestV1(
        manifest,
        &tokenizer_manifest_wire,
    );
    var prompt_receipt_wire: [engine.tokenizer.utf8_byte_prompt_bytes]u8 = undefined;
    _ = try engine.tokenizer.encodeUtf8BytePromptReceiptV1(
        tokenized.receipt,
        &prompt_receipt_wire,
    );
    var raw_input_binding_wire: [engine.prepared_text_raw_input.binding_bytes]u8 = undefined;
    _ = try engine.prepared_text_raw_input.encodeV1(
        raw_input_binding,
        &raw_input_binding_wire,
    );
    var artifact_wire: [engine.core.model_contract.artifact_manifest_bytes]u8 =
        undefined;
    try engine.core.model_contract.encodeArtifactManifestV1(
        bound_plan.artifact,
        &artifact_wire,
    );
    var execution_plan_wire: [engine.core.model_contract.execution_plan_bytes]u8 =
        undefined;
    try engine.core.model_contract.encodeExecutionPlanV1(
        bound_plan.execution,
        &execution_plan_wire,
    );
    var residency_binding_wire: [engine.core.model_contract.execution_residency_binding_bytes]u8 =
        undefined;
    try engine.core.model_contract.encodeExecutionResidencyBindingV1(
        bound_plan.residency,
        &residency_binding_wire,
    );
    var result_envelope_wire: [engine.core.model_contract.result_envelope_bytes]u8 =
        undefined;
    try engine.core.model_contract.encodeResultEnvelopeV1(
        terminal.result,
        &result_envelope_wire,
    );

    const tokenizer_domain_hex = std.fmt.bytesToHex(
        manifest.domain_sha256,
        .lower,
    );
    const tokenizer_behavior_hex = std.fmt.bytesToHex(
        manifest.behavior_sha256,
        .lower,
    );
    const tokenizer_config_hex = std.fmt.bytesToHex(
        manifest.config_sha256,
        .lower,
    );
    const prompt_receipt_hex = std.fmt.bytesToHex(
        tokenized.receipt.receipt_sha256,
        .lower,
    );
    const raw_binding_hex = std.fmt.bytesToHex(
        raw_input_binding.binding_sha256,
        .lower,
    );
    const raw_text_hex = std.fmt.bytesToHex(
        tokenized.receipt.raw_text_sha256,
        .lower,
    );
    const token_ids_hex = std.fmt.bytesToHex(
        tokenized.receipt.token_ids_sha256,
        .lower,
    );
    const prepared_prompt_hex = std.fmt.bytesToHex(
        local_plan.prompt_sha256,
        .lower,
    );
    const local_plan_hex = std.fmt.bytesToHex(
        local_plan.plan_sha256,
        .lower,
    );
    const prepared_image_hex = std.fmt.bytesToHex(
        local_plan.image_identity.container_sha256,
        .lower,
    );
    const prepared_source_hex = std.fmt.bytesToHex(
        local_plan.image_identity.source_fingerprint,
        .lower,
    );
    const bound_plan_hex = std.fmt.bytesToHex(
        bound_plan.bound_plan_sha256,
        .lower,
    );
    const artifact_hex = std.fmt.bytesToHex(
        bound_plan.artifact.artifact_sha256,
        .lower,
    );
    const plan_hex = std.fmt.bytesToHex(
        bound_plan.execution.plan_sha256,
        .lower,
    );
    const residency_hex = std.fmt.bytesToHex(
        bound_plan.residency.binding_sha256,
        .lower,
    );
    const license_hex = std.fmt.bytesToHex(
        artifact_license_sha256,
        .lower,
    );
    const result_hex = std.fmt.bytesToHex(
        terminal.evidence_sha256,
        .lower,
    );
    const output_hex = std.fmt.bytesToHex(
        terminal.result.output_sha256,
        .lower,
    );
    const sink_transcript_hex = std.fmt.bytesToHex(
        sink.last_transcript_sha256,
        .lower,
    );
    const prepared_abi_hex = std.fmt.bytesToHex(
        local_plan.image_identity.abi_fingerprint,
        .lower,
    );
    const boundary_hex = std.fmt.bytesToHex(
        terminal.boundary.boundary_sha256,
        .lower,
    );
    const result_envelope_hex = std.fmt.bytesToHex(
        terminal.result.result_sha256,
        .lower,
    );
    const publication_after_hex = std.fmt.bytesToHex(
        terminal.publication_state_after_sha256,
        .lower,
    );
    const publication_previous_result_hex = std.fmt.bytesToHex(
        terminal.publication_state_after.previous_result_sha256,
        .lower,
    );
    const tokenizer_manifest_wire_hex = std.fmt.bytesToHex(
        tokenizer_manifest_wire,
        .lower,
    );
    const prompt_receipt_wire_hex = std.fmt.bytesToHex(
        prompt_receipt_wire,
        .lower,
    );
    const raw_input_binding_wire_hex = std.fmt.bytesToHex(
        raw_input_binding_wire,
        .lower,
    );
    const artifact_wire_hex = std.fmt.bytesToHex(
        artifact_wire,
        .lower,
    );
    const execution_plan_wire_hex = std.fmt.bytesToHex(
        execution_plan_wire,
        .lower,
    );
    const residency_binding_wire_hex = std.fmt.bytesToHex(
        residency_binding_wire,
        .lower,
    );
    const result_envelope_wire_hex = std.fmt.bytesToHex(
        result_envelope_wire,
        .lower,
    );
    const prompt_source =
        if (raw_text_path != null) "file" else "argv";
    try writer.print(
        "{{\"schema\":\"glacier.prepared-text-raw-run/v1\"," ++
            "\"profile\":\"utf8-byte-v1\"," ++
            "\"model_profile\":\"retained-r1kb1-fixture-v1\"," ++
            "\"prompt_source\":\"{s}\"," ++
            "\"output_rendering\":\"token-ids\"," ++
            "\"prepared_image\":true,\"common_plan\":true," ++
            "\"transactional_publication\":true," ++
            "\"durable_result_sink\":false," ++
            "\"fresh_process_recovery\":false," ++
            "\"production_model\":false," ++
            "\"retained_fixture_profile_verified\":true," ++
            "\"prompt_hashes_are_anonymized\":false," ++
            "\"replay_safe\":false," ++
            "\"boundary_snapshot_independently_verified\":false," ++
            "\"publication_transcript_replayed\":false,",
        .{prompt_source},
    );
    try writer.print(
        "\"prompt_bytes\":{d},\"prompt_tokens\":{d}," ++
            "\"output_tokens\":[",
        .{ text.len, tokenized.tokens.len },
    );
    for (output, 0..) |token, token_index| {
        if (token_index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{token});
    }
    try writer.print(
        "],\"request_epoch\":{d}," ++
            "\"tokenizer_vocab_size\":{d}," ++
            "\"tokenizer_max_input_bytes\":{d}," ++
            "\"tokenizer_domain_sha256\":\"{s}\"," ++
            "\"tokenizer_behavior_sha256\":\"{s}\"," ++
            "\"tokenizer_config_sha256\":\"{s}\"," ++
            "\"prompt_receipt_sha256\":\"{s}\"," ++
            "\"raw_text_sha256\":\"{s}\"," ++
            "\"token_ids_sha256\":\"{s}\"," ++
            "\"prepared_prompt_sha256\":\"{s}\"," ++
            "\"local_plan_sha256\":\"{s}\"," ++
            "\"prepared_image_sha256\":\"{s}\"," ++
            "\"prepared_source_fingerprint\":\"{s}\"," ++
            "\"prepared_abi_fingerprint\":\"{s}\"," ++
            "\"prepared_image_bytes\":{d}," ++
            "\"local_plan_max_new_tokens\":{d}," ++
            "\"local_plan_eos_token\":{d}," ++
            "\"local_plan_seed\":{d}," ++
            "\"local_claim\":{{" ++
            "\"capsule_bytes\":{d},\"kv_bytes\":{d}," ++
            "\"activation_bytes\":{d},\"partial_bytes\":{d}," ++
            "\"logits_bytes\":{d},\"output_journal_bytes\":{d}," ++
            "\"staging_bytes\":{d},\"device_bytes\":{d}," ++
            "\"io_bytes\":{d},\"queue_slots\":{d}}},",
        .{
            request_epoch,
            manifest.vocab_size,
            manifest.max_input_bytes,
            &tokenizer_domain_hex,
            &tokenizer_behavior_hex,
            &tokenizer_config_hex,
            &prompt_receipt_hex,
            &raw_text_hex,
            &token_ids_hex,
            &prepared_prompt_hex,
            &local_plan_hex,
            &prepared_image_hex,
            &prepared_source_hex,
            &prepared_abi_hex,
            local_plan.image_identity.container_bytes,
            local_plan.max_new_tokens,
            local_plan.eos_token,
            local_plan.seed,
            local_plan.claim.capsule_bytes,
            local_plan.claim.kv_bytes,
            local_plan.claim.activation_bytes,
            local_plan.claim.partial_bytes,
            local_plan.claim.logits_bytes,
            local_plan.claim.output_journal_bytes,
            local_plan.claim.staging_bytes,
            local_plan.claim.device_bytes,
            local_plan.claim.io_bytes,
            local_plan.claim.queue_slots,
        },
    );
    try writer.print(
        "\"bound_plan_sha256\":\"{s}\"," ++
            "\"raw_input_binding_sha256\":\"{s}\"," ++
            "\"artifact_sha256\":\"{s}\"," ++
            "\"execution_plan_sha256\":\"{s}\"," ++
            "\"residency_binding_sha256\":\"{s}\"," ++
            "\"artifact_license_sha256\":\"{s}\"," ++
            "\"output_sha256\":\"{s}\"," ++
            "\"boundary_sha256\":\"{s}\"," ++
            "\"result_envelope_sha256\":\"{s}\"," ++
            "\"publication_state_after_sha256\":\"{s}\"," ++
            "\"publication_state_after_request_epoch\":{d}," ++
            "\"publication_state_after_next_sequence\":{d}," ++
            "\"publication_state_after_visible_results\":{d}," ++
            "\"publication_state_after_previous_result_sha256\":\"{s}\"," ++
            "\"result_evidence_sha256\":\"{s}\"," ++
            "\"last_sink_transcript_sha256\":\"{s}\"," ++
            "\"tokenizer_manifest_wire_hex\":\"{s}\"," ++
            "\"prompt_receipt_wire_hex\":\"{s}\"," ++
            "\"raw_input_binding_wire_hex\":\"{s}\"," ++
            "\"artifact_manifest_wire_hex\":\"{s}\"," ++
            "\"execution_plan_wire_hex\":\"{s}\"," ++
            "\"residency_binding_wire_hex\":\"{s}\"," ++
            "\"result_envelope_wire_hex\":\"{s}\"," ++
            "\"final_bank_host_bytes\":0," ++
            "\"runtime_self_verified\":true}}\n",
        .{
            &bound_plan_hex,
            &raw_binding_hex,
            &artifact_hex,
            &plan_hex,
            &residency_hex,
            &license_hex,
            &output_hex,
            &boundary_hex,
            &result_envelope_hex,
            &publication_after_hex,
            terminal.publication_state_after.request_epoch,
            terminal.publication_state_after.next_sequence,
            terminal.publication_state_after.visible_results,
            &publication_previous_result_hex,
            &result_hex,
            &sink_transcript_hex,
            &tokenizer_manifest_wire_hex,
            &prompt_receipt_wire_hex,
            &raw_input_binding_wire_hex,
            &artifact_wire_hex,
            &execution_plan_wire_hex,
            &residency_binding_wire_hex,
            &result_envelope_wire_hex,
        },
    );
}

fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "usage: glacier text-run <retained-fixture.glrt> " ++
            "(--text <utf8>|--text-file <path>) " ++
            "--license <license-file> [--n 1..64]\n",
    );
}

fn readBoundedStableFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    maximum_bytes: u64,
) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const before = try file.stat();
    if (before.size > maximum_bytes)
        return error.FileTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read_count = try file.pread(
            bytes[offset..],
            @intCast(offset),
        );
        if (read_count == 0) return error.UnexpectedEndOfFile;
        offset += read_count;
    }
    const after = try file.stat();
    if (before.inode != after.inode or
        before.size != after.size or
        before.mtime != after.mtime or
        before.ctime != after.ctime)
        return error.LicenseChanged;
    return bytes;
}
